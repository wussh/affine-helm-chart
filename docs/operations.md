# AFFiNE Chart — Operations Guide

Companion to the [design document](design.md) and [chart README](../README.md). This is a pre-production guide: HTTPS, workspace validation, persistence validation, and restore drill remain incomplete. Do not treat the backup section as a proven recovery runbook until the isolated drill passes.

## Target ownership and values

For `tbs-dev`, the platform GitOps surface owns `prod/db-affine` and `affine-redis`; this release consumes their namespace-local runtime Secrets. Start from [`examples/values-platform-managed.yaml`](../examples/values-platform-managed.yaml), not the legacy `envFrom` values shape.

Before installing, copy that example into the platform GitOps repository, set only non-secret environment values, and validate it:

```bash
VALUES=/path/to/platform-values.yaml
helm lint --strict . -f "$VALUES"
helm template affine . --namespace affine -f "$VALUES" >/dev/null
```

The example sets `prerequisites.enabled=false`, `databaseProvisioning.enabled=false`, and `secrets.mode=existing`. Do not enable chart prerequisites while separately managed `db-affine` or `affine-redis` objects exist.

### Argo CD values source

If production values live in the platform GitOps repository, configure an Argo CD multi-source Application. Pin both repositories to tested immutable commit SHAs:

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

`$values` resolves from the root of the source marked `ref: values`; omit `path` from that source when it supplies values only. Alternative: keep a non-secret environment values file beside the chart and use one pinned Git source. A single-source chart Application cannot load an arbitrary values file from another repository through a relative path.

## Preconditions

- Kubernetes 1.25+, Helm 3.12+ or Helm 4.x, and a known target context.
- `storage-nvme-c1` (or an approved equivalent) supports RWO claims for 20Gi blob storage and 1Gi config storage.
- Platform PostgreSQL is ready: `prod/db-affine`, PostgreSQL 16.4, internal PgBouncer, and required extensions/migration locking behavior validated.
- Platform Redis is ready, authenticated, reachable from namespace `affine`, and reserves indexes `0`–`4` for AFFiNE.
- DNS and cert-manager issuer are ready for `affine.dev.tbs.cloudeka.xyz` before enabling ingress.
- Argo CD Application pins both chart and values commits, uses manual sync, no `selfHeal`, and no prune.

In the platform-owned model the chart has no database/Redis connectivity gate: its bootstrap Job is not rendered. Prove authenticated PostgreSQL/PgBouncer and Redis connectivity from namespace `affine` before syncing, without printing connection URLs or passwords.

## Runtime Secrets

### Platform-owned production model

With `secrets.mode=existing`, create these Secrets in the release namespace before Helm/Argo CD runs:

| Secret | Required keys | Gate behavior |
| --- | --- | --- |
| `affine-database` | `DATABASE_URL` | `wait-for-secrets` requires a non-empty file; URL should target the approved PgBouncer/direct PostgreSQL endpoint. |
| `affine-redis` | `REDIS_SERVER_HOST`, `REDIS_SERVER_PORT`, `REDIS_SERVER_USERNAME`, `REDIS_SERVER_PASSWORD`, `REDIS_SERVER_DATABASE` | The init gate checks file presence only. Verify values and connectivity separately. |

Never commit or print Secret data. Database and Redis Secret references must be namespace-local; `secretKeyRef` cannot cross namespaces.

### Chart-managed database mode

`secrets.mode=create` may render application database and Redis Secrets, plus a prerequisite database credential Secret when a non-external database is chart-managed. When `databaseProvisioning.enabled=true`, the chart also needs application role credentials and an admin Secret with configured host, port, user, and password keys. Use a private values file and consult the [README Secret contract](../README.md#secrets-lifecycle) before selecting this mode.

`secrets.database.allowBootstrapPatch=true` is not a narrowly enforced one-key permission. It grants whole-object `patch`/`update` authority over the named database Secret; the current bootstrap script also may remove a legacy annotation. Keep it disabled for externally managed Secrets unless explicitly approved.

## Direct Helm validation and install — pre-adoption only

> Use direct Helm only before Argo CD adoption. Once Argo CD has performed the first sync, it is the only reconciler; use Git, `argocd app diff`, and manual Argo syncs instead.

Set an explicit target. Do not rely on a current kubeconfig context or an implicit namespace.

```bash
set -euo pipefail

CONTEXT=tbs-dev
NAMESPACE=affine
RELEASE=affine
VALUES=/path/to/platform-values.yaml
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

helm lint --strict . -f "$VALUES"
helm template "$RELEASE" . --namespace "$NAMESPACE" -f "$VALUES" >"$RENDERED"
kubectl --context "$CONTEXT" -n "$NAMESPACE" apply --dry-run=server -f "$RENDERED"

# Run only after external database, Redis, Secrets, PVC storage, and DNS/TLS
# preconditions are verified.
helm --kube-context "$CONTEXT" upgrade --install "$RELEASE" . \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$VALUES" \
  --wait --wait-for-jobs --timeout 15m
```

The development example (`examples/values-dev.yaml`) is isolated and uses chart-managed container PostgreSQL/Redis plus placeholder credentials. Never reuse it or its credentials in a shared environment.

## Argo CD adoption

- Use the pinned multi-source contract above (or co-locate values with the chart). Do not use a branch or `HEAD` for either source.
- Render exactly the same values commit used by direct Helm validation.
- Perform server-side diff review before first ownership adoption. Stop for any delete/replace of PVCs, Services, Jobs, ConfigMaps, Secrets, or the database/Redis endpoints.
- Initial policy: manual sync, `prune: false`, no `selfHeal`, no `Force=true`, no `Replace=true`.
- Sync waves do not make separately owned PostgreSQL, Redis, or Secrets healthy. Their readiness remains a preflight condition.
- Existing dev test policy (floating source, automated sync, routing disabled) is not a production template.

### Reconciler boundary

Direct Helm is allowed only before Argo CD adoption. After the first Argo CD sync, Argo CD is the sole reconciler: never run `helm upgrade`, `helm rollback`, or `helm uninstall` against that release. Upgrade by changing pinned source revisions and values, reviewing `argocd app diff`, and performing one approved manual sync.

## Upgrade and chart validation

1. Update image digest, chart/app version, schema, tests, and changelog as one reviewed release.
2. Validate both the chart and the actual target values:

   ```bash
   git diff --check
   helm lint --strict . -f "$VALUES"
   bash tests/chart-tests.sh
   helm template "$RELEASE" . --namespace "$NAMESPACE" -f "$VALUES" >/dev/null
   ```

3. Before adoption, run the direct Helm command above with the explicit context and timeout. After adoption, change the pinned Argo CD source revision/values, review `argocd app diff`, and run an approved manual sync instead.
4. Do not use `--force` to bypass immutable selector or Job failures. Investigate and correct the chart/versioned Job name instead.
5. Do not assume a completed migration cannot run again. `jobRetentionSeconds: 0` (default) keeps completed Jobs so Argo CD never sees a missing desired Job, but a Job deleted by other means is recreated on the next sync and re-runs the migration; a changed migration pod template also creates a new Job with a new name. Keep self-heal/prune disabled and use a manual rollout until post-recreation migration behavior is proven.
6. Do not roll back an image after an incompatible schema migration. Restore matching database and PVC backups instead.

### Isolated cluster test warning

`AFFINE_CLUSTER_TEST=1` uses `examples/values-dev.yaml`. It must run only in a unique, disposable namespace. By default the script deletes **all PVCs** in its test namespace and then deletes that namespace. To inspect a run before cleanup:

```bash
TEST_ID="$(date +%s)"
AFFINE_CLUSTER_TEST=1 \
AFFINE_CLUSTER_CONTEXT=tbs-dev \
AFFINE_CLUSTER_NAMESPACE="affine-chart-test-${TEST_ID}" \
AFFINE_CLUSTER_RELEASE="affine-chart-test-${TEST_ID}" \
AFFINE_CLUSTER_CLEANUP=0 \
bash tests/chart-tests.sh
```

Delete that disposable namespace and its PVCs only after inspection. Never point the test at a shared or production namespace/database.

## Post-deployment validation

Record timestamps and sanitized evidence for every result; never include document contents, passwords, URLs, or certificate private data.

1. Confirm the AFFiNE Deployment is `Available`; its Service has populated EndpointSlice(s); PVCs are `Bound`; the migration Job is `Complete`; the database is ready; and, when Redis is chart-managed, the Redis Deployment is `Available` with authenticated connectivity; otherwise verify platform-managed Redis readiness and authenticated connectivity. Inspect `wait-for-secrets` separately from `wait-migration` failures.
2. Verify DNS resolves to the intended ingress, certificate is Ready and matches the host, HTTP redirects to HTTPS, WebSocket collaboration works, and an upload below the configured body-size limit succeeds.
3. Open `https://affine.dev.tbs.cloudeka.xyz/admin`, create the initial administrator manually, store credentials in the approved password manager, and disable public registration unless required.
4. In a test workspace, create/edit/reload/reopen a document, whiteboard, and database view. Upload/download a test file. Use two browser sessions to verify collaboration synchronization.
5. For persistence, record object names/IDs and uploaded-file checksum. During an approved maintenance window, capture the config-key hash, restart AFFiNE, confirm data, restart Redis, then confirm data/session recovery and unchanged key hash:

   ```bash
   kubectl --context "$CONTEXT" -n "$NAMESPACE" exec deploy/"$RELEASE" -- \
     sha256sum /root/.affine/config/private.key
   ```

   Do not restart workloads merely to satisfy this checklist without a change window and recovery plan.

## Backup and restore — planned until drill passes

| Scope | Intended mechanism | Schedule / retention |
| --- | --- | --- |
| PostgreSQL `prod/db-affine` | Everest scheduled backup to dedicated `BackupStorage` in a separate failure domain | Daily, 30 copies |
| `affine-storage` and `affine-config` PVCs | Approved Velero, Kasten, or CSI snapshot service independent from primary storage | Daily, 30 days, same maintenance window |

Required controls:

- Backup credentials live in `prod`; runtime Secrets live in `affine`.
- Do not reuse another application's bucket/prefix. Alert on failed or stale database backups and failed/stale PVC snapshots.
- Exclude generated plaintext Secret exports from file-level backups.
- PostgreSQL and PVC snapshots are not atomic. Record the possible consistency window between database references and blob/config snapshots.
- Initial recovery targets: RPO 24 hours; restore drill quarterly; RTO is measured from the first successful drill and then adopted as the baseline.
- Record backup ID, PVC snapshot IDs, chart/image revision, database migration marker, start/end time, RPO, and RTO for every drill.

### Isolated restore drill

1. Create an isolated target namespace, database target, Redis instance, and temporary hostname. The chart fixes `replicaCount` at `1`; use the feature flags below for baseline inspection. Never use production Redis, hostname, or database during the drill.
2. Restore PostgreSQL first through the supported Everest workflow into the isolated database target.
3. Restore matching `storage` and `config` snapshots into explicitly named PVCs. Configure `persistence.*.create=false` and `existingClaim` so Helm does not create empty replacement claims.
4. Create temporary namespace-local runtime Secrets that point only to the restored database and isolated Redis; never export source Secrets into the drill record.
5. Deploy the matching chart/image revision for baseline inspection with `application.enabled=false`, `migration.enabled=false`, and `routing.mode=none`. Inspect the restored migration marker and schema. If a migration is required, run it migration-only first (`application.enabled=false`, `migration.enabled=true`, `routing.mode=none`), then enable the application afterward.
6. Enable AFFiNE only after baseline inspection and any required migration. Use a unique internal hostname and matching `externalUrl` if routing is enabled.
7. Validate administrator login, documents, whiteboards, database rows, uploaded-file checksum, and the `private.key` hash. Confirm no production workload can write to the restored target.
8. Record RPO/RTO and cleanup procedure. A real production overwrite needs a separate, approved incident runbook.

## Uninstall, retention, and reuse

In supported Argo CD versions, `helm.sh/resource-policy: keep` maps to `argocd.argoproj.io/sync-options: Delete=false`, which can retain a resource during cascading Application deletion. Verify that behavior on the deployed Argo CD version. It does not provide `Prune=false`: a resource removed from desired state can still be pruned. Namespace deletion remains destructive for namespaced data. Keep prune disabled until explicit, tested retention controls exist.

For a different release name in the same namespace, explicitly reuse every retained application claim rather than relying on Helm adoption. PVCs are namespace-scoped and cannot be reused across namespaces:

```yaml
persistence:
  storage: {create: false, existingClaim: <old-release>-storage}
  config:  {create: false, existingClaim: <old-release>-config}
prerequisites:
  redis:
    persistence: {create: false, existingClaim: affine-redis}
  database:
    # Applies only to chart-managed container PostgreSQL.
    persistence: {create: false, existingClaim: <database-name>-data}
```

The backend-claim reuse examples apply only to chart-managed prerequisites after old-release workloads are removed. Do not use them to adopt platform-owned database or Redis resources.

For a retained chart-owned Everest `DatabaseCluster`, `prerequisites.database.existing=true` requires `prerequisites.enabled=true`; use it only in a chart-owned Everest model. The platform-owned model keeps `prerequisites.enabled=false` and does not reuse prerequisite backend claims.

## Troubleshooting

| Symptom | Meaning | Action |
| --- | --- | --- |
| `wait-for-secrets` times out | `DATABASE_URL` is empty or a Redis key file is absent | Check namespace-local Secret names/keys. For Redis, verify non-empty values and actual connectivity separately. |
| `wait-migration` times out | Expected migration marker is absent, or database/migration work failed | Inspect migration Job and database state; do not treat this solely as a Secret problem. |
| Missing-key `CreateContainerConfigError` | Secret key unavailable or old chart behavior | Verify `wait-for-secrets` conditions and application Secret keys; use current chart. |
| Migration pod has `Multi-Attach` for storage/config | Old chart mounted application RWO PVCs into migration | Upgrade to the fixed migration template, which uses `emptyDir`. |
| Jobs reappear or Argo reports them OutOfSync | Job TTL removed normal desired Jobs (`jobRetentionSeconds > 0`) | Keep self-heal disabled; keep the default `jobRetentionSeconds: 0` (no TTL field, completed Jobs retained) or fix/test reconciliation behavior. |
| `DatabaseCluster ... already exists and is not owned` | Two owners or retained chart-owned Everest resource | Use one ownership model. Do not render chart prerequisites over platform-owned resources. |
| Upgrade reports immutable Job or selector field | Name/checksum did not rotate for changed immutable fields, or old selector contract | Do not use `--force`; correct the chart/release inputs and retry with a reviewed plan. |
| Two AFFiNE releases misbehave in one namespace | Name-only selector collision | Run one AFFiNE release per namespace. |

## References

- [Design document](design.md)
- [Platform-managed values example](../examples/values-platform-managed.yaml)
- [Chart README](../README.md)
- [AFFiNE self-host guide](https://docs.affine.pro/self-host-affine/)
