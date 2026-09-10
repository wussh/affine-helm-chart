#!/usr/bin/env sh
# provision-db.sh
# Reads admin and app credentials from /run/affine-secrets.
# Creates the app role and database idempotently. Safe on repeated runs.
# Passwords handled via psql \getenv — never interpolated into SQL strings.
# Never prints credentials.
set -euo pipefail

# BusyBox ash supports pipefail in Alpine.

die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*" >&2; }

require_env() {
  for _v; do
    eval "_val=\"\${${_v}:-}\""
    [ -n "$_val" ] || die "Required env var not set: ${_v}"
  done
}

require_env APP_DATABASE

SECRET_DIR="${SECRET_DIR:-/run/affine-secrets}"

[ -f "$SECRET_DIR/pg-host" ]      || die "Missing ${SECRET_DIR}/pg-host"
[ -f "$SECRET_DIR/pg-port" ]      || die "Missing ${SECRET_DIR}/pg-port"
[ -f "$SECRET_DIR/pg-user" ]      || die "Missing ${SECRET_DIR}/pg-user"
[ -f "$SECRET_DIR/pg-password" ]  || die "Missing ${SECRET_DIR}/pg-password"
[ -f "$SECRET_DIR/app-user" ]     || die "Missing ${SECRET_DIR}/app-user"
[ -f "$SECRET_DIR/app-password" ] || die "Missing ${SECRET_DIR}/app-password"

# Export pg env vars — PGPASSWORD from file, never from a command-line arg
export PGHOST="$(cat "$SECRET_DIR/pg-host")"
export PGPORT="$(cat "$SECRET_DIR/pg-port")"
export PGUSER="$(cat "$SECRET_DIR/pg-user")"
export PGPASSWORD="$(cat "$SECRET_DIR/pg-password")"
export PGSSLMODE=require

# App credentials exported for \getenv in SQL
export APP_USER="$(cat "$SECRET_DIR/app-user")"
export APP_PASSWORD="$(cat "$SECRET_DIR/app-password")"
# APP_DATABASE comes from env (Helm value), validated above

info "Provisioning application database ..."

# psql variables provide safe identifier/literal quoting without printing
# generated SQL (especially passwords) to the client log.
psql -v ON_ERROR_STOP=1 -d postgres << 'SQL'
\set ON_ERROR_STOP on
\getenv app_user     APP_USER
\getenv app_password APP_PASSWORD
\getenv app_database APP_DATABASE

-- Create role if absent. \gset suppresses query output.
SELECT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'app_user'
) AS role_exists \gset
\if :role_exists
\else
  CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password';
\endif

-- Ensure password is current (supports rotation).
ALTER ROLE :"app_user" LOGIN PASSWORD :'app_password';

-- CREATE DATABASE cannot run inside a transaction; psql executes it directly.
SELECT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = :'app_database'
) AS database_exists \gset
\if :database_exists
\else
  CREATE DATABASE :"app_database" OWNER :"app_user";
\endif

-- Ensure existing databases also become application-owned (idempotent).
ALTER DATABASE :"app_database" OWNER TO :"app_user";
GRANT ALL PRIVILEGES ON DATABASE :"app_database" TO :"app_user";
SQL

info "Provisioning complete."
