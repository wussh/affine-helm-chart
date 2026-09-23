#!/usr/bin/env bash
# Automated tests for the AFFiNE Helm chart.
#
# Static tests (default): helm lint, helm template, schema/values validation and
# rendered-manifest assertions. No cluster access required.
#
# Cluster tests (opt-in): set AFFINE_CLUSTER_TEST=1 to run a fresh install,
# an idempotent upgrade and an uninstall in an isolated namespace. The example
# values use chart-managed container PostgreSQL and Redis, so no shared or
# production database is touched. The namespace is deleted at the end.
#
#   AFFINE_CLUSTER_TEST=1 \
#   AFFINE_CLUSTER_CONTEXT=tbs-dev \
#   AFFINE_CLUSTER_NAMESPACE=affine-race-test \
#   AFFINE_CLUSTER_RELEASE=affine-race-test \
#   ./tests/chart-tests.sh
#
# Requires: helm, bash, python3 + PyYAML. Cluster tests also require kubectl.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT"
DEV="$ROOT/examples/values-dev.yaml"
FIX="$ROOT/tests/fixtures"
ASSERT="$ROOT/tests/assert_render.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok %d - %s\n' "$((pass + fail))" "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok %d - %s\n' "$((pass + fail))" "$1"; }

expect_ok() { # desc cmd...
  local desc="$1"; shift
  if "$@" >"$TMP/out" 2>"$TMP/err"; then ok "$desc"; else bad "$desc"; sed -n '1,6p' "$TMP/err"; fi
}

expect_fail_msg() { # desc pattern cmd...
  local desc="$1" pattern="$2"; shift 2
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    bad "$desc (expected failure)"
    return
  fi
  if grep -qE "$pattern" "$TMP/err"; then
    ok "$desc"
  else
    bad "$desc (error does not match '$pattern')"
    sed -n '1,8p' "$TMP/err"
  fi
}

render() { # helm template args...
  if ! helm template "$@" >"$TMP/render.yaml" 2>"$TMP/err"; then
    bad "render: helm template $*"
    sed -n '1,8p' "$TMP/err"
    return 1
  fi
  return 0
}

assert_render() { # desc assert flags...
  local desc="$1"; shift
  if python3 "$ASSERT" "$TMP/render.yaml" "$@" >"$TMP/out" 2>"$TMP/err"; then
    ok "$desc"
  else
    bad "$desc"
    sed -n '1,10p' "$TMP/err"
  fi
}

echo "# static: lint"
expect_ok "lint default values" helm lint --strict "$CHART"
expect_ok "lint examples/values-dev.yaml" helm lint --strict "$CHART" -f "$DEV"
expect_ok "lint everest existing fixture" helm lint --strict "$CHART" -f "$FIX/values-everest-existing.yaml"
expect_ok "lint everest create fixture" helm lint --strict "$CHART" -f "$FIX/values-everest-create.yaml"
expect_ok "lint existing-pvc fixture" helm lint --strict "$CHART" -f "$FIX/values-existing-pvc.yaml"
expect_ok "lint: platform-managed example" helm lint "$CHART" -f "$CHART/examples/values-platform-managed.yaml" --strict
expect_ok "lint: argocd platform-managed example" helm lint "$CHART" -f "$CHART/examples/values-argocd-platform-managed.yaml" --strict

echo "# static: default values render nothing (safe, intentionally incomplete)"
if [ -n "$(helm template affine-default "$CHART" -n affine-tests 2>"$TMP/err")" ]; then
  bad "defaults render no resources"
else
  ok "defaults render no resources"
fi

echo "# static: rendered manifests"
render affine-dev "$CHART" -n affine-dev -f "$DEV" &&
  assert_render "dev: waits, secrets, PVCs, labels, selectors" \
    --release affine-dev --workloads --bootstrap --secrets --no-databasecluster \
    --selector-compat --job-ttl-absent --gate-absent \
    --pvc-names affine-dev-storage,affine-dev-config,affine-redis,affine-postgres-data

# The chart's default values deploy nothing; a profile that forgets to enable
# the application and migration would sync an empty Application in Argo CD.
render affine-argocd "$CHART" -n affine-argocd -f "$CHART/examples/values-argocd-platform-managed.yaml" &&
  assert_render "argocd profile: application and migration are enabled" \
    --release affine-argocd --workloads --gate-present --job-ttl-absent \
    --no-databasecluster \
    --pvc-names affine-argocd-storage,affine-argocd-config

render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" &&
  assert_render "existing mode: no Secrets rendered, no Secret writes, DatabaseCluster kept" \
    --release affine-tests --workloads --no-bootstrap --no-secrets --readonly-secret \
    --databasecluster --dc-keep --gate-absent \
    --pvc-names affine-tests-storage,affine-tests-config,affine-redis

render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-delete.yaml" &&
  assert_render "delete policy: DatabaseCluster has no keep annotation" \
    --release affine-tests --databasecluster --dc-no-keep

render affine-tests "$CHART" -n affine-tests -f "$FIX/values-existing-pvc.yaml" &&
  assert_render "existing PVCs: no PVC rendered, workloads reference claims" \
    --release affine-tests --workloads --no-secrets --no-databasecluster --no-pvc

render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-create.yaml" &&
  assert_render "create mode: chart-rendered Secrets and DatabaseCluster" \
    --release affine-tests --workloads --bootstrap --secrets --databasecluster --dc-keep --job-ttl-absent

render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set prerequisites.database.existing=true &&
  assert_render "existing=true reuses retained DatabaseCluster (none rendered)" \
    --release affine-tests --no-databasecluster --no-bootstrap

echo "# static: ingress TLS"
# tls.enabled=true (default) serves TLS from tlsSecretName and keeps the default
# ssl-redirect=true annotation. tls.enabled=false renders no spec.tls at all and
# forces ssl-redirect=false while preserving the other annotations, so a cluster
# without a working certificate source can still reach the host over plain HTTP.
render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set routing.mode=ingress &&
  assert_render "ingress: TLS enabled by default uses tlsSecretName" \
    --release affine-tests --ingress-tls-secret affine-tls
render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set routing.mode=ingress --set routing.ingress.tls.enabled=false &&
  assert_render "ingress: TLS disabled renders no spec.tls and forces ssl-redirect=false" \
    --release affine-tests --ingress-no-tls

echo "# static: claim annotations"
# persistence.*.annotations land on the chart-rendered claims; a dropped
# annotation would silently break backup tooling (Velero/Kasten selectors).
render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set persistence.storage.annotations."example\.com/x"=y &&
  assert_render "PVC annotations: persistence.storage.annotations reach the claim" \
    --release affine-tests --pvc-annotation example.com/x=y

echo "# static: argocd database gate"
# argocd.databaseGate.enabled is opt-in because `helm install` ignores
# argocd.argoproj.io/* annotations. When enabled it must render the PreSync hook
# Job plus exactly the read access that Job needs on the single application
# Secret, and when disabled it must render none of those objects.
render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set argocd.databaseGate.enabled=true &&
  assert_render "gate enabled: PreSync hook Job with get-only Secret RBAC" \
    --release affine-tests --gate-present

echo "# static: job retention semantics"
# jobRetentionSeconds=0 (default) renders no ttlSecondsAfterFinished field, so a
# finished Job is never TTL-deleted and Argo CD never sees a missing desired Job
# that it would recreate (re-running the migration). > 0 renders the field.
render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" --set jobRetentionSeconds=0 &&
  assert_render "jobRetentionSeconds=0 renders no ttlSecondsAfterFinished" \
    --release affine-tests --job-ttl-absent
render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" --set jobRetentionSeconds=3600 &&
  assert_render "jobRetentionSeconds=3600 renders ttlSecondsAfterFinished=3600" \
    --release affine-tests --job-ttl-equals 3600
expect_fail_msg "reject negative jobRetentionSeconds" "jobRetentionSeconds" \
  helm template t "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" --set jobRetentionSeconds=-1

echo "# static: migration Job name determinism and coverage"
# The name hashes the rendered pod template, so every immutable Job input must
# rotate it (otherwise Helm tries an immutable Job update) and unrelated values
# must not (otherwise every config edit leaves another Job behind).
migration_job_name() {
  helm template "$@" 2>/dev/null | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Job" and "-migration-" in d["metadata"]["name"]:
        print(d["metadata"]["name"]); break'
}
BASE=(affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml")
base_name="$(migration_job_name "${BASE[@]}")"
if [ -n "$base_name" ] && [ "$base_name" = "$(migration_job_name "${BASE[@]}")" ]; then
  ok "migration Job name is deterministic across identical renders"
else
  bad "migration Job name is not deterministic ($base_name)"
fi
# must rotate
for variant in \
  "image.repository=ghcr.io/example/affine" \
  "image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000" \
  "migrationResources.limits.memory=3Gi" \
  "securityContext.runAsUser=1000" \
  "serviceAccount.name=affine-migration-sa" \
  "databaseProvisioning.image.digest=sha256:1111111111111111111111111111111111111111111111111111111111111111" \
  "secrets.database.waitTimeoutSeconds=120" \
  "secrets.database.name=other-database" \
  "secrets.redis.name=other-redis" ; do
  name="$(migration_job_name "${BASE[@]}" --set "$variant")"
  if [ -n "$name" ] && [ "$name" != "$base_name" ]; then
    ok "migration Job name changes for --set $variant"
  else
    bad "migration Job name did not change for --set $variant"
  fi
done
name="$(migration_job_name "${BASE[@]}" --set-string migration.templateRevision=9)"
if [ -n "$name" ] && [ "$name" != "$base_name" ]; then
  ok "migration Job name changes for --set-string migration.templateRevision=9"
else
  bad "migration Job name did not change for --set-string migration.templateRevision=9"
fi
# must not rotate
for variant in \
  "routing.mode=ingress" \
  "routing.host=other.example.com" \
  "config.serverName=Other" \
  "service.port=3011" \
  "persistence.storage.size=21Gi" \
  "resources.limits.memory=5Gi" \
  "probes.readiness.periodSeconds=15" ; do
  name="$(migration_job_name "${BASE[@]}" --set "$variant")"
  if [ "$name" = "$base_name" ]; then
    ok "migration Job name unchanged for --set $variant"
  else
    bad "migration Job name changed for unrelated --set $variant ($name)"
  fi
done
# The Deployment's wait-migration gate must expect exactly the marker version
# the migration Job publishes, or the application never starts.
if python3 - "$CHART" "$FIX/values-everest-existing.yaml" <<'PY'
import subprocess, sys, yaml
chart, values = sys.argv[1], sys.argv[2]
r = subprocess.run(["helm", "template", "affine-tests", chart, "-n", "affine-tests", "-f", values],
                   capture_output=True, text=True)
docs = [d for d in yaml.safe_load_all(r.stdout) if d]
job_marker = dep_marker = None
for d in docs:
    if d["kind"] == "Job" and "-migration-" in d["metadata"]["name"]:
        job_marker = next(e["value"] for c in d["spec"]["template"]["spec"]["containers"]
                          if c["name"] == "mark-complete" for e in c["env"] if e["name"] == "MIGRATION_VERSION")
    if d["kind"] == "Deployment" and d["metadata"]["name"] == "affine-tests":
        dep_marker = next(e["value"] for c in d["spec"]["template"]["spec"]["initContainers"]
                          for e in (c.get("env") or []) if e["name"] == "EXPECTED_MIGRATION_VERSION")
sys.exit(0 if job_marker and job_marker == dep_marker else 1)
PY
then
  ok "migration marker version matches the Deployment wait-migration expectation"
else
  bad "migration marker version does not match the Deployment wait-migration expectation"
fi

echo "# static: bootstrap/provision/migration Job name rotation"
# The bootstrap and provision Job names hash their rendered pod template (like
# the migration Job already does), so a pod-template change rotates only the Job
# that carries it instead of failing the update with "field is immutable", and a
# routing/config-only change rotates none of them. The anchored 8-hex suffix
# keeps the bootstrap RBAC objects (Role/<release>-bootstrap-source) out of the
# match.
job_names() { # release helm template args... (release is also helm's first argument)
  local release="$1"
  helm template "$@" 2>/dev/null |
    grep -E "^  name: ${release}-(bootstrap|database-provision|migration)-[0-9a-z.-]*[0-9a-f]{8}$" |
    sed 's/^  name: //'
}
job_named() { # pattern release helm template args...
  local pattern="$1"; shift
  job_names "$@" | grep -E -- "$pattern" | head -n 1
}
JOB_BASE=(affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-create.yaml")
base_jobs="$(job_names "${JOB_BASE[@]}")"
if [ "$(printf '%s\n' "$base_jobs" | grep -c .)" -eq 3 ] &&
   [ "$base_jobs" = "$(job_names "${JOB_BASE[@]}")" ]; then
  ok "bootstrap/provision/migration Job names are deterministic across identical renders"
else
  bad "bootstrap/provision/migration Job names are not deterministic"
fi
base_bootstrap="$(job_named '-bootstrap-' "${JOB_BASE[@]}")"
rotated_bootstrap="$(job_named '-bootstrap-' "${JOB_BASE[@]}" --set securityContext.runAsNonRoot=false)"
if [ -n "$rotated_bootstrap" ] && [ "$rotated_bootstrap" != "$base_bootstrap" ]; then
  ok "bootstrap Job name changes for --set securityContext.runAsNonRoot=false"
else
  bad "bootstrap Job name did not change for --set securityContext.runAsNonRoot=false"
fi
routed_jobs="$(job_names "${JOB_BASE[@]}" --set routing.host=other.example.com)"
if [ -n "$routed_jobs" ] && [ "$routed_jobs" = "$base_jobs" ]; then
  ok "bootstrap/provision/migration Job names unchanged for --set routing.host=other.example.com"
else
  bad "Job names changed for routing-only --set routing.host=other.example.com"
fi

echo "# static: 0.2.0 -> 0.2.1 selector compatibility"
# Deployment .spec.selector is immutable. A normal upgrade is only possible if
# the selector is byte-identical to what 0.2.0 rendered. Render the 0.2.0 tag
# directly when git can provide it; otherwise fall back to the pinned literal.
selector_compat_fixture() {
  python3 - "$CHART" "$TMP" <<'PY'
import subprocess, sys, yaml, pathlib
chart, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
out = tmp / "v020"
out.mkdir(exist_ok=True)
arch = subprocess.run(["git", "-C", chart, "archive", "affine-0.2.0"],
                      capture_output=True)
if arch.returncode != 0:
    sys.exit(3)  # tag unavailable; caller falls back
subprocess.run(["tar", "-x", "-C", str(out)], input=arch.stdout, check=True)
vals = {"application": {"enabled": True}, "migration": {"enabled": False},
        "prerequisites": {"enabled": False},
        "persistence": {"storage": {"existingClaim": "compat-storage"},
                        "config": {"existingClaim": "compat-config"}},
        "secrets": {"mode": "existing"}, "routing": {"mode": "none"}}
vf = tmp / "compat-values.yaml"
vf.write_text(yaml.safe_dump(vals))
r = subprocess.run(["helm", "template", "compat", str(out), "-n", "compat",
                    "-f", str(vf)], capture_output=True, text=True)
if r.returncode:
    sys.exit(2)
sels = {}
for d in yaml.safe_load_all(r.stdout):
    if d and d.get("kind") == "Deployment":
        sels[d["metadata"]["name"]] = d["spec"]["selector"]["matchLabels"]
(tmp / "v020-selectors.json").write_text(yaml.safe_dump(sels))
PY
}

if selector_compat_fixture; then
  # Current chart must render the identical selector for the same workloads.
  python3 - "$CHART" "$TMP" <<'PY'
import subprocess, sys, yaml, json, pathlib
chart, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
want = yaml.safe_load((tmp / "v020-selectors.json").read_text())
r = subprocess.run(["helm", "template", "compat", chart, "-n", "compat",
                    "-f", str(tmp / "compat-values.yaml")],
                   capture_output=True, text=True)
if r.returncode:
    sys.stderr.write(r.stderr)
    sys.exit(1)
got = {}
for d in yaml.safe_load_all(r.stdout):
    if d and d.get("kind") == "Deployment":
        got[d["metadata"]["name"]] = d["spec"]["selector"]["matchLabels"]
bad = {k: (want.get(k), got.get(k)) for k in want if want[k] != got.get(k)}
if bad:
    for k, (w, g) in bad.items():
        sys.stderr.write(f"immutable selector drift on Deployment/{k}: 0.2.0={w} now={g}\n")
    sys.exit(1)
PY
  if [ $? -eq 0 ]; then
    ok "0.2.0 -> 0.2.1 Deployment selectors unchanged (upgrade without --force)"
  else
    bad "0.2.0 -> 0.2.1 Deployment selector drift"
  fi
else
  # No git tag (e.g. exported tarball): assert against the known 0.2.0 literal.
  render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" &&
    assert_render "0.2.0 selector literal preserved (tag unavailable)" \
      --release affine-tests --selector-compat
fi

echo "# static: schema and combination validation"
expect_fail_msg "reject invalid secrets.mode" "secrets/mode" \
  helm template t "$CHART" -f "$DEV" --set secrets.mode=bogus
expect_fail_msg "reject empty existing database Secret name" "secrets/database/name" \
  helm template t "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" --set secrets.database.name=
expect_fail_msg "reject create mode without POSTGRES_PASSWORD" "POSTGRES_PASSWORD" \
  helm template t "$CHART" -n affine-tests -f "$FIX/values-everest-create.yaml" --set secrets.database.data.POSTGRES_PASSWORD=
expect_fail_msg "reject create mode without bootstrap and no DATABASE_URL" "DATABASE_URL is required" \
  helm template t "$CHART" -n affine-tests --set application.enabled=true --set secrets.mode=create --set secrets.database.data.DATABASE_URL=
expect_fail_msg "reject persistence.create=false without existingClaim" "existingClaim" \
  helm template t "$CHART" -f "$DEV" --set persistence.storage.create=false
expect_fail_msg "reject invalid database persistencePolicy" "persistencePolicy" \
  helm template t "$CHART" -n affine-dev -f "$DEV" --set prerequisites.database.persistencePolicy=retain
expect_fail_msg "reject removed helmHooks flag" "helmHooks" \
  helm template t "$CHART" -f "$DEV" --set helmHooks=true
expect_fail_msg "reject databaseProvisioning without prerequisites" "requires prerequisites.enabled=true" \
  helm template t "$CHART" --set application.enabled=true --set databaseProvisioning.enabled=true
expect_fail_msg "reject databaseProvisioning in container mode" "container" \
  helm template t "$CHART" -n affine-dev -f "$DEV" \
    --set databaseProvisioning.enabled=true \
    --set secrets.database.data.POSTGRES_USERNAME=placeholder \
    --set secrets.database.data.POSTGRES_PASSWORD=placeholder
expect_fail_msg "reject Secret namespace that differs from the release namespace" "must match the release namespace" \
  helm template t "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" --set secrets.database.namespace=other
expect_fail_msg "reject existing mode + provisioning without allowBootstrapPatch" "allowBootstrapPatch=true" \
  helm template t "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set databaseProvisioning.enabled=true \
    --set databaseProvisioning.admin.secretName=db-affine-bootstrap
expect_fail_msg "reject database.existing=true with mode=container" "only meaningful with prerequisites.database.mode=everest" \
  helm template t "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set prerequisites.database.existing=true \
    --set prerequisites.database.mode=container

echo "# static: ReadWriteOnce single-replica guard and extraEnvFrom"
# The schema rejects replicaCount>1 first. The template-level guard is the
# explicit message for renders that bypass schema validation, and it must name
# the real reason (ReadWriteOnce claims, no multi-replica coordination).
expect_fail_msg "reject replicaCount>1 (schema)" "replicaCount" \
  helm template t "$CHART" -f "$DEV" --set replicaCount=2
expect_fail_msg "reject replicaCount>1 with an explicit ReadWriteOnce message" "ReadWriteOnce" \
  helm template t "$CHART" -f "$DEV" --set replicaCount=2 --skip-schema-validation
render affine-tests "$CHART" -n affine-tests -f "$FIX/values-everest-existing.yaml" \
    --set extraEnvFrom[0].configMapRef.name=affine-extra-config &&
  assert_render "extraEnvFrom is rendered on the application container" \
    --release affine-tests --extra-envfrom affine-extra-config
expect_fail_msg "reject malformed extraEnvFrom entry" "extraEnvFrom" \
  helm template t "$CHART" -f "$DEV" --set extraEnvFrom[0].bogus=1
expect_fail_msg "reject database gate interval above the schema cap" "intervalSeconds" \
  helm template t "$CHART" -f "$CHART/examples/values-argocd-platform-managed.yaml" \
    --set argocd.databaseGate.intervalSeconds=61

echo "# static: credential hygiene"
if grep -RInE 'postgresql://[^<[:space:]]+:[^<[:space:]]+@' \
  "$CHART/values.yaml" "$CHART/examples" "$CHART/tests/fixtures" >"$TMP/out" 2>/dev/null; then
  bad "no plaintext connection strings committed"
  sed -n '1,5p' "$TMP/out"
else
  ok "no plaintext connection strings committed"
fi
# The bootstrap image scripts target Alpine/BusyBox sh (pipefail). On hosts
# whose /bin/sh is dash, route `#!/usr/bin/env sh` to busybox for the test run.
run_bootstrap_script_tests() {
  if ! sh -c 'set -o pipefail' 2>/dev/null && command -v busybox >/dev/null 2>&1; then
    mkdir -p "$TMP/sh-compat"
    ln -sf "$(command -v busybox)" "$TMP/sh-compat/sh"
    env "PATH=$TMP/sh-compat:$PATH" bash "$ROOT/docker/db-bootstrap/tests/test-scripts.sh" >"$TMP/docker-tests.out" 2>&1
  else
    bash "$ROOT/docker/db-bootstrap/tests/test-scripts.sh" >"$TMP/docker-tests.out" 2>&1
  fi
}
expect_ok "bootstrap image script unit tests" run_bootstrap_script_tests

if [ "${AFFINE_CLUSTER_TEST:-0}" = "1" ]; then
  echo "# cluster: fresh install, upgrade, uninstall (isolated namespace)"
  CTX="${AFFINE_CLUSTER_CONTEXT:-}"
  NS="${AFFINE_CLUSTER_NAMESPACE:-affine-race-test}"
  REL="${AFFINE_CLUSTER_RELEASE:-affine-race-test}"
  HELM_CTX=()
  KCTL=(kubectl)
  if [ -n "$CTX" ]; then
    HELM_CTX=(--kube-context "$CTX")
    KCTL=(kubectl --context "$CTX")
  fi

  expect_ok "cluster: fresh install" \
    helm "${HELM_CTX[@]}" upgrade --install "$REL" "$CHART" \
      -n "$NS" --create-namespace -f "$DEV" --wait --wait-for-jobs --timeout 15m

  events="$("${KCTL[@]}" -n "$NS" get events \
    -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null || true)"
  if printf '%s' "$events" | grep -qiE "couldn't find key DATABASE_URL|CreateContainerConfigError|Multi-Attach"; then
    bad "cluster: no CreateContainerConfigError / couldn't find key DATABASE_URL / Multi-Attach"
    printf '%s\n' "$events" | grep -iE "couldn't find key DATABASE_URL|CreateContainerConfigError|Multi-Attach" | head -5
  else
    ok "cluster: no CreateContainerConfigError / couldn't find key DATABASE_URL / Multi-Attach"
  fi

  pvc_before="$("${KCTL[@]}" -n "$NS" get pvc \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.uid}{"\n"}{end}' 2>/dev/null | sort)"

  expect_ok "cluster: idempotent upgrade" \
    helm "${HELM_CTX[@]}" upgrade --install "$REL" "$CHART" \
      -n "$NS" --create-namespace -f "$DEV" --wait --wait-for-jobs --timeout 15m

  pvc_after="$("${KCTL[@]}" -n "$NS" get pvc \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.uid}{"\n"}{end}' 2>/dev/null | sort)"
  if [ -n "$pvc_before" ] && [ "$pvc_before" = "$pvc_after" ]; then
    ok "cluster: PVCs not recreated by upgrade"
  else
    bad "cluster: PVCs recreated or missing after upgrade"
  fi

  # Repeated upgrades must not accumulate a Job per revision. With
  # jobRetentionSeconds=0 (default) nothing is TTL-deleted, and an identical
  # upgrade reuses the same checksum-named Job; only a changed pod template adds
  # one Job (the superseded one is then removed by the release diff).
  jobs_after_two_upgrades="$("${KCTL[@]}" -n "$NS" get job -o name 2>/dev/null | wc -l)"
  if [ "$jobs_after_two_upgrades" -le 4 ]; then
    ok "cluster: Job count bounded after repeated upgrades ($jobs_after_two_upgrades)"
  else
    bad "cluster: Job accumulation after repeated upgrades ($jobs_after_two_upgrades jobs)"
  fi

  # Identical upgrade with jobRetentionSeconds=0: nothing is TTL-deleted, so an
  # unchanged release must reuse the same Job object and must not restart the
  # application pod.
  mig_name="$("${KCTL[@]}" -n "$NS" get job -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -- '-migration-' | head -1)"
  mig_uid="$("${KCTL[@]}" -n "$NS" get job "$mig_name" -o jsonpath='{.metadata.uid}')"
  app_pod_uid="$("${KCTL[@]}" -n "$NS" get pods -l app.kubernetes.io/name=affine \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.uid}')"

  expect_ok "cluster: third identical upgrade (idempotency)" \
    helm "${HELM_CTX[@]}" upgrade --install "$REL" "$CHART" -n "$NS" --create-namespace \
      -f "$DEV" --wait --wait-for-jobs --timeout 15m
  if grep -qi 'field is immutable' "$TMP/err"; then
    bad "cluster: identical upgrade hit an immutable field"
  else
    ok "cluster: identical upgrade produced no immutable-field error"
  fi
  [ -n "$mig_name" ] && [ "$mig_name" = "$("${KCTL[@]}" -n "$NS" get job -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -- '-migration-' | head -1)" ] &&
    ok "cluster: identical upgrade reuses the same migration Job" ||
    bad "cluster: identical upgrade rotated the migration Job name"
  [ -n "$mig_uid" ] && [ "$mig_uid" = "$("${KCTL[@]}" -n "$NS" get job "$mig_name" -o jsonpath='{.metadata.uid}')" ] &&
    ok "cluster: migration Job was not recreated" || bad "cluster: migration Job was recreated"
  if [ "$("${KCTL[@]}" -n "$NS" get pods -l app.kubernetes.io/name=affine \
        --field-selector=status.phase=Running -o name | wc -l)" -eq 1 ] &&
     [ -n "$app_pod_uid" ] &&
     [ "$app_pod_uid" = "$("${KCTL[@]}" -n "$NS" get pods -l app.kubernetes.io/name=affine \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.uid}')" ]; then
    ok "cluster: application pod was not restarted by an identical upgrade"
  else
    bad "cluster: application pod was restarted by an identical upgrade"
  fi

  # A changed migration pod template must rotate the Job name (Helm would fail
  # an immutable Job update otherwise) and the new Job must complete.
  expect_ok "cluster: upgrade with a changed migration PodTemplate" \
    helm "${HELM_CTX[@]}" upgrade --install "$REL" "$CHART" -n "$NS" --create-namespace \
      -f "$DEV" --set migrationResources.limits.memory=3Gi --wait --wait-for-jobs --timeout 15m
  if grep -qi 'field is immutable' "$TMP/err"; then
    bad "cluster: PodTemplate change hit an immutable field"
  else
    ok "cluster: PodTemplate change produced no immutable-field error"
  fi
  mig_name_new="$("${KCTL[@]}" -n "$NS" get job -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -- '-migration-' | head -1)"
  [ -n "$mig_name_new" ] && [ "$mig_name_new" != "$mig_name" ] &&
    ok "cluster: PodTemplate change rotated the migration Job name" ||
    bad "cluster: PodTemplate change did not rotate the migration Job name"
  [ "$("${KCTL[@]}" -n "$NS" get job "$mig_name_new" -o jsonpath='{.status.succeeded}')" = "1" ] &&
    ok "cluster: new migration Job completed" || bad "cluster: new migration Job did not complete"
  # Helm removes a resource that leaves the release manifest, so a rotated
  # migration Job is replaced, not accumulated: exactly one migration Job is
  # present and it is the new one. jobRetentionSeconds=0 only prevents
  # TTL-driven deletion of a Job that is still part of the release (that is what
  # keeps a GitOps reconciler from recreating it and re-running the migration).
  mig_jobs_retained="$("${KCTL[@]}" -n "$NS" get job -o name | grep -c -- '-migration-')"
  [ "$mig_jobs_retained" -eq 1 ] &&
    ok "cluster: superseded migration Job replaced, not accumulated (jobRetentionSeconds=0)" ||
    bad "cluster: migration Job count after rotation is not 1 ($mig_jobs_retained)"

  expect_ok "cluster: uninstall" helm "${HELM_CTX[@]}" uninstall "$REL" -n "$NS"

  if [ "$("${KCTL[@]}" -n "$NS" get deploy,job -o name 2>/dev/null | wc -l)" -eq 0 ]; then
    ok "cluster: workloads deleted by uninstall"
  else
    bad "cluster: workloads remain after uninstall"
  fi
  if [ "$("${KCTL[@]}" -n "$NS" get pvc -o name 2>/dev/null | wc -l)" -ge 3 ]; then
    ok "cluster: retained PVCs remain after uninstall"
  else
    bad "cluster: retained PVCs are missing after uninstall"
  fi

  # Reinstall over the retained PVCs, using a normal `helm upgrade --install`
  # (never --force). This exercises the 0.2.0 -> 0.2.1 upgrade path because the
  # existing Deployment with the 0.2.0 selector is adopted before upgrade.
  expect_ok "cluster: reinstall over retained PVCs without --force" \
    helm "${HELM_CTX[@]}" upgrade --install "$REL" "$CHART" \
      -n "$NS" --create-namespace -f "$DEV" --wait --wait-for-jobs --timeout 15m

  if [ "$("${KCTL[@]}" -n "$NS" get deploy "$REL" \
        -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)" = '{"app.kubernetes.io/name":"affine"}' ]; then
    ok "cluster: reinstalled Deployment keeps the 0.2.0 selector"
  else
    bad "cluster: reinstalled Deployment selector changed"
  fi

  if [ "${AFFINE_CLUSTER_CLEANUP:-1}" = "1" ]; then
    # --wait=false: the reinstalled pods still mount the retained PVCs, so the
    # pvc-protection finalizer does not clear until those pods are gone and
    # waiting here would block the suite. The namespace deletion below removes
    # the pods and then the claims.
    "${KCTL[@]}" -n "$NS" delete pvc --all --wait=false >/dev/null 2>&1 || true
    "${KCTL[@]}" delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
    ok "cluster: cleanup requested (PVCs and namespace deletion)"
  fi
fi

printf '1..%d\n' "$((pass + fail))"
if [ "$fail" -gt 0 ]; then
  printf '# %d test(s) failed\n' "$fail" >&2
  exit 1
fi
printf '# all %d tests passed\n' "$pass"
