# Changelog

## 0.2.3

- Optional Ingress TLS: `routing.ingress.tls.enabled` (default `true`). With
  `false` the Ingress renders no `spec.tls` and
  `nginx.ingress.kubernetes.io/ssl-redirect` is forced to `"false"`, so the host
  stays reachable over plain HTTP on clusters where no certificate source exists
  yet (for example a missing ClusterIssuer). Other annotations are preserved.
  `tlsSecretName` is required only when TLS is enabled (schema `if/then` plus a
  render-time guard).
- Argo CD database gate: `argocd.databaseGate` renders an opt-in `PreSync` hook
  Job that injects `DATABASE_URL` with `secretKeyRef`, parses host and port and
  probes until the database accepts TCP connections. Argo CD treats unknown CRs
  — an Everest `DatabaseCluster` — as Healthy on creation, so sync waves
  otherwise do not wait for `status.state: ready`. The hook is self-contained on
  purpose (no ServiceAccount, Role, RoleBinding, kubectl or API token): PreSync
  runs before the Sync phase, so chart-rendered RBAC would not exist yet on the
  first sync. It requires `secrets.mode: existing` with
  `databaseProvisioning.enabled=false`. Every probe attempt is bounded
  (`nc -z -w <intervalSeconds>`), so an unroutable host fails with the timeout
  message instead of hanging until the Job deadline. `helm install` ignores
  `argocd.argoproj.io/*` annotations, hence the gate is off by default.
- Bootstrap and database-provision Job names now hash their **rendered pod
  template** instead of a hand-picked value list, matching the migration Job
  pattern. Upgrading from `0.2.2` rotates those two Job names **once**, which
  re-runs the bootstrap (idempotent) and the DatabaseCluster provision step; the
  migration Job name and the migration marker are unaffected.
- `persistence.storage.annotations` / `persistence.config.annotations`: extra
  annotations for the chart-rendered claims (for example a Velero/Kasten
  selector). Ignored when `create=false`.
- New `examples/values-argocd-platform-managed.yaml`: Profile A values for a
  GitOps install (Job retention `0`, database gate enabled, `routing.mode: none`
  until an issuer exists), included in the `helm lint --strict` set.
- Tests: static suite grew from 54 to 62 assertions (Ingress TLS on/off, database
  gate present/absent, bootstrap and provision Job-name stability and rotation,
  PVC annotations).

## 0.2.2

- Safe-by-default Job retention: `jobRetentionSeconds` now defaults to `0`,
  which renders **no** `ttlSecondsAfterFinished` field and keeps completed Jobs.
  A TTL-deleted Job is a missing desired resource for Argo CD, and the next sync
  recreates it and re-runs the migration. Retention is bounded by the
  checksum-versioned Job names instead: an unchanged release reuses one Job per
  component. `jobRetentionSeconds: N` with `N > 0` still renders the field.
- Migration Job names now hash the **full rendered pod template** instead of a
  hand-picked value list. Covered: `image.repository`/`image.digest`,
  `migrationResources.*`, `securityContext.*`, `serviceAccount.*`, the bootstrap
  helper image, `secrets.database.name`/`secrets.redis.name`,
  `secrets.database.waitIntervalSeconds`/`waitTimeoutSeconds`, pod labels, and
  the new `affine.dev/migration-template-revision` annotation.
  `migration.templateRevision` is now rendered as that annotation, so bumping it
  rotates the Job name. Changes that cannot alter the pod template (routing,
  `config.*`, Service port, PVC size, application resources, probes) no longer
  rotate the name and no longer leave another Job behind. The migration marker
  version stays `<appVersion>-<podTemplateChecksum>`; the migration Job's
  `mark-complete` container and the Deployment's `wait-migration` gate now derive
  it from one helper, so they cannot disagree.
- Explicit ReadWriteOnce single-replica guard: `replicaCount > 1` fails with
  `replicaCount=N is not supported: AFFiNE stores data on ReadWriteOnce claims
  (persistence.storage/config) and has no multi-replica coordination.` The schema
  still pins `replicaCount` to `1`; the guard is the readable message for renders
  that bypass schema validation. RWX multi-replica remains unsupported.
- New `extraEnvFrom` value: extra `envFrom` sources for the AFFiNE application
  container only (for example a shared runtime ConfigMap or Secret). The
  migration Job deliberately does not inherit them; database and Redis
  configuration must still go through `secrets.*`.
- Profile A (platform-owned PostgreSQL/Redis) is lint-covered:
  `examples/values-platform-managed.yaml` is now part of `helm lint --strict`,
  and the deployment repository's overlay was replaced with the typed
  `secrets.mode=existing` contract instead of the removed top-level `envFrom` key
  that no template renders.
- Tests: the static suite grew from 27 to 54 assertions (retention semantics,
  migration-Job-name determinism and coverage matrix, marker-version equality,
  replica guard, `extraEnvFrom`) and the cluster suite adds identical-upgrade Job
  identity (name and UID unchanged, application pod not restarted) and
  PodTemplate-change rotation.

## 0.2.1

- With `secrets.mode=existing` and
  `secrets.database.allowBootstrapPatch=false`, keep external database/Redis
  Secrets read-only: the chart never creates, patches, annotates, or deletes
  them; the bootstrap Job is not rendered and no Role grants a write verb on
  those Secrets. `secrets.database.allowBootstrapPatch=true` is an explicit
  exception required for `databaseProvisioning.enabled=true` to publish
  `DATABASE_URL` into the external database Secret; `databaseProvisioning.enabled=true`
  with `existing` mode fails validation without it.
- Preserve 0.2.0 immutable Deployment selectors. `0.2.1` had added
  `app.kubernetes.io/instance` to `.spec.selector.matchLabels`, which is
  immutable and forced `helm upgrade --force` for every 0.2.0 -> 0.2.1 move. The
  selector is back to `app.kubernetes.io/name` only, byte-identical to 0.2.0,
  so a normal upgrade works; release-instance labels remain on pod/resource
  metadata. A static test falls back to the expected 0.2.0 selector literal
  and diffs selectors; it does not render the unavailable `affine-0.2.0` tag.
- Bound Job history: bootstrap, database-provision and migration Jobs carry
  `ttlSecondsAfterFinished` (`jobRetentionSeconds`, default 3600), so repeated
  upgrades no longer accumulate a Job per checksum revision.
- Harden retained `DatabaseCluster` lifecycle: `prerequisites.database.existing`
  reuses a cluster that survived uninstall via `persistencePolicy=keep`, and a
  differing-release owner is rejected with an ownership error instead of a raw
  `already exists` failure. The post-uninstall detachment is documented.
- Fix a fresh-install deadlock: the migration Job's `migrate` initContainer no
  longer mounts the Deployment's ReadWriteOnce `storage`/`config` PVCs, which
  made the two pods fight for the same claim and leave both blocked
  (`Multi-Attach error` on the migration pod, `Init:1/2` on the app pod). Those
  mounts are now node-local `emptyDir`s; predeploy migrates the database only.
- Make runtime dependencies deterministic: the AFFiNE Deployment and migration
  Job gate on the required Secret keys through an optional Secret volume before
  their containers start, so a fresh direct Helm install never produces
  `CreateContainerConfigError: couldn't find key DATABASE_URL`.
- Make `secrets.mode` the single source of truth for Secret lifecycle; remove
  the nested `secret.create` flags (database, redis and prerequisite database).
- Bootstrap merge-patches only `.data.DATABASE_URL` with
  `kubectl patch --type=merge --patch-file`, preserves unrelated data,
  verifies the result without logging the secret, and can also remove the
  legacy `kubectl.kubernetes.io/last-applied-configuration` annotation.
- Add `prerequisites.database.persistencePolicy: keep|delete` (default `keep`)
  and `helm.sh/resource-policy: keep` on the Everest `DatabaseCluster` so
  `helm uninstall` does not destroy database data.
- Add explicit PVC lifecycle: `create` / `existingClaim` / `retain` for AFFiNE
  storage, config, Redis and container PostgreSQL.
- Add strong values schema and template validation with readable errors.
- Default values now deploy nothing; add a working `examples/values-dev.yaml`.
- Add `app.kubernetes.io/instance` labels to resource metadata while preserving
  name-only workload selectors.
- Fix Redis/container-PostgreSQL pod labels so their Services select their pods.
- Remove Argo CD hook annotations and the `helmHooks` switch; Jobs are normal
  release resources ordered by sync waves at most.
- Add automated chart tests (`tests/chart-tests.sh`): static lint/template
  assertions plus an opt-in isolated-cluster fresh install, upgrade and
  uninstall test.

## 0.2.0

- Add optional Everest and container PostgreSQL prerequisites.
- Bootstrap final database credentials before migrations.
- Add checksum-versioned migration Jobs.
- Make AFFiNE and Redis updates safe for RWO volumes.
- Add dynamic Ingress and Gateway API routing.
- Add chart-managed or existing Secret modes.

## 0.1.0

- Initial minimal AFFiNE chart.
