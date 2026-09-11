# AFFiNE Helm Chart

Minimal Helm chart for self-hosted AFFiNE `0.27.4` (chart `0.2.1`).

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
helm upgrade --install affine-dev . \
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
| `create` | The chart renders `secrets.database.name` and `secrets.redis.name` from the values in `secrets.database.data` / `secrets.redis.data`. Supply credentials through a private values file; never commit them. |
| `existing` | Strictly read-only: the chart renders **no** Secrets, and never patches, annotates, or deletes them. It only references the configured names. `DATABASE_URL` must already be present in the database Secret. Suitable for External Secrets Operator, Sealed Secrets, Vault, or any external manager. |

`secrets.mode=existing` guarantees the chart does **not** create, patch,
annotate, or delete the database or Redis Secret. No chart-created Job or Role
has a write verb on them; the bootstrap Job is not rendered at all in this mode
unless you explicitly opt in (below).

Required data keys:

| Secret | Keys |
| --- | --- |
| database (`secrets.database.name`) | `DATABASE_URL`, and `POSTGRES_USERNAME` / `POSTGRES_PASSWORD` when `databaseProvisioning.enabled=true` |
| redis (`secrets.redis.name`) | `REDIS_SERVER_HOST`, `REDIS_SERVER_PORT`, `REDIS_SERVER_USERNAME`, `REDIS_SERVER_PASSWORD`, `REDIS_SERVER_DATABASE` |

The old nested `secret.create` flags were removed. `secrets.mode` alone
controls whether Secrets are rendered, including the prerequisite database
credential Secret.

### The one deliberate opt-in: `secrets.database.allowBootstrapPatch`

`databaseProvisioning.enabled=true` creates the application role and database,
so `DATABASE_URL` cannot exist until that Job has run. With
`secrets.mode=create` the chart owns the Secret and publishes the URL itself.
With `secrets.mode=existing` that write would violate the read-only contract, so
the chart **fails validation** unless you set:

```yaml
secrets:
  mode: existing
  database:
    allowBootstrapPatch: true   # explicit: chart may patch DATABASE_URL only
```

This is not adoption: the chart still does not own, label, or delete the
Secret, and only the `DATABASE_URL` key is written. Leave it `false` (the
default) when a controller owns `DATABASE_URL`, and either disable
`databaseProvisioning` or have the controller publish the URL.

## Deterministic startup (no sync-wave dependency)

Resource ordering never depends on Argo CD annotations:

1. Prerequisites (`prerequisites.database.mode` = `everest` or `container`)
   provide the database endpoint and admin credential Secret. With
   `databaseProvisioning.enabled=true`, a Job creates the application role and
   database idempotently (`CREATE` guarded by existence checks, password
   rotation supported).
2. The bootstrap Job waits for the database (and Redis, when enabled), composes
   `DATABASE_URL` from the credentials, and patches **only**
   `.data.DATABASE_URL` into `secrets.database.name`.
3. The AFFiNE Deployment and migration Job run an init container that mounts an
   `optional: true` Secret volume projecting the required keys. It blocks until
   `DATABASE_URL` is non-empty (and the Redis keys exist), then exits.
4. The Deployment also waits for the migration completion marker before
   starting the application container.

Because the mounted files and `secretKeyRef` environment variables are resolved
from the same kubelet Secret cache, the main containers can never start before
the key exists. A fresh direct `helm install` therefore never produces
`CreateContainerConfigError: couldn't find key DATABASE_URL`; the pods wait in
`Init` state instead of crash-looping. Secret values are never printed.

`argocd.argoproj.io/sync-wave` annotations remain as Argo CD ordering hints
only. Provisioning/bootstrap/migration Jobs are normal chart resources (no
Helm hooks), so `helm upgrade --install` owns their lifecycle and Argo CD can
sync them wave by wave.

### Job history is bounded

Job names are checksum-versioned (`…-migration-<appVersion>-<checksum>`,
`…-bootstrap-<checksum>`, `…-database-provision-<checksum>`): a material template
change rotates the name, so a Job is never patched onto an immutable field.
Job names are also *not* stable across revisions, and their TTL must come from
somewhere. Every Job carries `ttlSecondsAfterFinished`:

```yaml
jobRetentionSeconds: 3600   # keep finished Jobs 1h, then let the TTL controller delete them
```

* `> 0` (default `3600`): a finished Job is deleted after that window, so
  repeated upgrades do not accumulate unbounded history. Failed Jobs stay
  inspectable for the same window, which is long enough to read logs and events.
* `0`: Jobs are kept forever. Use only if an external process needs them; the
  release will otherwise grow one Job per changed revision.

Helm does not delete a Job just because its name rotated in a later revision, so
the TTL is what bounds accumulation — not the checksum alone.

### The bootstrap patch is narrow and safe

The bootstrap Job:

* uses `kubectl patch --type=merge --patch-file` against `.data.DATABASE_URL`,
  never `kubectl apply` and never `create secret | apply`;
* keeps unrelated Secret keys untouched;
* removes a legacy `kubectl.kubernetes.io/last-applied-configuration`
  annotation if a previous chart version created one;
* writes the URL to a `umask 077` temporary file removed on exit;
* verifies the patched value by SHA-256 comparison without printing it;
* is idempotent, so repeated upgrades do not corrupt the Secret.

With `databaseProvisioning.enabled=true`, the bootstrap Job also writes the
derived `DATABASE_URL` key into the configured `secrets.database.name`. That
write only happens when the chart is allowed to patch the Secret:
`secrets.mode=create`, or `secrets.mode=existing` with
`secrets.database.allowBootstrapPatch=true`. In the default `existing` mode the
bootstrap Job is not rendered and the Secret is untouched.

## Database lifecycle

`prerequisites.database.persistencePolicy`:

* `keep` (default): the cross-namespace Everest `DatabaseCluster` gets
  `helm.sh/resource-policy: keep`. `helm uninstall affine -n affine` will
  **not** delete the database or its data, and upgrading the chart will not
  remove it either.
* `delete`: explicit opt-in. Helm may delete the `DatabaseCluster` (and its
  storage) on uninstall. Do not use it unless data durability is handled
  elsewhere.

Helm retains the resource but also stops tracking future changes to it after
uninstall. **Reinstall behavior:**

* **Same release name and namespace (the usual case):** Helm adopts the retained
  `DatabaseCluster` again by name. Nothing is recreated and credentials are not
  touched. A normal `helm install`/`helm upgrade --install` works.
* **Different release name, or Helm cannot adopt the retained object:** set
  `prerequisites.database.existing=true` to reuse the cluster instead of
  rendering one. The chart then renders no `DatabaseCluster` at all and only
  consumes the endpoint.
* **Without `existing=true` and the object is owned by another release:** the
  chart fails fast with an ownership error naming both releases, rather than a
  raw `already exists` failure. Delete the cluster explicitly if you intend to
  recreate the database.

```yaml
prerequisites:
  database:
    mode: everest
    existing: true   # reuse a retained/externally managed DatabaseCluster
```

`helm.sh/resource-policy: keep` means the `DatabaseCluster` outlives the release:
after uninstall it is no longer managed by Helm, so changes to its spec in a
later values file are not applied until the release is reinstalled and adopts it
(or until you manage it directly). Treat a retained cluster as a database with
its own lifecycle, not as a chart-owned object.

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
* `retain: true` adds `helm.sh/resource-policy: keep`, so `helm uninstall`
  leaves the data volume in place.

The same interface exists for prerequisites:
`prerequisites.redis.persistence.{create,existingClaim,retain}` and
`prerequisites.database.persistence.{create,existingClaim,retain}` (container
mode). Redis and container-PostgreSQL claims default to their workload names
(`affine-redis`, `db-affine-data`).

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
not part of the selector. A normal upgrade is therefore sufficient:

```sh
helm upgrade affine ./affine-helm-chart -n affine -f <values>
```

`tests/assert_render.py --selector-compat` pins the 0.2.0 selector values so a
future label change cannot silently reintroduce the immutable-field break. As a
consequence, two releases of this chart in the same namespace would select each
other's pods; run one AFFiNE release per namespace.

## Argo CD

The chart works with both `helm upgrade --install` and Argo CD:

* correctness comes from the waits above, not from Argo phases;
* sync waves remain for ordering (`-2` prerequisites, `-1`/`0` secrets and
  PVCs, `0` provisioning Job, `1` bootstrap Job, `2` migration Job and
  Deployment, `3` routing);
* no Helm hooks are used, so resources keep normal release ownership and are
  pruned or upgraded normally.

## Validate

```sh
./tests/chart-tests.sh
```

Static tests run `helm lint --strict`, `helm template`, values/schema
validation and rendered-manifest assertions (waits, selectors, labels, digest
pinning, Secret lifecycle, PVC lifecycle, DatabaseCluster retention, bootstrap
patch hygiene).

To also run the fresh-install / upgrade / uninstall race test against an
isolated namespace (chart-managed container PostgreSQL and Redis, no shared
database):

```sh
AFFINE_CLUSTER_TEST=1 \
AFFINE_CLUSTER_CONTEXT=tbs-dev \
AFFINE_CLUSTER_NAMESPACE=affine-race-test \
AFFINE_CLUSTER_RELEASE=affine-race-test \
./tests/chart-tests.sh
```

## Release

Update `Chart.yaml` (version + app version), the migration Job checksum inputs
and image digests, `values.schema.json`, the tests and `CHANGELOG.md` together.
Never commit credentials. Validate with `helm lint --strict` and
`./tests/chart-tests.sh` before creating an immutable release tag from `master`.
