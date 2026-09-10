# AFFiNE Helm Install Test Cases

Chart: `affine` `0.2.0` · AFFiNE `0.27.4`

Purpose: validate Helm install using inline Secret creation (`create: true`) on dev/simulation environments. Production should use external Secrets, External Secrets, Sealed Secrets, or approved Secret Manager.

## Safety

- Use dummy credentials only for simulation.
- Never commit `/tmp/affine-inline-values.yaml`.
- Never print Secret values, rendered `stringData`, Helm release values, or pod environments.
- Do not use `--debug` when rendered output could contain credentials.
- Delete test release and PVCs after test; PVCs carry `helm.sh/resource-policy: keep`.
- Run commands from chart root.

```bash
cd /home/wush/playground/affine-helm-chart-argocd-adoption
```

## Test Data

Create temporary values file with dummy values. `create: true` enables all three Helm-managed Secrets:

```bash
cat >/tmp/affine-inline-values.yaml <<'EOF'
application:
  enabled: true
migration:
  enabled: true
prerequisites:
  enabled: true
  database:
    mode: everest
    name: db-affine-test
    namespace: prod
    userSecretName: db-affine-bootstrap-test
    secret:
      create: true
      name: db-affine-bootstrap-test
      username: test_user
      password: test_password
  redis:
    enabled: true
secrets:
  mode: create
  database:
    name: affine-database-test
    namespace: affine-test
    secret:
      create: true
    data:
      DATABASE_URL: postgresql://test_user:test_password@db-affine-test-pgbouncer.prod.svc:5432/postgres
  redis:
    name: affine-redis-test
    namespace: affine-test
    secret:
      create: true
    data:
      REDIS_SERVER_HOST: affine-redis
      REDIS_SERVER_PORT: "6379"
      REDIS_SERVER_USERNAME: default
      REDIS_SERVER_PASSWORD: test_redis_password
      REDIS_SERVER_DATABASE: "0"
routing:
  mode: none
EOF
chmod 600 /tmp/affine-inline-values.yaml
```

The chart's existing `secrets.mode` remains compatibility control. Inline nested `secret.create` flags control whether each Secret renders. Use matching names in both fields.

## TC-01: Static Validation

```bash
rtk helm lint --strict . -f /tmp/affine-inline-values.yaml
rtk helm template affine-test . -n affine-test -f /tmp/affine-inline-values.yaml >/tmp/affine-inline-render.yaml
```

Pass:

- lint exit code `0`;
- render exit code `0`;
- image references remain digest-pinned;
- no mutable image tags;
- one application DB provisioning Job is rendered before migration.

Required provisioning check (fails until application DB provisioning is implemented):

```bash
rtk rg -n 'name: affine-test-database-provision|CREATE ROLE|CREATE DATABASE' /tmp/affine-inline-render.yaml
```

Do not inspect or save rendered output containing credentials. Delete it:

```bash
rm -f /tmp/affine-inline-render.yaml
```

## TC-02: Inline Secret Metadata

Use a metadata-only Kubernetes dry-run; do not print Secret objects:

```bash
rtk helm template affine-test . -n affine-test -f /tmp/affine-inline-values.yaml >/tmp/affine-inline-render.yaml
rtk awk '
  /^kind: Secret$/ {secret=1; name=""; namespace=""}
  secret && /^  name:/ {name=$2}
  secret && /^  namespace:/ {namespace=$2}
  secret && /^type:/ {print name, namespace; secret=0}
' /tmp/affine-inline-render.yaml
rm -f /tmp/affine-inline-render.yaml
```

Expected metadata only:

```text
db-affine-bootstrap-test prod
affine-database-test affine-test
affine-redis-test affine-test
```

Expected keys:

| Secret | Keys |
| --- | --- |
| `prod/db-affine-bootstrap-test` | `user`, `password` |
| `affine-test/affine-database-test` | `DATABASE_URL` |
| `affine-test/affine-redis-test` | `REDIS_SERVER_HOST`, `REDIS_SERVER_PORT`, `REDIS_SERVER_USERNAME`, `REDIS_SERVER_PASSWORD`, `REDIS_SERVER_DATABASE` |

## TC-03: Negative Required-Value Checks

Each command must fail with matching `required` message. Never print full render.

```bash
rtk helm template affine-test . -n affine-test -f /tmp/affine-inline-values.yaml \
  --set prerequisites.database.secret.username= >/tmp/out 2>/tmp/err
 test $? -ne 0
 rtk rg -n 'database.bootstrap.*username|required.*username' /tmp/err

rtk helm template affine-test . -n affine-test -f /tmp/affine-inline-values.yaml \
  --set prerequisites.database.secret.password= >/tmp/out 2>/tmp/err
 test $? -ne 0
 rtk rg -n 'database.bootstrap.*password|required.*password' /tmp/err

rtk helm template affine-test . -n affine-test -f /tmp/affine-inline-values.yaml \
  --set secrets.database.data.DATABASE_URL= >/tmp/out 2>/tmp/err
 test $? -ne 0
 rtk rg -n 'DATABASE_URL is required' /tmp/err

rtk helm template affine-test . -n affine-test -f /tmp/affine-inline-values.yaml \
  --set secrets.redis.data.REDIS_SERVER_PASSWORD= >/tmp/out 2>/tmp/err
 test $? -ne 0
 rtk rg -n 'REDIS_SERVER_PASSWORD is required' /tmp/err
rm -f /tmp/out /tmp/err
```

## TC-04: External Secret Compatibility

```bash
rtk helm lint --strict .
rtk helm template affine-external . > /tmp/affine-external-render.yaml
printf 'secret-count='
rtk rg -c '^kind: Secret$' /tmp/affine-external-render.yaml || true
rm -f /tmp/affine-external-render.yaml
```

Pass: lint succeeds; Secret count is `0`; external Secret references remain in workloads.

## TC-05: Simulation Install

Only run after confirming namespace and storage class are dedicated to this test. This creates cluster resources and dummy credentials.

```bash
rtk helm upgrade --install affine-test . \
  --namespace affine-test \
  --create-namespace \
  -f /tmp/affine-inline-values.yaml \
  --wait --wait-for-jobs --timeout 15m
```

Verify metadata/status only:

```bash
rtk kubectl --context tbs-dev -n affine-test get deploy,job,svc,pvc -o wide
rtk kubectl --context tbs-dev -n prod get databasecluster db-affine-test -o jsonpath='{.status.state}{"\n"}'
rtk kubectl --context tbs-dev -n affine-test get secret affine-database-test affine-redis-test \
  -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers
rtk kubectl --context tbs-dev -n prod get secret db-affine-bootstrap-test \
  -o custom-columns=NAME:.metadata.name,TYPE:.type --no-headers
```

Pass:

- DB ready;
- Redis Ready;
- bootstrap Job Complete;
- migration Job Complete;
- AFFiNE Deployment Available;
- expected PVCs Bound;
- Secret names/types correct; values not printed.

## TC-06: Repeat Install/Upgrade

```bash
rtk helm upgrade affine-test . -n affine-test -f /tmp/affine-inline-values.yaml \
  --wait --wait-for-jobs --timeout 15m
rtk kubectl --context tbs-dev -n affine-test get jobs -o name
```

Pass: upgrade succeeds without immutable Job failure or unintended duplicate migration.

## TC-07: Cleanup

Destructive; removes test data and dummy credentials only:

```bash
rtk helm uninstall affine-test -n affine-test
rtk kubectl --context tbs-dev -n affine-test delete pvc --all
rtk kubectl --context tbs-dev -n affine-test delete namespace affine-test --wait=true
rtk kubectl --context tbs-dev -n prod delete databasecluster db-affine-test --wait=true
rtk kubectl --context tbs-dev -n prod delete secret db-affine-bootstrap-test --ignore-not-found
rm -f /tmp/affine-inline-values.yaml /tmp/out /tmp/err
```

Verify no test resources remain:

```bash
rtk kubectl --context tbs-dev -n affine-test get all,pvc,secret
rtk kubectl --context tbs-dev -n prod get databasecluster db-affine-test secret/db-affine-bootstrap-test
```

Expected: namespace and all test resources absent; unrelated AFFiNE/platform resources untouched.

## Result Record

| Case | Result | Evidence |
| --- | --- | --- |
| TC-01 Static validation | [ ] | lint/render exit code |
| TC-02 Secret metadata | [ ] | names/namespaces/keys only |
| TC-03 Required checks | [ ] | four expected failures |
| TC-04 External mode | [ ] | zero Secrets rendered |
| TC-05 Simulation install | [ ] | DB/Redis/Jobs/Deployment/PVC status |
| TC-06 Repeat upgrade | [ ] | upgrade/job status |
| TC-07 Cleanup | [ ] | absence checks |
