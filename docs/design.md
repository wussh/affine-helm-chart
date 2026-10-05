# AFFiNE on Kubernetes — Design Document

| Field | Value |
| --- | --- |
| Status | Pre-production; chart static suite passes, multi-replica trial evidence below, production rollout gates remain |
| Chart | `affine` `0.2.4` (AFFiNE `0.27.4`) |
| Repository | [`Lintasarta/affine-helm`](https://github.com/Lintasarta/affine-helm) |
| Target platform | `tbs-dev`, GitOps-managed through Argo CD |
| Last verified | 2026-10-02 (`bash tests/chart-tests.sh`: 79/79 static checks with Helm 4.2.4; opt-in three-replica trial on `tbs-dev`: 28/28 cluster checks in a disposable namespace — see [Multi-replica (opt-in)](#multi-replica-opt-in)) |

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

- AFFiNE high availability as an upstream-supported topology. Multi-replica
  (`replicaCount>1`) is an opt-in, operator-tested configuration with strict
  prerequisites (see [Multi-replica (opt-in)](#multi-replica-opt-in)); it is not
  an upstream-supported AFFiNE HA claim.
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
| AFFiNE | Deployment (default one replica; opt-in `replicaCount>1`) + ClusterIP Service | Application image is digest-pinned. The default application security context sets `allowPrivilegeEscalation: false`, drops all capabilities, and uses `RuntimeDefault` seccomp; `automountServiceAccountToken: false` is chart-enforced. Application `runAsNonRoot` and read-only root filesystem are **not** currently enforced by the chart. Multi-replica requires `application.enabled=true`, `migration.enabled=true` and RWX claims (see below). |
| Configuration | ConfigMap | Writes `config.json` with server name and public `externalUrl`; mounted as a file over the config PVC. |
| Blob storage | PVC `<release>-storage` | Default 20Gi RWO on `storage-nvme-c1`; uploaded files and application data. With `replicaCount>1` it must be ReadWriteMany (operator-asserted with `create=false`). |
| Config storage | PVC `<release>-config` | Default 1Gi RWO on `storage-nvme-c1`; retains `private.key`. With `replicaCount>1` it must be ReadWriteMany and is also mounted by the migration Job, so the single predeploy run writes the key every replica reads. |
| Migration | Normal Job | Runs `node ./scripts/self-host-predeploy.js`, then writes an `affine_deployment_state` marker. `storage` volume is always `emptyDir`; the config claim is mounted only with `replicaCount>1`. |
| Session affinity | kgateway `BackendConfigPolicy` (opt-in) | With `replicaCount>1` and `routing.gateway.kgatewayCookieAffinity.enabled=true`, a consistent-hash cookie (`affine-route-affinity`) is attached to the AFFiNE Service. Rendered in `routing.mode=none` too, so it can be staged before a route exists. `HTTPRoute.spec.rules.sessionPersistence` is **not** available on the installed Gateway API CRDs and is not used. |
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

A value change that rotates the migration pod template also changes the
migration marker, and the Deployment's `wait-migration` init container compares
that marker exactly: the application pods roll once together with the migration
Job. This is intended gate behavior, not a stray restart — plan the rollout
accordingly when changing migration inputs (including `migrationResources`).

## Multi-replica (opt-in)

Chart `0.2.4` allows `replicaCount>1` as an explicit operator opt-in. AFFiNE
0.27.4 ships a Redis adapter and a job queue, but self-host multi-replica is not
documented upstream as a supported topology; this section records what the chart
enforces and what remains unproven.

Render-time contract (each violation fails naming the missing requirement, also
with `--skip-schema-validation`):

| Requirement | Why |
| --- | --- |
| `application.enabled=true`, `migration.enabled=true` | One migration Job plus the `wait-migration` gate must complete before any replica starts. |
| `persistence.storage.accessMode=ReadWriteMany` and `persistence.config.accessMode=ReadWriteMany` | Every replica mounts the same claims; a ReadWriteOnce volume attaches to a single node. With `create=false` the value is the operator's assertion about the pre-created claim — the schema cannot inspect a live PVC. |
| `routing.mode != ingress` | The nginx Ingress has no affinity implementation in this chart; the guard refuses rather than rendering a broken multi-replica route. |
| With `routing.mode=gateway`: `routing.gateway.kgatewayCookieAffinity.enabled=true` and an HTTPS `config.externalUrl` | AFFiNE clients fall back to Socket.IO HTTP polling, which needs sticky sessions; the affinity cookie is marked `Secure`. |
| Affinity flag only with `replicaCount>1` | A single replica needs no affinity; the flag is rejected at one replica and with `routing.mode=ingress`. |

Behavior with `replicaCount>1`:

- The migration Job mounts the **config** claim read-write: the single predeploy
  run writes/keeps `$HOME/.affine/config/private.key` there and every replica
  mounts the same file. The Job's `storage` volume stays an `emptyDir`.
- `examples/values-three-replicas.yaml` adds required pod anti-affinity on
  `kubernetes.io/hostname`, so a node-local RWX implementation or a single node
  failure cannot silently take down all replicas.
- The kgateway `BackendConfigPolicy` hashes on `affine-route-affinity`
  (session TTL `0s`, `Secure`, `HttpOnly`, `SameSite=Lax`, `terminal: true`).
  Hashing is soft: adding/removing backends or restarting Envoy can remap a
  polling session; the client reconnects while PostgreSQL, Redis and the RWX
  claims keep data consistent. Live check: the installed CRD
  (`gateway.kgateway.dev/v1alpha1`) supports the cookie/`ttl` fields, and
  `HTTPRoute.spec.rules.sessionPersistence` does not exist on the installed
  Gateway API CRDs.
- Rollback: scale back to one replica on the **same RWX claims** and clear the
  affinity flag (the guard rejects it at one replica). Never return to an old
  RWO claim after writes landed on the RWX claim. PVC `accessModes` are
  immutable, so promoting an existing RWO release requires new RWX claims and a
  stop-the-writer copy (PostgreSQL plus both volumes), plus a check that the old
  `private.key` exists: if it was only ever ephemeral, previously stored data
  cannot be decrypted and promotion is blocked until the encryption strategy is
  audited. Protect old claims from Argo CD prune before switching
  `existingClaim`; `helm.sh/resource-policy: keep` alone is not enough.

Trial evidence: `AFFINE_CLUSTER_MULTI_TEST=1` runs the overlay in a disposable
`tbs-dev` namespace with chart-managed dev PostgreSQL/Redis. It verifies both
claims `Bound ReadWriteMany`, three Ready pods on three distinct nodes, one
succeeded migration Job with every application container started afterwards,
identical `private.key` digests in all pods (before and after a rolling
restart), no `Multi-Attach`/`FailedAttachVolume` events, stable PVC/Job/pod UIDs
across an identical upgrade, exactly one Job rotation on a deliberate migration
PodTemplate change, and `Accepted=True`/`Attached=True` on the staged
`BackendConfigPolicy`.

## Platform integration

| Area | Intended configuration | Evidence/status |
| --- | --- | --- |
| Kubernetes context | `tbs-dev` | Selected |
| Namespace | `affine` | Platform-owned; production release pending |
| PostgreSQL | Everest `prod/db-affine`, PostgreSQL 16.4, PgBouncer, ClusterIP | Manifest exists; release-namespace connectivity still needs validation |
| Redis | Dedicated authenticated Redis 7 in `affine` | Manifest exists; release-namespace connectivity still needs validation |
| Storage | `storage-nvme-c1` (Trident CSI) | RWO default; multi-replica requires RWX on both application claims. 114 `ReadWriteMany` PVCs were `Bound` on this class at the 2026-10-02 check; production claims pending. |
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
| Confirm PVC storage class | `storage-nvme-c1` (Trident): RWO default; RWX verified for the multi-replica trial (both application claims `Bound ReadWriteMany`). |
| Confirm domain and TLS | Host and issuer are selected, but live Ingress/TLS validation has not occurred. |
| Define backup schedule and retention | Database: daily, 30 copies. PVC snapshots: daily, 30 days. Both remain untested until an isolated restore drill succeeds. |

## Verification and acceptance status

### Current evidence

- `bash tests/chart-tests.sh` passed all 79 static checks on 2026-10-02 with
  Helm 4.2.4: linting, render assertions, schema failures, the multi-replica
  contract, RWO/RWX claim assertions, migration config-volume assertions,
  kgateway policy presence/cookie attributes, HTTPRoute presence, both
  three-replica overlays, Secret/PVC lifecycle, Job retention and naming, and
  helper script tests. The one-replica cluster suite
  (`AFFINE_CLUSTER_TEST=1`) previously passed all 21 of its checks against
  `tbs-dev` (2026-09-21, Helm 4.2.0): fresh install, no
  `CreateContainerConfigError`/`Multi-Attach`, idempotent upgrade with unchanged
  PVC UIDs, identical-upgrade migration Job identity, migration-Job-name
  rotation on a pod-template change, uninstall retention, and reinstall without
  `--force`.
- The opt-in three-replica trial (`AFFINE_CLUSTER_MULTI_TEST=1`) passed 28/28
  cluster checks on `tbs-dev` on 2026-10-02 with a disposable namespace and
  chart-managed dev PostgreSQL/Redis: both application claims `Bound
  ReadWriteMany` on Trident `storage-nvme-c1`, three Ready pods on three distinct
  nodes, exactly one succeeded migration Job with the `wait-migration` gate
  passing before every affine container and Job completion before pod `Ready`,
  no `Multi-Attach`/`FailedAttachVolume`, identical `private.key` digests after
  install and after a rolling restart, an identical upgrade reusing PVC/Job/pod
  UIDs, exactly one Job rotation on a deliberate migration PodTemplate change
  (stable on the repeated upgrade), the affinity policy staged in
  `routing.mode=none` without restarting pods and reporting
  `Accepted=True`/`Attached=True`, and a rolling restart returning 3 Ready pods
  on 3 distinct nodes. The HTTPS gateway leg (cookie over TLS, Socket.IO polling
  behind kgateway, cross-pod UI/blob checks) remains pending: `tbs-dev` has no
  `ClusterIssuer`.
- A `tbs-dev` development test release is Argo CD-tracked and runs chart `0.2.1` with container PostgreSQL and Redis. It uses a separate development source, a floating branch, automated sync, and `routing.mode=none`; it is **not** evidence for this repository's pinned-revision, manual-sync, HTTPS production policy.
- No supplied fixture renders an Ingress, and no current test proves external HTTPS, WebSocket, administrator creation, workspace features, or actual AFFiNE content persistence.

| Acceptance criterion | Status | Required evidence before closure |
| --- | --- | --- |
| Helm deployment managed by Argo CD | Partial | Apply a pinned-revision Application for this repository, review its server-side diff, then complete manual sync with no prune/self-heal. |
| Internal HTTPS access | Pending | DNS, Ready certificate, HTTP→HTTPS redirect, hostname validation, WebSocket, and upload test. |
| Admin account and functional workspace | Pending | Create administrator at `/admin`; store credentials in approved password manager; confirm registration policy. |
| Docs, whiteboards, and database views | Pending | Run [post-deployment validation](operations.md#post-deployment-validation) and record sanitized evidence. |
| Data persists across pod restarts | Pending | The cluster test preserves PVC identity through upgrade/reinstall but does not prove AFFiNE content. Restart AFFiNE and Redis after creating test data; verify content and unchanged `private.key` hash. |
| Multi-replica (opt-in) trial | Passed (chart level) | Trial covers RWX mounts, `private.key`, gate ordering, upgrade idempotence, Job rotation, policy conditions and rolling restart. HTTPS gateway cookie/Socket.IO polling and cross-pod UI/blob checks remain pending until a certificate source exists. |
| Backup and restore tested and documented | Pending | Complete the isolated restore drill in the operations guide, including measured RPO/RTO and evidence. |

## Production gates

1. Commit one valid, non-secret platform values file based on `examples/values-platform-managed.yaml` (or `examples/values-argocd-platform-managed.yaml` for GitOps); remove unsupported legacy values and configure either pinned Argo CD multi-source or co-located chart values.
2. Prove PostgreSQL/PgBouncer and Redis connectivity from namespace `affine` before application sync — or enable `argocd.databaseGate.enabled=true`, which turns that preflight into a `PreSync` hook Job that waits for the database endpoint. Argo CD has no health check for `everest.percona.com/DatabaseCluster`, so without one of the two the application waves start against a database that may still be provisioning.
3. Prove behavior after Jobs are deleted or retained under Argo CD reconciliation: `jobRetentionSeconds: 0` (default) keeps completed Jobs, and all three Job names now hash their rendered pod templates, so an unchanged release recreates nothing. The remaining gate is the two-sync proof on the target release.
4. Add and test Argo CD data retention before enabling prune or self-heal.
5. Keep external Secret writes disabled, or explicitly approve whole-Secret writer authority and metadata mutation.
6. Validate ingress/TLS, the admin flow, workspace features, persistence, and an isolated backup/restore drill. Until a certificate source exists, deploy with `routing.mode: none` or `routing.ingress.tls.enabled=false`; an ingress that advertises TLS with no issuer is unreachable.
7. Multi-replica promotion (only after the three-replica trial passes and TLS exists): two ReadWriteMany claims, three schedulable nodes, isolated PostgreSQL/Redis (reserve AFFiNE Redis indexes `n`..`n+4`), the kgateway `BackendConfigPolicy` reporting `Accepted=True` **before** the HTTPRoute is opened, and a cookie/Socket.IO polling check over HTTPS. Check that no older `BackendConfigPolicy` with a `loadBalancer` block targets the same Service (kgateway priority rules) before relying on the cookie. If the old `private.key` cannot be located, block promotion of existing data until the encryption strategy is audited — previously stored data cannot be decrypted without it.
8. Never change PVC `accessModes` in place and never point the multi-replica overlay at a release whose claims are ReadWriteOnce. Promotion requires **new** RWX claims plus a stop-the-writer copy (PostgreSQL, storage, config) with a key-hash check, and the old claims must be protected from Argo CD prune before `existingClaim` is switched.
9. Treat consistent hashing as soft affinity: clients reconnect when the backend set changes. Do not use the unavailable `HTTPRoute.spec.rules.sessionPersistence` field as a workaround; fix the platform prerequisite separately.

### Deferred: External Secrets

`secrets.mode` supports `create` (chart-owned, development) and `existing`
(read-only, production). A third mode that renders `ExternalSecret` CRs
(`secretStoreRef`, `refreshInterval`, `dataFrom`) is deliberately **not**
implemented: no External Secrets or Sealed Secrets operator is installed on the
target platform today. Revisit once a secret operator exists — until then,
platform-managed Secrets stay an out-of-band prerequisite and are never
committed to Git.

## References

- [Operations guide](operations.md)
- [Platform-managed values example](../examples/values-platform-managed.yaml)
- [Repository README — option reference](../README.md)
- [Chart changelog](../CHANGELOG.md)
- [AFFiNE self-host guide](https://docs.affine.pro/self-host-affine/)
- [AFFiNE GitHub](https://github.com/toeverything/affine)
- [Kubernetes support discussion](https://github.com/toeverything/AFFiNE/discussions/6325)
- [Community chart — affine-chart](https://github.com/chandr-andr/affine-chart)
