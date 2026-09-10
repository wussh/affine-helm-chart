#!/usr/bin/env sh
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok %s - %s\n' "$((PASS + 1))" "$1" >&2; exit 1; }

write_kubectl_mock() {
  cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env sh
set -eu
query=$*
case "${MOCK_SECRET_MODE:-ready}" in
  absent) exit 1 ;;
  empty-host)
    case "$query" in *"['pgbouncer-host']"*) exit 0 ;; esac
    ;;
esac
case "$query" in
  *"['pgbouncer-host']"*) value=db.example ;;
  *"['pgbouncer-port']"*) value=5432 ;;
  *"['user']"*) value=admin ;;
  *"['password']"*) value=admin-password-sentinel ;;
  *"['POSTGRES_USERNAME']"*) value=app ;;
  *"['POSTGRES_PASSWORD']"*) value=app-password-sentinel ;;
  *) exit 1 ;;
esac
printf %s "$value" | base64
EOF
  chmod +x "$TMP/bin/kubectl"
}

run_secret_loader() {
  ADMIN_SECRET_NAMESPACE=admin-ns ADMIN_SECRET_NAME=admin-secret \
  ADMIN_HOST_KEY=pgbouncer-host ADMIN_PORT_KEY=pgbouncer-port \
  ADMIN_USERNAME_KEY=user ADMIN_PASSWORD_KEY=password \
  APP_SECRET_NAMESPACE=app-ns APP_SECRET_NAME=app-secret \
  APP_USERNAME_KEY=POSTGRES_USERNAME APP_PASSWORD_KEY=POSTGRES_PASSWORD \
  WAIT_INTERVAL_SECONDS=1 WAIT_TIMEOUT_SECONDS=1 SECRET_DIR="$TMP/secrets" \
  PATH="$TMP/bin:$PATH" "$ROOT/scripts/wait-and-load-secrets.sh"
}

mkdir -p "$TMP/bin"
write_kubectl_mock
if MOCK_SECRET_MODE=absent run_secret_loader >/dev/null 2>"$TMP/absent.log"; then fail 'absent Secret accepted'; fi
ok 'absent Secret times out'
if MOCK_SECRET_MODE=empty-host run_secret_loader >/dev/null 2>"$TMP/empty.log"; then fail 'empty host accepted'; fi
ok 'empty hyphenated host key times out'
MOCK_SECRET_MODE=ready run_secret_loader >/dev/null 2>"$TMP/ready.log" || fail 'ready Secrets rejected'
ok 'hyphenated keys load successfully'
[ "$(cat "$TMP/secrets/pg-host")" = db.example ] || fail 'decoded host mismatch'
ok 'decoded values written'
! grep -Fq 'admin-password-sentinel' "$TMP/ready.log" || fail 'admin secret leaked'
! grep -Fq 'app-password-sentinel' "$TMP/ready.log" || fail 'app secret leaked'
ok 'secret values absent from logs'

cat > "$TMP/bin/pg_isready" <<'EOF'
#!/usr/bin/env sh
exit "${MOCK_PG_READY_EXIT:-0}"
EOF
cat > "$TMP/bin/psql" <<'EOF'
#!/usr/bin/env sh
exit "${MOCK_PSQL_EXIT:-0}"
EOF
chmod +x "$TMP/bin/pg_isready" "$TMP/bin/psql"
if MOCK_PG_READY_EXIT=1 MOCK_PSQL_EXIT=0 PATH="$TMP/bin:$PATH" SECRET_DIR="$TMP/secrets" \
  WAIT_INTERVAL_SECONDS=1 WAIT_TIMEOUT_SECONDS=1 \
  "$ROOT/scripts/wait-postgres.sh" >/dev/null 2>"$TMP/pg-unavailable.log"; then
  fail 'PostgreSQL unavailable accepted'
fi
ok 'PostgreSQL unavailable times out'
if MOCK_PG_READY_EXIT=0 MOCK_PSQL_EXIT=1 PATH="$TMP/bin:$PATH" SECRET_DIR="$TMP/secrets" \
  WAIT_INTERVAL_SECONDS=1 WAIT_TIMEOUT_SECONDS=1 \
  "$ROOT/scripts/wait-postgres.sh" >/dev/null 2>"$TMP/pg-login-unavailable.log"; then
  fail 'PgBouncer proxy accepted without backend login'
fi
ok 'PgBouncer false-positive readiness times out'
MOCK_PG_READY_EXIT=0 MOCK_PSQL_EXIT=0 PATH="$TMP/bin:$PATH" SECRET_DIR="$TMP/secrets" \
  WAIT_INTERVAL_SECONDS=1 WAIT_TIMEOUT_SECONDS=1 \
  "$ROOT/scripts/wait-postgres.sh" >/dev/null 2>"$TMP/pg-ready.log" || fail 'PostgreSQL ready rejected'
ok 'PostgreSQL ready succeeds'
! grep -Fq 'admin-password-sentinel' "$TMP/pg-ready.log" || fail 'PostgreSQL log leaked secret'
ok 'PostgreSQL logs omit secrets'

cat > "$TMP/bin/psql" <<EOF
#!/usr/bin/env sh
cat > "$TMP/captured.sql"
printf '%s\n' "\${APP_PASSWORD:-}" > "$TMP/captured-password"
EOF
chmod +x "$TMP/bin/psql"
APP_DATABASE='db-name.with$dollar' PATH="$TMP/bin:$PATH" SECRET_DIR="$TMP/secrets" \
  "$ROOT/scripts/provision-db.sh" >/dev/null 2>"$TMP/provision.log" || fail 'provision script rejected safe identifier'
grep -Fq '\getenv app_password APP_PASSWORD' "$TMP/captured.sql" || fail 'password not passed through getenv'
grep -Fq 'ALTER DATABASE :"app_database" OWNER TO :"app_user"' "$TMP/captured.sql" || fail 'database ownership not enforced'
! grep -Fq 'app-password-sentinel' "$TMP/captured.sql" || fail 'password interpolated into SQL'
! grep -Fq 'app-password-sentinel' "$TMP/provision.log" || fail 'password leaked in provision log'
ok 'provision SQL safely supports create, repeat, rotation, ownership'

printf '1..%s\n' "$PASS"
