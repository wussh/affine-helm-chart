#!/usr/bin/env sh
# wait-postgres.sh
# Reads admin credentials from /run/affine-secrets.
# Waits for PostgreSQL (via PgBouncer) to be ready using pg_isready.
# Never prints credentials. Exits non-zero on timeout.
set -euo pipefail

# BusyBox ash supports pipefail in Alpine.

die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*" >&2; }

WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-5}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-300}"
SECRET_DIR="${SECRET_DIR:-/run/affine-secrets}"

case "$WAIT_INTERVAL_SECONDS" in ''|*[!0-9]*) die "WAIT_INTERVAL_SECONDS must be a positive integer";; esac
case "$WAIT_TIMEOUT_SECONDS" in ''|*[!0-9]*) die "WAIT_TIMEOUT_SECONDS must be a positive integer";; esac
[ "$WAIT_INTERVAL_SECONDS" -gt 0 ] || die "WAIT_INTERVAL_SECONDS must be greater than zero"
[ "$WAIT_TIMEOUT_SECONDS" -gt 0 ] || die "WAIT_TIMEOUT_SECONDS must be greater than zero"

# Read from tmpfs files (no env leak)
[ -f "$SECRET_DIR/pg-host" ]     || die "Missing ${SECRET_DIR}/pg-host"
[ -f "$SECRET_DIR/pg-port" ]     || die "Missing ${SECRET_DIR}/pg-port"
[ -f "$SECRET_DIR/pg-user" ]     || die "Missing ${SECRET_DIR}/pg-user"
[ -f "$SECRET_DIR/pg-password" ] || die "Missing ${SECRET_DIR}/pg-password"

PGHOST="$(cat "$SECRET_DIR/pg-host")"
PGPORT="$(cat "$SECRET_DIR/pg-port")"
PGUSER="$(cat "$SECRET_DIR/pg-user")"
PGPASSWORD="$(cat "$SECRET_DIR/pg-password")"
export PGHOST PGPORT PGUSER PGPASSWORD PGSSLMODE=require

info "Waiting for PostgreSQL readiness ..."

_elapsed=0
while true; do
  # PgBouncer can accept connections before backend login works. Require both
  # proxy readiness and an authenticated query to avoid false positives.
  if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres -q \
    && psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d postgres \
      -Atqc 'SELECT 1' >/dev/null 2>&1; then
    info "PostgreSQL ready."
    exit 0
  fi
  if [ "$_elapsed" -ge "$WAIT_TIMEOUT_SECONDS" ]; then
    die "Timeout (${WAIT_TIMEOUT_SECONDS}s): PostgreSQL not ready"
  fi
  sleep "$WAIT_INTERVAL_SECONDS"
  _elapsed=$((_elapsed + WAIT_INTERVAL_SECONDS))
done
