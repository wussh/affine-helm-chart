#!/usr/bin/env sh
# wait-and-load-secrets.sh
# Waits for Kubernetes Secrets to be populated (keys non-empty),
# then decodes and writes credential files to /run/affine-secrets.
# No credentials are printed. Fails on timeout.
set -euo pipefail

# BusyBox ash supports pipefail in Alpine.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*" >&2; }

require_env() {
  for _v; do
    eval "_val=\"\${${_v}:-}\""
    [ -n "$_val" ] || die "Required env var not set: ${_v}"
  done
}

require_positive_int() {
  _name="$1" _value="$2"
  case "$_value" in
    ''|*[!0-9]*) die "${_name} must be a positive integer" ;;
  esac
  [ "$_value" -gt 0 ] || die "${_name} must be greater than zero"
}

validate_key() {
  _name="$1" _value="$2"
  case "$_value" in
    ''|*[!A-Za-z0-9._-]*) die "${_name} contains unsupported characters" ;;
  esac
}

# ---------------------------------------------------------------------------
# Env validation
# ---------------------------------------------------------------------------
require_env \
  ADMIN_SECRET_NAMESPACE ADMIN_SECRET_NAME \
  ADMIN_HOST_KEY ADMIN_PORT_KEY ADMIN_USERNAME_KEY ADMIN_PASSWORD_KEY \
  APP_SECRET_NAMESPACE APP_SECRET_NAME \
  APP_USERNAME_KEY APP_PASSWORD_KEY

WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-5}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-300}"
SECRET_DIR="${SECRET_DIR:-/run/affine-secrets}"
require_positive_int WAIT_INTERVAL_SECONDS "$WAIT_INTERVAL_SECONDS"
require_positive_int WAIT_TIMEOUT_SECONDS "$WAIT_TIMEOUT_SECONDS"
validate_key ADMIN_HOST_KEY "$ADMIN_HOST_KEY"
validate_key ADMIN_PORT_KEY "$ADMIN_PORT_KEY"
validate_key ADMIN_USERNAME_KEY "$ADMIN_USERNAME_KEY"
validate_key ADMIN_PASSWORD_KEY "$ADMIN_PASSWORD_KEY"
validate_key APP_USERNAME_KEY "$APP_USERNAME_KEY"
validate_key APP_PASSWORD_KEY "$APP_PASSWORD_KEY"

# ---------------------------------------------------------------------------
# Prepare output dir
# ---------------------------------------------------------------------------
umask 077
mkdir -p "$SECRET_DIR"

# ---------------------------------------------------------------------------
# Wait for a single Secret key to be non-empty (bracket-safe JSONPath)
# Never prints value.
# ---------------------------------------------------------------------------
wait_key() {
  _ns="$1" _name="$2" _key="$3" _label="$4"
  _elapsed=0
  info "Waiting for Secret ${_ns}/${_name} key '${_key}' (${_label}) ..."
  while true; do
    _val="$(kubectl -n "$_ns" get secret "$_name" \
      -o "jsonpath={.data['${_key}']}" 2>/dev/null || true)"
    if [ -n "$_val" ]; then
      info "Key '${_key}' ready."
      return 0
    fi
    if [ "$_elapsed" -ge "$WAIT_TIMEOUT_SECONDS" ]; then
      die "Timeout (${WAIT_TIMEOUT_SECONDS}s) waiting for Secret ${_ns}/${_name} key '${_key}'"
    fi
    sleep "$WAIT_INTERVAL_SECONDS"
    _elapsed=$((_elapsed + WAIT_INTERVAL_SECONDS))
  done
}

# ---------------------------------------------------------------------------
# Decode a key and write to file (no value in stdout/stderr)
# ---------------------------------------------------------------------------
decode_key() {
  _ns="$1" _name="$2" _key="$3" _dest="$4"
  kubectl -n "$_ns" get secret "$_name" \
    -o "jsonpath={.data['${_key}']}" 2>/dev/null \
    | base64 -d > "$SECRET_DIR/$_dest"
  chmod 0400 "$SECRET_DIR/$_dest"
}

# ---------------------------------------------------------------------------
# Wait -- admin Secret keys
# ---------------------------------------------------------------------------
wait_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_HOST_KEY"     "admin-host"
wait_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_PORT_KEY"     "admin-port"
wait_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_USERNAME_KEY" "admin-username"
wait_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_PASSWORD_KEY" "admin-password"

# ---------------------------------------------------------------------------
# Wait -- app Secret keys
# ---------------------------------------------------------------------------
wait_key "$APP_SECRET_NAMESPACE" "$APP_SECRET_NAME" "$APP_USERNAME_KEY" "app-username"
wait_key "$APP_SECRET_NAMESPACE" "$APP_SECRET_NAME" "$APP_PASSWORD_KEY" "app-password"

# ---------------------------------------------------------------------------
# Decode and write to tmpfs
# ---------------------------------------------------------------------------
info "All keys ready. Decoding to ${SECRET_DIR} ..."
decode_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_HOST_KEY"     pg-host
decode_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_PORT_KEY"     pg-port
decode_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_USERNAME_KEY" pg-user
decode_key "$ADMIN_SECRET_NAMESPACE" "$ADMIN_SECRET_NAME" "$ADMIN_PASSWORD_KEY" pg-password
decode_key "$APP_SECRET_NAMESPACE"   "$APP_SECRET_NAME"   "$APP_USERNAME_KEY"   app-user
decode_key "$APP_SECRET_NAMESPACE"   "$APP_SECRET_NAME"   "$APP_PASSWORD_KEY"   app-password

info "Secrets loaded."
