# AFFiNE Helm Chart

Minimal chart for AFFiNE `0.27.4`.

## Validate

```sh
helm lint --strict .
helm template dev-affine .
```

The image uses a verified manifest digest. PostgreSQL, Redis, and PVCs remain platform-managed. Set `secrets.mode=existing` to reference pre-created Secrets, or `secrets.mode=create` to have the chart render them from supplied values. Never commit credentials.

Set `prerequisites.enabled=true` to additionally render an Everest PostgreSQL `DatabaseCluster`, Redis Deployment, Redis PVC, and Redis Service. With `secrets.mode=create`, provide `POSTGRES_USERNAME` and `POSTGRES_PASSWORD`; the Everest user Secret is created once, then retained for operator ownership. With `existing`, create the Everest user Secret separately. The prerequisite mode does not create object-store backup credentials.

Set `prerequisites.database.mode` to `everest`, `container`, or `external`. Managed modes create a credential bootstrap Job that waits for the final database credentials and endpoint, URL-encodes them, then creates the AFFiNE runtime database Secret. Direct Helm installs can therefore create prerequisites and migration resources together; migration remains blocked until the runtime Secret exists. Container mode is intended for development, not production HA.

Migration Job names include the AFFiNE version and a configuration checksum. Increment `migration.templateRevision` whenever migration template behavior changes.

Set `routing.mode` to `ingress`, `gateway`, or `none`. Ingress mode supports a configurable class and annotations. Gateway mode renders HTTPS and HTTP-redirect `HTTPRoute` resources against a configurable parent Gateway. TLS for Gateway mode belongs to the shared Gateway listener, not this chart.

Before enabling Gateway mode, verify the parent HTTPS listener certificate covers `routing.host`. This chart does not modify a shared Gateway Certificate or Secret.

## Release

Update `Chart.yaml`, the migration Job name, image digest, schema, and `CHANGELOG.md` together. Validate before creating an immutable release tag from `master`.
