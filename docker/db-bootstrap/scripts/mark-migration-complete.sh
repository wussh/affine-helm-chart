#!/usr/bin/env sh
# Mark migration completion in the database so Deployment initContainer can gate on it.
# Writes to affine_deployment_state(key='migration-version', value=MIGRATION_VERSION).
#
# Required env vars:
#   DATABASE_URL      — postgres://user:pass@host:port/dbname
#   MIGRATION_VERSION — unique identifier for this migration run (e.g. "0.27.4-a6028ee7")
#
# Security: DATABASE_URL consumed only by psql via argv, never echoed.
# MIGRATION_VERSION is chart-controlled (not user input).
set -eu

info() { printf '[INFO]  %s\n' "$*" >&2; }

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${MIGRATION_VERSION:?MIGRATION_VERSION is required}"

info "Writing migration completion marker: version=${MIGRATION_VERSION}"

psql -v ON_ERROR_STOP=1 "$DATABASE_URL" << 'SQL'
\set ON_ERROR_STOP on
\getenv migration_version MIGRATION_VERSION

CREATE TABLE IF NOT EXISTS affine_deployment_state (
    key        text PRIMARY KEY,
    value      text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO affine_deployment_state (key, value)
VALUES ('migration-version', :'migration_version')
ON CONFLICT (key)
DO UPDATE SET
    value      = EXCLUDED.value,
    updated_at = now();
SQL

info "Marker written: migration-version=${MIGRATION_VERSION}"
