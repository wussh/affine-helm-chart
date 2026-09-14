# Changelog

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
