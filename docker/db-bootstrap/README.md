# affine-db-bootstrap

Utility image for AFFiNE Helm chart DB provisioning Job.

## Scripts

| Script | Purpose |
|---|---|
| `wait-and-load-secrets.sh` | Polls Kubernetes Secrets until all keys are non-empty; decodes to `/run/affine-secrets` |
| `wait-postgres.sh` | Waits for PostgreSQL/PgBouncer readiness via `pg_isready` |
| `provision-db.sh` | Creates app role + database idempotently; safe on repeated Helm upgrades |
| `wait-migration.sh` | Deployment initContainer gate on the migration completion marker written by `mark-migration-complete.sh` |
| `mark-migration-complete.sh` | Writes the `affine_deployment_state` migration marker after migrations succeed |

The chart's bootstrap Job patches `.data.DATABASE_URL` with `kubectl patch`
(never `apply`) and is defined inline in the Helm template; it does not require
a script in this image.

## Environment variables

### wait-and-load-secrets.sh
| Variable | Required | Default |
|---|---|---|
| `ADMIN_SECRET_NAMESPACE` | yes | — |
| `ADMIN_SECRET_NAME` | yes | — |
| `ADMIN_HOST_KEY` | yes | — |
| `ADMIN_PORT_KEY` | yes | — |
| `ADMIN_USERNAME_KEY` | yes | — |
| `ADMIN_PASSWORD_KEY` | yes | — |
| `APP_SECRET_NAMESPACE` | yes | — |
| `APP_SECRET_NAME` | yes | — |
| `APP_USERNAME_KEY` | yes | — |
| `APP_PASSWORD_KEY` | yes | — |
| `WAIT_INTERVAL_SECONDS` | no | `5` |
| `WAIT_TIMEOUT_SECONDS` | no | `300` |
| `SECRET_DIR` | no | `/run/affine-secrets` |

### wait-postgres.sh
Reads from `SECRET_DIR` files. Accepts `WAIT_INTERVAL_SECONDS`, `WAIT_TIMEOUT_SECONDS`, `SECRET_DIR`.

### provision-db.sh
| Variable | Required | Default |
|---|---|---|
| `APP_DATABASE` | yes | — |
| `SECRET_DIR` | no | `/run/affine-secrets` |

Reads admin + app credentials from `SECRET_DIR` files.

## Security

- No credentials baked into image
- `/run/affine-secrets` must be `emptyDir.medium: Memory` in Kubernetes
- Runs as non-root UID 10001
- `allowPrivilegeEscalation: false` must be set in pod securityContext
- Passwords never appear in process arguments or logs (use `PGPASSWORD` env / `\getenv`)

## Build

```bash
cd docker/db-bootstrap
./tests/test-scripts.sh
docker build --platform linux/amd64 -t wushie/affine-db-bootstrap:dev .
```

`tests/test-scripts.sh` uses synthetic `kubectl`, `pg_isready`, and `psql`
mocks. It verifies bounded Secret/PostgreSQL waits, hyphenated JSONPath keys,
decoding, safe SQL input, ownership enforcement, and log redaction. Production
integration still requires PostgreSQL create/repeat/password-rotation checks.
