#!/usr/bin/env sh
# Block until migration completion marker matches EXPECTED_MIGRATION_VERSION.
# Used as Deployment initContainer to prevent app from starting before migration completes.
#
# Required env vars:
#   DATABASE_URL                — postgres://user:pass@host:port/dbname
#   EXPECTED_MIGRATION_VERSION  — expected marker value (must equal what mark-migration-complete.sh wrote)
#
# Optional:
#   WAIT_INTERVAL_SECONDS  (default: 5)
#   WAIT_TIMEOUT_SECONDS   (default: 900)
set -eu

info() { printf '[INFO]  %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${EXPECTED_MIGRATION_VERSION:?EXPECTED_MIGRATION_VERSION is required}"

INTERVAL="${WAIT_INTERVAL_SECONDS:-5}"
TIMEOUT="${WAIT_TIMEOUT_SECONDS:-900}"
DEADLINE="$(($(date +%s) + TIMEOUT))"

info "Waiting for migration-version=${EXPECTED_MIGRATION_VERSION} (timeout=${TIMEOUT}s)"

while true; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    fail "TIMEOUT: migration marker not found after ${TIMEOUT}s"
  fi

  ACTUAL="$(
    psql -Atqc "
      SELECT value
      FROM affine_deployment_state
      WHERE key = 'migration-version'
      LIMIT 1
    " "$DATABASE_URL" 2>/dev/null || true
  )"

  if [ "$ACTUAL" = "$EXPECTED_MIGRATION_VERSION" ]; then
    info "Migration ready: version=${ACTUAL}"
    exit 0
  fi

  if [ -n "$ACTUAL" ]; then
    info "Marker present but version mismatch: got=${ACTUAL}, want=${EXPECTED_MIGRATION_VERSION}"
  else
    info "Marker absent or DB not ready yet; retrying in ${INTERVAL}s ..."
  fi

  sleep "$INTERVAL"
done
