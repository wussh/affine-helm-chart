# AFFiNE on Kubernetes — Design Document

| Field | Value |
| --- | --- |
| Status | Pre-production; chart static suite passes, production rollout gates remain |
| Chart | `affine` `0.2.2` (AFFiNE `0.27.4`) |
| Repository | [`Lintasarta/affine-helm`](https://github.com/Lintasarta/affine-helm) |
| Target platform | `tbs-dev`, GitOps-managed through Argo CD |
| Last verified | 2026-09-21 (`bash tests/chart-tests.sh`: 54/54 static checks; opt-in cluster suite: 21/21 checks in a disposable namespace) |

## Background

Team documentation, meeting notes, and internal knowledge are scattered across multiple tools with no single, self-hosted source of truth. AFFiNE combines documents, whiteboards, and database views in one workspace and provides a self-hostable alternative to Notion and Miro.

Kubernetes deployment keeps AFFiNE aligned with the platform operating model: declarative configuration, controlled lifecycle, and Argo CD GitOps rather than a standalone Docker Compose host.

## Scope

**In scope**

- Maintained Helm chart for AFFiNE `0.27.4` in this repository.
- Platform-managed PostgreSQL and Redis for production; chart-managed containers only for isolated dev/test.
- Persistent blob and configuration storage, including AFFiNE's `private.key`.
- Internal TLS routing, Argo CD adoption, initial administrator bootstrap, functional validation, and backup/restore validation.

**Out of scope**

- Multiple AFFiNE replicas, RWX storage, and high availability.
- SSO/OIDC, SMTP, and AFFiNE AI/indexer (`pgvector` requirement unresolved).
- AFFiNE or PostgreSQL major-version upgrades.
- Selecting and operating an external Secret manager. The chart consumes externally managed Secrets through `secrets.mode=existing`; that manager is separate work.

## Deployment approach

AFFiNE does not provide an official public Helm chart intended for general self-hosting. Its `.github/helm/affine` chart serves AFFiNE Cloud, while public `toeverything/helm-charts` is unmaintained. The original task proposed `chandr-andr/affine-chart`; review found it did not meet this platform's lifecycle, Secret, and RWO-volume controls.

**Decision: maintain a minimal chart in this repository** rather than fork a stale community chart. It supplies digest-pinned images, schema and render-time validation, explicit data/Secret lifecycle controls, and automated chart tests. Version history and hardening rationale are in [`CHANGELOG.md`](../CHANGELOG.md).

## Production ownership model

The `tbs-dev` platform already owns the Everest `DatabaseCluster` and Redis through a separate GitOps surface. This Helm release must not render competing resources with the same names.

| Owner | Resources |
| --- | --- |
| Platform GitOps desired state | Namespace, `prod/db-affine` Everest `DatabaseCluster`, and `affine-redis` |
| Operator / external Secret process | Backing-service and runtime credentials populated out-of-band |
| Planned platform ownership | Dedicated backup infrastructure; it is not live yet |
| This Helm release | AFFiNE Deployment and Service, ConfigMap, AFFiNE `storage` and `config` PVCs, migration Job, optional routing, and chart-owned Secrets only when explicitly requested |

Use [`examples/values-platform-managed.yaml`](../examples/values-platform-managed.yaml) as the starting point. It is schema-valid and prevents competing backend resources:

```yaml
prerequisites:
  enabled: false
  database: {mode: external}
  redis: {enabled: false}
databaseProvisioning:
  enabled: false
secrets:
  mode: existing
```

A legacy `envFrom`-based values file is not valid for chart `0.2.1`; `envFrom` is not a supported schema key. Replace it with a validated platform-owned values file before any production sync.

### Argo CD source contract

The Argo CD Application must resolve the chart and its environment values from one reproducible source contract. Recommended: use Argo CD multi-source with both Git commits pinned:

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

`ref: values` exposes `$values` at the root of the second repository; omit `path` from that source when it is values-only. The alternative is to keep a non-secret environment values file beside the chart in this repository. Do not place production values only in a different repository and then reference them as a relative file from the chart source: a single-source Application cannot load them.

Direct Helm is allowed only before adoption. After the first Argo CD sync, Argo CD is the sole reconciler: manage changes through pinned Git revisions, `argocd app diff`, and approved manual syncs; do not run `helm upgrade`, `helm rollback`, or `helm uninstall` against adopted resources.

## Architecture

| Component | Resources | Notes |
| --- | --- | --- |
| AFFiNE | Deployment (one replica) + ClusterIP Service | Application image is digest-pinned. The default application security context sets `allowPrivilegeEscalation: false`, drops all capabilities, and uses `RuntimeDefault` seccomp; `automountServiceAccountToken: false` is chart-enforced. Application `runAsNonRoot` and read-only root filesystem are **not** currently enforced by the chart. |
| Configuration | ConfigMap | Writes `config.json` with server name and public `externalUrl`; mounted as a file over the config PVC. |
| Blob storage | PVC `<release>-storage` | Default 20Gi RWO on `storage-nvme-c1`; uploaded files and application data. |
| Config storage | PVC `<release>-config` | Default 1Gi RWO on `storage-nvme-c1`; retains `private.key`. |
| Migration | Normal Job | Runs `node ./scripts/self-host-predeploy.js`, then writes an `affine_deployment_state` marker. Uses `emptyDir`, not application RWO PVCs. |
| Bootstrap | Conditional normal Job | Renders only for a chart-managed non-external database when the chart may write the database Secret. It is absent in the platform-owned model. |
| Database provisioning | Optional normal Job | Creates the AFFiNE role/database idempotently for chart-managed Everest PostgreSQL only. |
| PostgreSQL | Everest, container, or external | Production consumes platform `prod/db-affine` (PostgreSQL 16.4, internal PgBouncer). Container mode is development-only. |
| Redis | Chart-managed or external | Production consumes platform `affine-redis`; reserve indexes `0`–`4` for AFFiNE. |
| Routing | Ingress or HTTPRoute | `routing.mode: none \| ingress \| gateway`; nginx Ingress uses cert-manager settings. |
| Validation | `values.schema.json` + `templates/validate.yaml` | `helm lint`, `helm template`, and install fail early on covered invalid combinations. |

### Startup behavior and limits

1. `wait-for-secrets` waits for a non-empty `DATABASE_URL` file and for the five Redis key files to exist. It does not verify that Redis values are non-empty or that either endpoint accepts a connection.
2. Migration and application containers use the same kubelet Secret cache as their `secretKeyRef` environment variables. This gate is intended to prevent missing-key `CreateContainerConfigError` after its conditions pass.
3. `wait-migration` blocks the application until the expected database marker exists. A wait here indicates migration/marker/database state, not necessarily a missing Secret.
4. When the bootstrap Job is active, it waits for database before composing `DATABASE_URL`. It TCP-probes Redis only when chart-managed Redis is enabled (`prerequisites.redis.enabled=true`); external Redis is not TCP-probed.

In the platform-owned model bootstrap is deliberately absent because `secrets.mode=existing` is read-only and prerequisites are external. Therefore database and Redis readiness are mandatory preflight checks before a Helm install or Argo CD sync. Sync waves are ordering hints inside one rendered Application, not a cross-Application readiness protocol.

### Secret lifecycle and privilege boundary

| Mode | Behavior |
| --- | --- |
| `create` | Chart renders application database and Redis Secrets. When it manages a non-external database, it may also render the prerequisite database credential Secret. Private values are required. |
| `existing` | By default, chart renders no Secrets and has no chart-created Secret write Role. Database and Redis Secrets must already exist in the release namespace. |

`secrets.database.allowBootstrapPatch=true` is the deliberate exception to read-only operation. It grants the bootstrap ServiceAccount `get`, `patch`, and `update` over the **entire named database Secret**. The script merge-patches `.data.DATABASE_URL` and may remove the legacy `kubectl.kubernetes.io/last-applied-configuration` annotation. It normally preserves unrelated data, but Kubernetes RBAC cannot restrict those verbs to one key. Leave this disabled for externally managed Secrets unless that full privilege boundary is accepted.

### Data lifecycle and Argo CD boundary

- PVCs expose `create`, `existingClaim`, and `retain`. `retain: true` adds `helm.sh/resource-policy: keep` and protects a claim from **Helm uninstall**.
- Everest `persistencePolicy: keep` similarly protects a chart-rendered `DatabaseCluster` from Helm uninstall.
- In supported Argo CD versions, `helm.sh/resource-policy: keep` maps to `argocd.argoproj.io/sync-options: Delete=false`. It can retain the resource during cascading Application deletion, but must be verified against the deployed Argo CD version.
- `Delete=false` does **not** provide `Prune=false`: a resource can still be pruned when it leaves desired state. Namespace deletion is also a destructive boundary for namespaced data. Keep prune disabled until explicit, tested retention controls exist for every data-bearing resource.
- The app uses name-only selectors for `0.2.0` upgrade compatibility. Run one AFFiNE release per namespace; two releases would match each other's pods.

### Job lifecycle: current production gate

Migration Job names include a hash of the rendered migration pod template, so a
pod-template change rotates the name rather than patching an immutable Job pod
template. The hash covers image repository and digest, migration resources,
container security context, ServiceAccount, helper image, database/Redis Secret
names, Secret-wait timings, pod labels, and the
`affine.dev/migration-template-revision` annotation (`migration.templateRevision`).
Unrelated values (routing, `config.*`, Service port, PVC size, application
resources, probes) do not rotate the name.

Finished Jobs are kept: `jobRetentionSeconds: 0` (default) renders no
`ttlSecondsAfterFinished` field, so a GitOps reconciler never observes a missing
desired Job and never recreates it (a recreation re-runs the migration). With
`jobRetentionSeconds: N > 0` the TTL controller removes a normal desired Job, and
a later Helm upgrade or Argo CD reconciliation can recreate it. The chart does
not prove migration work is skipped when the existing database marker already
matches, so keep Argo CD self-heal and prune disabled for initial adoption and
close the reconciliation/migration-idempotence tests before production
automation.

## Platform integration

| Area | Intended configuration | Evidence/status |
| --- | --- | --- |
| Kubernetes context | `tbs-dev` | Selected |
| Namespace | `affine` | Platform-owned; production release pending |
| PostgreSQL | Everest `prod/db-affine`, PostgreSQL 16.4, PgBouncer, ClusterIP | Manifest exists; release-namespace connectivity still needs validation |
| Redis | Dedicated authenticated Redis 7 in `affine` | Manifest exists; release-namespace connectivity still needs validation |
| Storage | RWO `storage-nvme-c1` | Test PVCs bound; production claims pending |
| Hostname | `affine.dev.tbs.cloudeka.xyz` | Selected; live DNS/Ingress/certificate confirmation pending |
| TLS | cert-manager `lets-encrypt-http-issuer` | Selected; no live certificate evidence yet |
| Argo CD | Pinned revision, manual sync, no self-heal or prune initially | Required production policy; not established by current dev test |
| PostgreSQL backups | Daily, 30 copies, dedicated Everest `BackupStorage` | Planned; no restore drill yet |
| PVC backups | Daily snapshots, 30 days, independent failure domain | Planned; no restore drill yet |

## Pre-implementation checklist

| Checklist item | Resolution |
| --- | --- |
| Review chart values coverage | Done. The original community-chart path was replaced by this maintained chart. The platform-owned example lints and templates successfully. |
| Decide PostgreSQL and Redis backend | Platform-owned Everest PostgreSQL and Redis for production; chart containers only for disposable dev/test installs. |
| Confirm PVC storage class | `storage-nvme-c1` RWO; confirmed by bound test PVCs. |
| Confirm domain and TLS | Host and issuer are selected, but live Ingress/TLS validation has not occurred. |
| Define backup schedule and retention | Database: daily, 30 copies. PVC snapshots: daily, 30 days. Both remain untested until an isolated restore drill succeeds. |

## Verification and acceptance status

### Current evidence

- `bash tests/chart-tests.sh` passed all 54 static tests in this repository on 2026-09-21 with Helm 4.2.0, and the opt-in cluster suite (`AFFINE_CLUSTER_TEST=1`, disposable namespace) passed all 21 of its checks against `tbs-dev`: fresh install, no `CreateContainerConfigError`/`Multi-Attach`, idempotent upgrade with unchanged PVC UIDs, identical-upgrade migration Job identity (name and UID unchanged, application pod not restarted), migration-Job-name rotation on a pod-template change, uninstall retention, and reinstall without `--force`. It covers linting, render assertions, schema failures, Secret/PVC lifecycle cases, Job retention and naming, and helper script tests.
- A `tbs-dev` development test release is Argo CD-tracked and runs chart `0.2.1` with container PostgreSQL and Redis. It uses a separate development source, a floating branch, automated sync, and `routing.mode=none`; it is **not** evidence for this repository's pinned-revision, manual-sync, HTTPS production policy.
- No supplied fixture renders an Ingress, and no current test proves external HTTPS, WebSocket, administrator creation, workspace features, or actual AFFiNE content persistence.

| Acceptance criterion | Status | Required evidence before closure |
| --- | --- | --- |
| Helm deployment managed by Argo CD | Partial | Apply a pinned-revision Application for this repository, review its server-side diff, then complete manual sync with no prune/self-heal. |
| Internal HTTPS access | Pending | DNS, Ready certificate, HTTP→HTTPS redirect, hostname validation, WebSocket, and upload test. |
| Admin account and functional workspace | Pending | Create administrator at `/admin`; store credentials in approved password manager; confirm registration policy. |
| Docs, whiteboards, and database views | Pending | Run [post-deployment validation](operations.md#post-deployment-validation) and record sanitized evidence. |
| Data persists across pod restarts | Pending | The cluster test preserves PVC identity through upgrade/reinstall but does not prove AFFiNE content. Restart AFFiNE and Redis after creating test data; verify content and unchanged `private.key` hash. |
| Backup and restore tested and documented | Pending | Complete the isolated restore drill in the operations guide, including measured RPO/RTO and evidence. |

## Production gates

1. Commit one valid, non-secret platform values file based on `examples/values-platform-managed.yaml`; remove unsupported legacy values and configure either pinned Argo CD multi-source or co-located chart values.
2. Prove PostgreSQL/PgBouncer and Redis connectivity from namespace `affine` before application sync.
3. Prove behavior after Jobs are deleted or retained under Argo CD reconciliation (the migration Job name now covers every pod-template input, so this is the remaining reconciliation risk).
4. Add and test Argo CD data retention before enabling prune or self-heal.
5. Keep external Secret writes disabled, or explicitly approve whole-Secret writer authority and metadata mutation.
6. Validate ingress/TLS, the admin flow, workspace features, persistence, and an isolated backup/restore drill.

## References

- [Operations guide](operations.md)
- [Platform-managed values example](../examples/values-platform-managed.yaml)
- [Repository README — option reference](../README.md)
- [Chart changelog](../CHANGELOG.md)
- [AFFiNE self-host guide](https://docs.affine.pro/self-host-affine/)
- [AFFiNE GitHub](https://github.com/toeverything/affine)
- [Kubernetes support discussion](https://github.com/toeverything/AFFiNE/discussions/6325)
- [Community chart — affine-chart](https://github.com/chandr-andr/affine-chart)
