# AFFiNE Helm Install Test Cases

Chart: `affine` `0.2.1` · AFFiNE `0.27.4`

Purpose: validate a fresh direct Helm install is deterministic and never
transiently enters `CreateContainerConfigError` because `DATABASE_URL` is
missing, and validate `secrets.mode`, PVC/retention and upgrade behavior.

The preferred path is the automated suite:

```sh
./tests/chart-tests.sh
```

It runs `helm lint --strict`, `helm template`, schema/combination validation
and rendered-manifest assertions (waits, selectors, labels, digest pinning,
Secret lifecycle, PVC lifecycle, DatabaseCluster retention, bootstrap patch
hygiene).

For the cluster cases, set `AFFINE_CLUSTER_TEST=1` and point the suite at an
isolated namespace. The example values use chart-managed container PostgreSQL
and Redis, so no shared/production database is touched.

## Safety

- Use an isolated namespace and release name, never the live `affine` release.
- Use placeholder credentials only; never commit them.
- Never print Secret values, rendered `stringData`, Helm release values or pod
  environments. Do not use `--debug` on rendered output containing credentials.
- Chart-created PVCs carry `helm.sh/resource-policy: keep`; delete them
  explicitly after the test.
- `prerequisites.database.persistencePolicy=delete` is destructive; do not use
  it in tests against a shared Everest cluster.

## Test data

Container mode keeps every resource (including the database) inside the test
namespace:

```sh
cp examples/values-dev.yaml /tmp/affine-dev-values.yaml
# Optional: ./tests/chart-tests.sh already does this with these values.
```

For `secrets.mode=create` with an external database
(`prerequisites.database.mode=external`), supply `DATABASE_URL` and the Redis
keys through a private values file with `chmod 600` and delete it afterwards.

## TC-01: Static validation

```sh
helm lint --strict .
helm lint --strict . -f examples/values-dev.yaml
helm template affine-dev . -n affine-dev -f examples/values-dev.yaml >/dev/null
```

Pass: all exit `0`; images remain digest-pinned; no Secret values in default
renders (defaults render nothing).

## TC-02: Secret lifecycle

* `secrets.mode=existing`: `helm template` renders zero `Secret` objects and
  workloads reference the configured names.
* `secrets.mode=create`: database and Redis Secrets render from values; the
  database Secret may omit `DATABASE_URL` when a managed bootstrap publishes it.
* `helm template ... -f examples/values-dev.yaml --set secrets.mode=existing`
  renders zero Secrets.
* `helm template ... --set secrets.database.name=` fails with
  `secrets.database.name is required`.

## TC-03: Negative required-value checks

Each command must fail with a readable message. Never print the full render.

```sh
helm template t . -f examples/values-dev.yaml --set secrets.mode=bogus
helm template t . -f examples/values-dev.yaml --set persistence.storage.create=false
helm template t . -n affine-dev -f examples/values-dev.yaml \
  --set prerequisites.database.persistencePolicy=retain
helm template t . --set application.enabled=true --set secrets.mode=create \
  --set secrets.database.data.DATABASE_URL=
```

Expected failures: invalid mode, missing `existingClaim`, invalid persistence
policy, missing `DATABASE_URL` when no bootstrap can publish it.

## TC-04: Fresh install (race acceptance)

```sh
helm upgrade --install affine-race-test ./affine-helm-chart \
  --namespace affine-race-test --create-namespace \
  -f examples/values-dev.yaml \
  --wait --wait-for-jobs --timeout 15m
```

Acceptance: no transient for the AFFiNE Deployment or migration Job, and no
volume contention between them:

```text
CreateContainerConfigError
couldn't find key DATABASE_URL
Multi-Attach error
```

Verify from events and pod status metadata only:

```sh
kubectl -n affine-race-test get events \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' \
  | grep -Ei "CreateContainerConfigError|couldn't find key DATABASE_URL|Multi-Attach"
kubectl -n affine-race-test get pods,jobs,pvc -o wide
```

The grep must return nothing; init containers wait in `Init` state until the
bootstrap Job patches `DATABASE_URL`. The migration Job holds no
`storage`/`config` PVC, so it and the app pod can run concurrently on different
nodes.

## TC-05: Repeat upgrade

Run the TC-04 command again.

Pass: idempotent; no immutable selector errors; no Secret corruption (bootstrap
re-patches the same value and verifies it); no duplicate roles/databases (the
provisioning SQL is existence-guarded); PVC UIDs unchanged.

## TC-06: Uninstall and retention

```sh
helm uninstall affine-race-test -n affine-race-test
kubectl -n affine-race-test get deploy,job      # must be empty
kubectl -n affine-race-test get pvc             # retained PVCs remain
kubectl delete pvc --all -n affine-race-test    # explicit cleanup
kubectl delete namespace affine-race-test
```

For Everest mode with `persistencePolicy: keep`, confirm the `DatabaseCluster`
in its namespace still exists after `helm uninstall` and was not modified.

## TC-07: `secrets.mode=existing` is read-only

Render the existing-mode fixture and assert no chart-created workload or Role
can write the Secret:

```sh
helm template t . -n affine-tests -f tests/fixtures/values-everest-existing.yaml \
  | python3 tests/assert_render.py /dev/stdin --readonly-secret --no-bootstrap
```

Pass: no `bootstrap` Job, no Secret object, and no `Role` rule with a write verb
(`create`/`update`/`patch`/`delete`/`deletecollection`) on `secrets`.

Combination check — provisioning with `existing` mode and no explicit opt-in
must fail validation:

```sh
helm template t . -n affine-tests -f tests/fixtures/values-everest-existing.yaml \
  --set databaseProvisioning.enabled=true
```

Pass: exit non-zero with a message mentioning `allowBootstrapPatch=true`.

## TC-08: 0.2.0 -> 0.2.1 upgrade without `--force`

The static suite renders the `affine-0.2.0` git tag and compares
`Deployment.spec.selector.matchLabels` against the current chart. Pass: selectors
identical (`app.kubernetes.io/name` only). On a cluster, install a release with
`0.2.0`, then run a plain upgrade:

```sh
helm upgrade affine ./affine-helm-chart -n affine -f <values>
```

Pass: succeeds with no `field is immutable` error and no `--force`. Then confirm
the live selector is unchanged (`kubectl -n affine get deploy affine
-o jsonpath='{.spec.selector.matchLabels}'`).

## TC-09: Database retention and reinstall

With Everest mode and `persistencePolicy: keep`:

```sh
helm install ... ; kubectl get databasecluster -n prod db-affine   # exists
helm uninstall ... ; kubectl get databasecluster -n prod db-affine # retained
helm install ...                                                   # same name: adopted
```

Pass: the cluster and its credentials are not replaced; a reinstall under a
*different* release name must set `prerequisites.database.existing=true` to
reuse it, and otherwise fails with an ownership error naming both releases.

## Result Record

| Case | Result | Evidence |
| --- | --- | --- |
| TC-01 Static validation | [ ] | lint/render exit code |
| TC-02 Secret lifecycle | [ ] | Secret names only |
| TC-03 Required checks | [ ] | expected failures |
| TC-04 Fresh install race | [ ] | zero matching events |
| TC-05 Repeat upgrade | [ ] | upgrade/PVC UID status |
| TC-06 Uninstall retention | [ ] | PVC/DatabaseCluster absence checks |
| TC-07 existing mode read-only | [ ] | no Secret-writing Job/Role |
| TC-08 0.2.0 -> 0.2.1 no --force | [ ] | selector compare + upgrade |
| TC-09 DB retention reinstall | [ ] | DatabaseCluster UID/ownership |
