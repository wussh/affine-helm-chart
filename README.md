# AFFiNE Helm Chart

Minimal chart for AFFiNE `0.27.4`.

## Validate

```sh
helm lint --strict .
helm template dev-affine .
```

The image uses a verified manifest digest. PostgreSQL, Redis, and PVCs remain platform-managed. Set `secrets.mode=existing` to reference pre-created Secrets, or `secrets.mode=create` to have the chart render them from supplied values. Never commit credentials.

Set `prerequisites.enabled=true` to additionally render an Everest PostgreSQL `DatabaseCluster`, Redis Deployment, Redis PVC, and Redis Service. With `secrets.mode=create`, provide `POSTGRES_USERNAME` and `POSTGRES_PASSWORD`; with `existing`, create the Everest user Secret separately. The prerequisite mode does not create object-store backup credentials.

## Release

Update `Chart.yaml`, the migration Job name, image digest, schema, and `CHANGELOG.md` together. Validate before creating an immutable release tag from `master`.
