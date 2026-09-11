#!/usr/bin/env python3
"""Structural assertions for rendered AFFiNE chart manifests.

Requires PyYAML. Usage:

  assert_render.py RENDERED.yaml [checks...]

Checks:
  --release NAME          Helm release name used for label/instance assertions
  --workloads             AFFiNE Deployment + migration Job wait logic
  --bootstrap             bootstrap Job exists and uses the narrow patch lifecycle
  --secrets               affine-database and affine-redis Secrets are rendered
  --no-secrets            no Secret objects are rendered
  --pvc-names A,B         these PersistentVolumeClaim names are rendered
  --no-pvc-substr S       no PVC name contains S
  --no-pvc                no PersistentVolumeClaim objects are rendered
  --databasecluster       a DatabaseCluster is rendered
  --no-databasecluster    no DatabaseCluster is rendered
  --dc-keep               DatabaseCluster carries helm.sh/resource-policy: keep
  --dc-no-keep            DatabaseCluster does not carry helm.sh/resource-policy: keep
"""
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("assert_render.py requires PyYAML (python3 -m pip install pyyaml)\n")
    sys.exit(2)

path = sys.argv[1]
args = sys.argv[2:]

release = None
flags = set()
values = {}
i = 0
while i < len(args):
    a = args[i]
    if a == "--release":
        release = args[i + 1]
        i += 2
        continue
    if a in ("--pvc-names", "--no-pvc-substr"):
        values[a] = args[i + 1].split(",")
        flags.add(a)
        i += 2
        continue
    flags.add(a)
    i += 1

raw = open(path, encoding="utf-8").read()
docs = [d for d in yaml.safe_load_all(raw) if d]
errors = []


def fail(msg):
    errors.append(msg)


def by_kind(kind):
    return [d for d in docs if d.get("kind") == kind]


def named(kind, name):
    for d in by_kind(kind):
        if d.get("metadata", {}).get("name") == name:
            return d
    return None


def containers_of(pod_spec):
    for key in ("initContainers", "containers"):
        for c in pod_spec.get(key) or []:
            yield c


def pod_specs():
    for kind in ("Deployment", "Job", "StatefulSet"):
        for d in by_kind(kind):
            spec = d.get("spec", {})
            if kind == "Job":
                yield d, spec.get("template", {}).get("spec", {})
            else:
                yield d, spec.get("template", {}).get("spec", {})


# --- generic checks -------------------------------------------------------
required_labels = {
    "app.kubernetes.io/name",
    "app.kubernetes.io/instance",
    "app.kubernetes.io/managed-by",
    "helm.sh/chart",
}
for d in docs:
    meta = d.get("metadata", {})
    kind = d.get("kind", "?")
    name = meta.get("name", "?")
    if not meta.get("name"):
        fail(f"{kind} has no metadata.name")
    missing = required_labels - set((meta.get("labels") or {}).keys())
    if missing:
        fail(f"{kind}/{name} missing labels: {sorted(missing)}")
    if not meta.get("labels", {}).get("helm.sh/chart", "").startswith("affine-"):
        fail(f"{kind}/{name} has no affine chart label")

for d in docs:
    annotations = d.get("metadata", {}).get("annotations") or {}
    if "kubectl.kubernetes.io/last-applied-configuration" in annotations:
        fail(f"{d.get('kind')}/{d.get('metadata', {}).get('name')} carries last-applied-configuration")
if "kubectl apply" in raw:
    fail("rendered output contains 'kubectl apply'")
if "--dry-run=client" in raw:
    fail("rendered output contains '--dry-run=client'")

seen_images = 0
for d, spec in pod_specs():
    kind = d.get("kind")
    name = d.get("metadata", {}).get("name")
    for c in containers_of(spec):
        image = c.get("image")
        if not image:
            continue
        seen_images += 1
        if "@sha256:" not in image:
            fail(f"{kind}/{name} container {c.get('name')} is not digest-pinned: {image}")
    pod_labels = d.get("spec", {}).get("template", {}).get("metadata", {}).get("labels") or {}
    if not pod_labels:
        fail(f"{kind}/{name} pod template has no labels")
    if kind == "Deployment":
        sel = (d.get("spec", {}).get("selector", {}) or {}).get("matchLabels") or {}
        if not sel:
            fail(f"Deployment/{name} has no selector.matchLabels")
        for k, v in sel.items():
            if pod_labels.get(k) != v:
                fail(f"Deployment/{name} selector {k}={v} does not match pod label {pod_labels.get(k)!r}")
if seen_images == 0:
    fail("no container images found in rendered output")

for svc in by_kind("Service"):
    sel = svc.get("spec", {}).get("selector")
    if not sel:
        continue
    if not any(
        all((d.get("spec", {}).get("template", {}).get("metadata", {}).get("labels") or {}).get(k) == v
            for k, v in sel.items())
        for d in by_kind("Deployment")
    ):
        fail(f"Service/{svc['metadata']['name']} selector {sel} matches no Deployment pod labels")

# --- expected objects -----------------------------------------------------
if "--workloads" in flags:
    apps = [d for d in by_kind("Deployment")
            if (d.get("metadata", {}).get("labels") or {}).get("app.kubernetes.io/name") == "affine"]
    if release:
        apps = [d for d in apps
                if (d.get("metadata", {}).get("labels") or {}).get("app.kubernetes.io/instance") == release]
    if len(apps) != 1:
        fail(f"expected exactly one AFFiNE Deployment, found {len(apps)}")
    else:
        app = apps[0]
        spec = app["spec"]["template"]["spec"]
        inits = spec.get("initContainers") or []
        init_names = [c["name"] for c in inits]
        if "wait-for-secrets" not in init_names:
            fail("AFFiNE Deployment has no wait-for-secrets initContainer")
        wait = next((c for c in inits if c["name"] == "wait-for-secrets"), None)
        if wait:
            script = "\n".join(wait.get("args") or [])
            if "DATABASE_URL" not in script:
                fail("wait-for-secrets script does not wait for DATABASE_URL")
            if "-s " not in script:
                fail("wait-for-secrets does not require a non-empty DATABASE_URL file")
            if "cat " in script:
                fail("wait-for-secrets must not print Secret contents")
            mounts = {m.get("name") for m in wait.get("volumeMounts") or []}
            if "database-secret-wait" not in mounts or "redis-secret-wait" not in mounts:
                fail("wait-for-secrets is missing secret wait volume mounts")
        vols = {v.get("name"): v for v in spec.get("volumes") or []}
        dbvol = vols.get("database-secret-wait", {}).get("secret", {})
        if dbvol.get("optional") is not True:
            fail("database-secret-wait volume must be optional:true")
        items = {it.get("key") for it in dbvol.get("items") or []}
        if "DATABASE_URL" not in items:
            fail("database-secret-wait volume must project only the DATABASE_URL key")

    mig = [j for j in by_kind("Job")
           if "-migration-" in j.get("metadata", {}).get("name", "")
           and (j.get("metadata", {}).get("labels") or {}).get("app.kubernetes.io/name") == "affine"]
    if len(mig) != 1:
        fail(f"expected exactly one migration Job, found {len(mig)}")
    else:
        m = mig[0]
        inits = m["spec"]["template"]["spec"].get("initContainers") or []
        names = [c["name"] for c in inits]
        if "wait-for-secrets" not in names:
            fail("migration Job has no wait-for-secrets initContainer")
        elif "migrate" in names and names.index("wait-for-secrets") > names.index("migrate"):
            fail("migration wait-for-secrets must run before the migrate initContainer")
        migrate = next((c for c in inits if c["name"] == "migrate"), None)
        if migrate is not None:
            env = {e["name"]: e for e in migrate.get("env") or []}
            if "DATABASE_URL" not in env or "secretKeyRef" not in env["DATABASE_URL"].get("valueFrom", {}):
                fail("migrate initContainer does not reference DATABASE_URL via secretKeyRef")
        # The migration Job must not hold the Deployment's ReadWriteOnce claims: the
        # app pod attaches them, then waits for migration to finish, so a shared
        # claim deadlocks the release with a Multi-Attach error on the other pod.
        pvc_claims = {
            v["persistentVolumeClaim"].get("claimName")
            for v in m["spec"]["template"]["spec"].get("volumes") or []
            if "persistentVolumeClaim" in v
        }
        for claim in pvc_claims:
            if claim and claim.endswith(("-storage", "-config")):
                fail(f"migration Job mounts the Deployment's storage/config PVC: {claim}")

if "--readonly-secret" in flags:
    # secrets.mode=existing without the explicit allowBootstrapPatch opt-in:
    # no chart-created workload or RBAC rule may hold a write verb on the
    # application Secret.
    for j in by_kind("Job"):
        script = "\n".join((j["spec"]["template"]["spec"]["containers"][0].get("args") or []))
        if "patch secret" in script or "apply -f" in script or "create secret" in script or "delete secret" in script:
            fail(f"read-only mode renders a Secret-writing Job: {j['metadata']['name']}")
    for role in by_kind("Role"):
        for rule in role.get("rules") or []:
            if "secrets" not in (rule.get("resources") or []):
                continue
            writes = {"create", "update", "patch", "delete", "deletecollection"} & set(rule.get("verbs") or [])
            if writes:
                fail(f"read-only mode renders Secret write verbs {sorted(writes)} in Role/{role['metadata']['name']}")

if "--no-bootstrap" in flags:
    boots = [j for j in by_kind("Job") if "-bootstrap-" in j.get("metadata", {}).get("name", "")]
    if boots:
        fail(f"no bootstrap Job expected, found {[j['metadata']['name'] for j in boots]}")
    for role in by_kind("Role"):
        for rule in role.get("rules") or []:
            if "secrets" in (rule.get("resources") or []) and \
                    {"patch", "update"} & set(rule.get("verbs") or []):
                fail(f"no bootstrap Job expected, but Role/{role['metadata']['name']} can write Secrets")

if "--job-ttl" in flags:
    # Every rendered Job must bound its own history, or repeated upgrades
    # accumulate one Job per checksum revision forever.
    for j in by_kind("Job"):
        ttl = j["spec"].get("ttlSecondsAfterFinished")
        if ttl is None:
            fail(f"Job/{j['metadata']['name']} has no ttlSecondsAfterFinished (unbounded history)")
        elif not isinstance(ttl, int) or ttl < 1:
            fail(f"Job/{j['metadata']['name']} has invalid ttlSecondsAfterFinished={ttl!r}")

if "--selector-compat" in flags:
    # Immutable Deployment selectors must stay byte-identical to 0.2.0, which
    # hardcoded app.kubernetes.io/name only. Any extra key breaks `helm upgrade`
    # with "field is immutable", forcing a destructive --force.
    expect = {
        "affine": {"app.kubernetes.io/name": "affine"},
        "affine-redis": {"app.kubernetes.io/name": "affine-redis"},
        "affine-postgres": {"app.kubernetes.io/name": "affine-postgres"},
    }
    for d in by_kind("Deployment"):
        name = d["metadata"]["name"]
        got = d["spec"]["selector"]["matchLabels"]
        want = expect.get(name)
        if want is None:
            continue
        if got != want:
            fail(f"Deployment/{name} selector changed: got {got}, 0.2.0 had {want} (immutable)")

if "--bootstrap" in flags:
    boots = [j for j in by_kind("Job") if "-bootstrap-" in j.get("metadata", {}).get("name", "")]
    if len(boots) != 1:
        fail(f"expected exactly one bootstrap Job, found {len(boots)}")
    else:
        script = "\n".join((boots[0]["spec"]["template"]["spec"]["containers"][0].get("args") or []))
        if "--type=merge" not in script:
            fail("bootstrap does not use a merge patch")
        if "--patch-file" not in script:
            fail("bootstrap does not use --patch-file")
        if "last-applied-configuration" not in script:
            fail("bootstrap does not clean up the legacy last-applied-configuration annotation")
        if "kubectl apply" in script or "--dry-run=client" in script or "create secret generic" in script:
            fail("bootstrap still uses the legacy create|apply Secret pattern")
        if "sha256sum" not in script:
            fail("bootstrap does not verify the patched DATABASE_URL without printing it")
        for bad_echo in ("echo \"$DATABASE_URL\"", "echo ${DATABASE_URL}", "echo \"$PASSWORD\"", "echo \"$USER\""):
            if bad_echo in script:
                fail(f"bootstrap prints sensitive value via {bad_echo}")

if "--secrets" in flags:
    for name in ("affine-database", "affine-redis"):
        if named("Secret", name) is None:
            fail(f"expected Secret/{name} to be rendered")
if "--no-secrets" in flags and by_kind("Secret"):
    fail("no Secret objects were expected, but some were rendered")
if "--pvc-names" in flags:
    got = {d["metadata"]["name"] for d in by_kind("PersistentVolumeClaim")}
    for name in values["--pvc-names"]:
        if name not in got:
            fail(f"expected PVC/{name} to be rendered (got {sorted(got)})")
if "--no-pvc-substr" in flags:
    for d in by_kind("PersistentVolumeClaim"):
        for sub in values["--no-pvc-substr"]:
            if sub in d["metadata"]["name"]:
                fail(f"unexpected PVC/{d['metadata']['name']} rendered")
if "--no-pvc" in flags and by_kind("PersistentVolumeClaim"):
    fail("no PVC objects were expected, but some were rendered")

dcs = by_kind("DatabaseCluster")
if "--databasecluster" in flags and not dcs:
    fail("expected a DatabaseCluster to be rendered")
if "--no-databasecluster" in flags and dcs:
    fail("no DatabaseCluster was expected")
if dcs:
    ann = dcs[0].get("metadata", {}).get("annotations") or {}
    keep = ann.get("helm.sh/resource-policy") == "keep"
    if "--dc-keep" in flags and not keep:
        fail("DatabaseCluster does not carry helm.sh/resource-policy: keep")
    if "--dc-no-keep" in flags and keep:
        fail("DatabaseCluster unexpectedly carries helm.sh/resource-policy: keep")

if errors:
    for e in errors:
        sys.stderr.write(f"assertion failed: {e}\n")
    sys.exit(1)
sys.exit(0)
