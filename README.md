# AFFiNE Helm Chart

Minimal Helm chart for self-hosted AFFiNE `0.27.4` (chart `0.2.1`).

## Documentation

- [Design document](docs/design.md)
- [Operations guide](docs/operations.md)
- [Platform-managed values example](examples/values-platform-managed.yaml)

## Requirements

* Kubernetes 1.25+ (secret `optional` volumes, Jobs, PVCs)
* Helm 3.12+ or Helm 4.x
* A default StorageClass, or existing PersistentVolumeClaims
* Optional: the Everest operator for managed PostgreSQL (`prerequisites.database.mode=everest`)

## Default values deploy nothing

`application.enabled`, `migration.enabled` and `prerequisites.enabled` all
default to `false`. This is intentional: a default install cannot silently
deploy an insecure or broken AFFiNE. Use the working example for local/dev:

```sh
CONTEXT=target-kube-context
helm --kube-context "$CONTEXT" upgrade --install affine-dev . \
  --namespace affine-dev --create-namespace \
  -f examples/values-dev.yaml \
  --wait --wait-for-jobs --timeout 15m
```

`examples/values-dev.yaml` uses chart-managed single-container PostgreSQL and
Redis with placeholder credentials. Never use those credentials anywhere real.

Any enabled component validates its own required values and fails the render
with a readable message (`helm lint`, `helm template`, `helm install` all run
the same validation).

## Secrets lifecycle

`secrets.mode` is the single source of truth for Secret rendering:

| Mode | Behavior |
| --- | --- |
| `create` | The chart renders application database and Redis Secrets from `secrets.database.data` / `secrets.redis.data`. When it manages a non-external database, it may also render the prerequisite database credential Secret. Supply credentials through a private values file; never commit them. |
| `existing` | With `secrets.database.allowBootstrapPatch=false` (default), the chart renders **no** Secrets and is read-only. `DATABASE_URL` must already be present in the database Secret. The explicit bootstrap-write opt-in below is the exception. Suitable for External Secrets Operator, Sealed Secrets, Vault, or any external manager. |

`secrets.mode=existing` guarantees the chart does **not** create, patch,
annotate, or delete the database or Redis Secret only when
`secrets.database.allowBootstrapPatch=false`. No chart-created Job or Role has
a write verb on either Secret then; the bootstrap Job is not rendered. With the
explicit `allowBootstrapPatch=true` opt-in, a rendered bootstrap Job may patch
or update the named database Secret as described below.

Required data keys:

| Secret | Keys |
| --- | --- |
| database (`secrets.database.name`) | `DATABASE_URL`, and configurable application credential keys (`POSTGRES_USERNAME` / `POSTGRES_PASSWORD` by default) when `databaseProvisioning.enabled=true` |
| redis (`secrets.redis.name`) | `REDIS_SERVER_HOST`, `REDIS_SERVER_PORT`, `REDIS_SERVER_USERNAME`, `REDIS_SERVER_PASSWORD`, `REDIS_SERVER_DATABASE` |

For chart-managed provisioning, application credential key names are configurable through `databaseProvisioning.application.*`. Bootstrap/admin Secret key names are configurable through `databaseProvisioning.admin.*` (host, port, user, password). In `existing` mode, chart-managed bootstrap also needs `prerequisites.database.userSecretName`.

The old nested `secret.create` flags were removed. `secrets.mode` alone
controls whether Secrets are rendered, including the prerequisite database
credential Secret.

### Explicit bootstrap-write opt-in: `secrets.database.allowBootstrapPatch`

`databaseProvisioning.enabled=true` creates the application role and database, so `DATABASE_URL` cannot exist until that Job has run. With `secrets.mode=create`, the chart owns the destination Secret. With `secrets.mode=existing`, validation fails unless you explicitly enable:

```yaml
secrets:
  mode: existing
  database:
    allowBootstrapPatch: true   # permits patch/update of this named Secret
```

This is not adoption: the chart does not label or delete the Secret. However, the writer Role grants `get`, `patch`, and `update` over the entire named Secret; Kubernetes RBAC cannot restrict those verbs to one key. The script currently merge-patches `.data.DATABASE_URL` and may remove the legacy `kubectl.kubernetes.io/last-applied-configuration` annotation. Leave the option `false` when another controller owns the Secret, and either disable `databaseProvisioning` or have that controller publish `DATABASE_URL`.

## Startup gates and external-dependency preflight

Secret gating prevents missing-key startup only; it is not a universal endpoint-readiness guarantee.

1. When bootstrap is active, the bootstrap Job waits for database, then prepares `DATABASE_URL`. It TCP-probes Redis only when chart-managed Redis is enabled (`prerequisites.redis.enabled=true`); external Redis is not TCP-probed.
2. The AFFiNE Deployment and migration Job mount optional Secret volumes. They wait for a non-empty `DATABASE_URL` and for Redis key files to exist.
3. The Deployment waits for the expected migration marker before starting the application container.

Mounted files and `secretKeyRef` environment variables use the same kubelet Secret cache, so the wait gate is designed to prevent a missing-key startup failure after its conditions pass. It does not prove Redis values are non-empty or that PostgreSQL/Redis are reachable.

With `secrets.mode=existing` plus external/platform prerequisites, bootstrap is not rendered. Verify authenticated database/PgBouncer and Redis connectivity before Helm install or Argo CD sync. Sync waves remain ordering hints, not a cross-Application readiness protocol. Jobs are normal chart resources; no Helm hooks are used.

### Job lifecycle and reconciliation limits

Jobs use checksum-bearing names, but current checksums do not cover every immutable pod-template input. Some changes can still fail as immutable Job updates; extend checksum coverage and test the release before changing helper images or runtime/security inputs.

Every Job receives `ttlSecondsAfterFinished` when `jobRetentionSeconds > 0` (default `3600`). TTL bounds retained history but removes a normal desired Job; a later Helm upgrade or Argo CD reconciliation can recreate it. The chart does not yet prove that a recreated migration Job skips work when its database marker already matches.

`jobRetentionSeconds: 0` keeps Jobs for manual adoption and prevents TTL-driven absence, at the cost of deliberate cleanup of superseded Jobs. Keep Argo CD self-heal and prune disabled until post-TTL reconciliation and migration idempotence are tested.

### Bootstrap mutation behavior

The bootstrap script uses `kubectl patch --type=merge --patch-file` for `.data.DATABASE_URL`, never `kubectl apply` or `create secret | apply`. It normally preserves unrelated Secret keys, writes temporary data with `umask 077`, and verifies the patched URL by SHA-256 without printing it. Its RBAC authority remains whole-object `patch`/`update`, and it may remove the legacy annotation described above.

## Database lifecycle

`prerequisites.database.persistencePolicy`:

* `keep` (default): the cross-namespace Everest `DatabaseCluster` gets
  `helm.sh/resource-policy: keep`. With `CONTEXT=target-kube-context`,
  `helm --kube-context "$CONTEXT" uninstall affine --namespace affine` will
  **not** delete the database or its data, and upgrading the chart will not
  remove it either.
* `delete`: explicit opt-in. Helm may delete the `DatabaseCluster` (and its
  storage) on uninstall. Do not use it unless data durability is handled
  elsewhere.

Helm retains the resource but also stops tracking future changes to it after
uninstall. **Reinstall behavior:**

* **Same release name and namespace (the usual case):** Helm adopts the retained
  `DatabaseCluster` again by name. Nothing is recreated and credentials are not
  touched. A normal install or upgrade works.
* **Different release name, or Helm cannot adopt the retained object:** set
  `prerequisites.database.existing=true` with `prerequisites.enabled=true` to
  reuse the cluster instead of rendering one. The chart then renders no
  `DatabaseCluster` at all and only consumes the endpoint.
* **Without `existing=true` and the object is owned by another release:** the
  chart fails fast with an ownership error naming both releases, rather than a
  raw `already exists` failure. Delete the cluster explicitly if you intend to
  recreate the database.

```yaml
prerequisites:
  enabled: true
  database:
    mode: everest
    existing: true   # reuse a retained/externally managed DatabaseCluster
```

`helm.sh/resource-policy: keep` means the `DatabaseCluster` outlives the release:
after uninstall it is no longer managed by Helm, so changes to its spec in a
later values file are not applied until the release is reinstalled and adopts it
(or until you manage it directly). Treat a retained cluster as a database with
its own lifecycle, not as a chart-owned object.

### Argo CD retention boundary

In supported Argo CD versions, `helm.sh/resource-policy: keep` maps to `argocd.argoproj.io/sync-options: Delete=false`, which can retain the resource during cascading Application deletion. Verify this translation against the deployed Argo CD version. It does not supply `Prune=false`: resources removed from desired state can still be pruned. Namespace deletion remains a destructive boundary for namespaced data. Keep prune disabled until explicit, tested retention controls exist.

## PersistentVolumeClaim lifecycle

Every claim supports an explicit lifecycle:

```yaml
persistence:
  storage:
    create: true          # chart renders the PVC
    existingClaim: ""     # when create=false this must name an existing claim
    retain: true          # chart-created PVCs get helm.sh/resource-policy: keep
    size: 20Gi
    storageClass: storage-nvme-c1
  config: { ... }
```

* `create: true` and `existingClaim: ""` renders a PVC named
  `<release>-storage` / `<release>-config`.
* `create: true` and `existingClaim: some-name` renders a PVC named `some-name`.
* `create: false` renders no PVC and requires `existingClaim`; the workloads
  mount it read/write.
* `existingClaim` identifies a PVC in the release namespace; PVCs cannot cross
  namespaces.
* `retain: true` adds `helm.sh/resource-policy: keep`, so `helm uninstall`
  leaves the data volume in place.

The same interface exists for prerequisites:
`prerequisites.redis.persistence.{create,existingClaim,retain}` and
`prerequisites.database.persistence.{create,existingClaim,retain}` (container
mode). Redis and container-PostgreSQL claims default to their workload names
(`affine-redis`, `db-affine-data`).

Backend-claim reuse applies only to chart-managed prerequisites after
old-release workloads are removed.

## Labels and selectors

All namespaced resources carry `app.kubernetes.io/name`,
`app.kubernetes.io/instance`, `app.kubernetes.io/managed-by` and
`helm.sh/chart`.

Deployment and Service **selectors** use only `app.kubernetes.io/name` — the
smallest stable set, byte-identical to chart `0.2.0`. `Deployment.spec.selector`
is immutable, so adding `app.kubernetes.io/instance` there (as `0.2.1`
originally did) would break every `0.2.0 → 0.2.1` upgrade with
`field is immutable` and force a destructive `helm upgrade --force`. The
release-instance label still lands on pod and resource metadata; it is simply
not part of the selector. Before Argo CD adoption, a normal Helm upgrade is therefore sufficient:

```bash
CONTEXT=target-kube-context
helm --kube-context "$CONTEXT" upgrade affine . --namespace affine -f /path/to/values.yaml \
  --wait --wait-for-jobs --timeout 15m
```

`tests/assert_render.py --selector-compat` pins the 0.2.0 selector values so a
future label change cannot silently reintroduce the immutable-field break. As a
consequence, two releases of this chart in the same namespace would select each
other's pods; run one AFFiNE release per namespace.

## Argo CD

Use direct Helm only for pre-adoption validation. After the first Argo CD sync, Argo CD is the sole reconciler: manage changes through Git, `argocd app diff`, and approved manual syncs. Do not run `helm upgrade`, `helm rollback`, or `helm uninstall` against adopted resources.

When values live in a separate platform Git repository, use multi-source and pin both source commits:

```yaml
spec:
  sources:
    - repoURL: https://github.com/Lintasarta/affine-helm.git
      targetRevision: <chart-commit-sha>
      path: .
      helm:
        valueFiles:
          - $values/manifests/affine/values/production.yaml
    - repoURL: <platform-gitops-repository>
      targetRevision: <values-commit-sha>
      ref: values
```

`ref: values` exposes `$values` at the root of the values repository. Omit `path` from that source when it supplies values only. Alternatively, keep a non-secret environment values file beside the chart and use a single pinned source. Do not attempt to load values from an unrelated repository through a relative path in a single-source Application.

Sync waves are implementation-level ordering hints, not cross-Application readiness. Inspect rendered manifests for current wave values; no Helm hooks are used. Keep `prune` and `selfHeal` disabled until job reconciliation and data-retention behavior are tested.

## Validate

```bash
./tests/chart-tests.sh
```

Static tests run `helm lint --strict`, `helm template`, values/schema
validation and rendered-manifest assertions (waits, selectors, labels, digest
pinning, Secret lifecycle, PVC lifecycle, DatabaseCluster retention, bootstrap
patch hygiene).

To also run the fresh-install / upgrade / uninstall race test against an
isolated namespace (chart-managed container PostgreSQL and Redis, no shared
database):

```bash
TEST_ID="$(date +%s)"
AFFINE_CLUSTER_TEST=1 \
AFFINE_CLUSTER_CONTEXT=tbs-dev \
AFFINE_CLUSTER_NAMESPACE="affine-chart-test-${TEST_ID}" \
AFFINE_CLUSTER_RELEASE="affine-chart-test-${TEST_ID}" \
AFFINE_CLUSTER_CLEANUP=0 \
bash tests/chart-tests.sh
```

The test uses disposable chart-managed PostgreSQL/Redis. With its default cleanup setting it deletes all PVCs in the selected namespace and then deletes that namespace. Use a unique disposable name; set `AFFINE_CLUSTER_CLEANUP=0` to inspect before deliberate cleanup. Never point it at shared or production infrastructure.

## Release

Update `Chart.yaml` (version + app version), the migration Job checksum inputs
and image digests, `values.schema.json`, the tests and `CHANGELOG.md` together.
Never commit credentials. Validate with `helm lint --strict` and
`./tests/chart-tests.sh` before creating an immutable release tag from `main`.
