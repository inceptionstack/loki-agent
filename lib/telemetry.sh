#!/usr/bin/env bash
# lib/telemetry.sh — Lowkey installer telemetry
# Sourced by install.sh. All functions are prefixed with _telem_ to avoid collisions.
# Design: fire-and-forget, 2-second timeouts, silent on every failure.
# Opt-out: LOWKEY_TELEMETRY=0 | DO_NOT_TRACK=1 | ~/.lowkey/telemetry-off

# ── Config ──────────────────────────────────────────────────────────────
_TELEM_ENDPOINT="${LOWKEY_TELEMETRY_URL:-https://telemetry.loki.run}"
_TELEM_TIMEOUT=2          # seconds — curl connect + transfer
_TELEM_LOG="${INSTALL_LOG:-/tmp/loki-install.log}"
_TELEM_QUEUE="/tmp/.lowkey-telem-$$"   # per-process event queue (NDJSON)
_TELEM_ENABLED=true
_TELEM_INSTALL_ID=""
_TELEM_MACHINE_ID=""
_TELEM_SESSION_ID=""
_TELEM_T0=""              # epoch ms when install started
_TELEM_FINAL_STATE="${_TELEM_FINAL_STATE:-}"

_telem_num_or_default() {
  local value="${1:-}"
  local fallback="${2:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

# ── Opt-out check ───────────────────────────────────────────────────────
_telem_init() {
  # Respect all three opt-out signals
  if [[ "${LOWKEY_TELEMETRY:-}" == "0" ]] \
     || [[ "${DO_NOT_TRACK:-}" == "1" ]] \
     || [[ -n "${HOME:-}" && -f "${HOME}/.lowkey/telemetry-off" ]]; then
    _TELEM_ENABLED=false
    return 0
  fi

  # Require curl — if missing, silently disable
  if ! command -v curl &>/dev/null; then
    _TELEM_ENABLED=false
    return 0
  fi

  # IDs — validate against schema; if we can't produce a conformant machine_id,
  # disable telemetry rather than send payloads that will 400.
  _TELEM_INSTALL_ID="$(_telem_uuid)"
  _TELEM_SESSION_ID="$(_telem_uuid)"
  _TELEM_MACHINE_ID="$(_telem_machine_id)"
  _TELEM_T0="$(_telem_epoch_ms)"

  local os_name arch_name os_ver version os_ver_re
  os_name="$(_telem_norm_os)"
  arch_name="$(_telem_norm_arch)"
  os_ver="$(_telem_norm_os_version)"
  version="$(_telem_norm_version)"
  os_ver_re='^[-A-Za-z0-9./_+ ]{1,48}$'

  if [[ -z "$_TELEM_MACHINE_ID" ]] \
     || [[ -z "$os_name" ]] \
     || [[ -z "$arch_name" ]] \
     || ! [[ "$_TELEM_INSTALL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
     || ! [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]] \
     || ! [[ "$os_ver" =~ $os_ver_re ]]; then
    _TELEM_ENABLED=false
    return 0
  fi

  # Init the event queue file
  : > "$_TELEM_QUEUE" 2>/dev/null || _TELEM_ENABLED=false
}

# ── Identity ────────────────────────────────────────────────────────────
_telem_machine_id() {
  # Stable, irreversible machine fingerprint. Never transmitted raw.
  local raw=""
  if [[ -f /etc/machine-id ]]; then
    raw="$(cat /etc/machine-id 2>/dev/null || printf '')"
  elif [[ -f /var/lib/dbus/machine-id ]]; then
    raw="$(cat /var/lib/dbus/machine-id 2>/dev/null || printf '')"
  elif command -v ioreg &>/dev/null; then
    raw="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F\" '/IOPlatformUUID/{print $4}' 2>/dev/null || printf '')"
  fi
  # Mix with hostname for extra uniqueness, hash it
  raw="${raw}:$(hostname 2>/dev/null || printf 'unknown')"
  # Validate: schema requires sha256:<64-lowercase-hex>. Empty → disable.
  local hex=""
  if command -v sha256sum &>/dev/null; then
    hex="$(printf '%s' "$raw" | sha256sum 2>/dev/null | cut -d' ' -f1 2>/dev/null || printf '')"
  elif command -v shasum &>/dev/null; then
    hex="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -d' ' -f1 2>/dev/null || printf '')"
  fi
  if [[ "$hex" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'sha256:%s\n' "$hex"
  else
    printf ''
  fi
}

_telem_uuid() {
  # UUIDv4 from /dev/urandom — no external deps
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '00000000-0000-4000-8000-000000000000\n'
  elif command -v uuidgen &>/dev/null; then
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf '00000000-0000-4000-8000-000000000000\n'
  else
    # Pure bash fallback
    local hex
    hex="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' 2>/dev/null || printf '')"
    if [[ ${#hex} -ge 32 ]]; then
      printf '%s-%s-4%s-%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:16:4}" "${hex:20:12}"
    else
      printf '00000000-0000-4000-8000-%012d\n' "$$"
    fi
  fi
}

_telem_epoch_ms() {
  # Milliseconds since epoch. Falls back to seconds * 1000.
  if date +%s%3N >/dev/null 2>&1; then
    local ms
    ms="$(_telem_num_or_default "$(date +%s%3N 2>/dev/null || printf '')" '')"
    # GNU date returns ms, but macOS date may not support %3N
    if [[ ${#ms} -ge 13 ]]; then
      printf '%s\n' "$ms"
    else
      printf '%s000\n' "$(_telem_num_or_default "$(date +%s 2>/dev/null || printf '')" 0)"
    fi
  else
    printf '%s000\n' "$(_telem_num_or_default "$(date +%s 2>/dev/null || printf '')" 0)"
  fi
}

_telem_iso() {
  # ISO 8601 UTC timestamp
  local ts
  ts="$(LC_ALL=C date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf '')"
  if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\n' "$ts"
  else
    printf '1970-01-01T00:00:00Z\n'
  fi
}

_telem_duration_ms() {
  # Duration since _TELEM_T0 in milliseconds
  local now start
  now="$(_telem_num_or_default "$(_telem_epoch_ms)" 0)"
  start="$(_telem_num_or_default "${_TELEM_T0:-}" 0)"
  printf '%s\n' "$(( now - start ))"
}

# ── Normalization helpers ──────────────────────────────────────────────
# Keep outputs strictly within the schema enums.
_telem_norm_os() {
  # Map raw uname -s to schema enum: linux | darwin | windows
  local s
  s="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf 'linux')"
  case "$s" in
    darwin*)                 printf 'darwin\n' ;;
    linux*)                  printf 'linux\n' ;;
    mingw*|msys*|cygwin*|windows*) printf 'windows\n' ;;
    *)                       printf '' ;;
  esac
}

_telem_norm_arch() {
  # Map raw uname -m / hw_arch to schema enum: arm64 | x86_64
  local a
  a="$(hw_arch 2>/dev/null || uname -m 2>/dev/null || printf 'x86_64')"
  a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf '')"
  case "$a" in
    arm64|aarch64|armv8*|armv9*) printf 'arm64\n' ;;
    x86_64|amd64|x64)            printf 'x86_64\n' ;;
    *)                           printf '' ;;
  esac
}

_telem_norm_os_version() {
  # Schema: alnum + . _ + - space, max 48 chars.
  local v
  v="$(uname -r 2>/dev/null || printf '0.0')"
  # Strip anything not in the allowed set, then cap to 48 chars
  v="$(printf '%s' "$v" | tr -cd 'A-Za-z0-9._+\- ' 2>/dev/null || printf '0.0')"
  v="${v:0:48}"
  [[ -n "$v" ]] || v="0.0"
  printf '%s\n' "$v"
}

_telem_norm_version() {
  # Schema: ^[A-Za-z0-9][A-Za-z0-9.+_-]*$, max 32 chars
  local v="${INSTALLER_VERSION:-0.0.0}"
  v="$(printf '%s' "$v" | tr -cd 'A-Za-z0-9.+_\-' 2>/dev/null || printf '0.0.0')"
  # Ensure first char is alnum
  case "${v:0:1}" in
    [A-Za-z0-9]) : ;;
    *) v="0.0.0" ;;
  esac
  v="${v:0:32}"
  [[ -n "$v" ]] || v="0.0.0"
  printf '%s\n' "$v"
}

# ── Event recording (local queue, no network) ──────────────────────────
_telem_event() {
  # Usage: _telem_event "event.name" '{"key":"value"}'
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  local name="${1:-unknown}"
  local props="${2:-{}}"
  local ts
  ts="$(_telem_iso)"

  # Append to the NDJSON queue file (one JSON object per line)
  printf '{"t":"%s","name":"%s","props":%s}\n' "$ts" "$name" "$props" \
    >> "$_TELEM_QUEUE" 2>/dev/null || true
}

# ── Network: fire-and-forget POST ──────────────────────────────────────
_telem_post() {
  # Usage: _telem_post "/v1/install" '{"json":"body"}'
  # Runs curl in the background. Never blocks. Never fails visibly.
  local path="${1:-}" body="${2:-}"
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  (
    command curl -sfSL -X POST \
      "${_TELEM_ENDPOINT}${path}" \
      -H "Content-Type: application/json" \
      --connect-timeout "$_TELEM_TIMEOUT" \
      --max-time "$_TELEM_TIMEOUT" \
      -d "$body" \
      -o /dev/null \
      -w "" \
      </dev/null \
      2>>"$_TELEM_LOG" || true
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# ── High-level: install beacon (/v1/install) ────────────────────────────
_telem_send_install_beacon() {
  # Usage: _telem_send_install_beacon "completed" [duration_ms] [failure_step] [failure_class]
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  local outcome="${1:-started}"
  local duration_ms
  local failure_step="${3:-}"
  local failure_class="${4:-}"
  duration_ms="$(_telem_num_or_default "${2:-0}" 0)"

  local os_name arch_name os_ver install_method
  os_name="$(_telem_norm_os)"
  arch_name="$(_telem_norm_arch)"
  os_ver="$(_telem_norm_os_version)"
  install_method="${PRESELECT_METHOD:-unknown}"

  local body
  body=$(cat <<EOF
{
  "schema": "lowkey.install.v1",
  "sent_at": "$(_telem_iso)",
  "install_id": "${_TELEM_INSTALL_ID}",
  "machine_id": "${_TELEM_MACHINE_ID}",
  "agent": {
    "version": "$(_telem_norm_version)",
    "channel": "stable",
    "os": "${os_name}",
    "arch": "${arch_name}",
    "os_version": "${os_ver}"
  },
  "install_method": "${install_method}",
  "outcome": "${outcome}",
  "duration_ms": ${duration_ms},
  "is_test": ${TEST_MODE:-false},
  "failure_step": $(if [[ -n "$failure_step" ]]; then echo "\"$failure_step\""; else echo "null"; fi),
  "failure_class": $(if [[ -n "$failure_class" ]]; then echo "\"$failure_class\""; else echo "null"; fi)
}
EOF
  )
  _telem_post "/v1/install" "$body"
}

# ── High-level: flush queued events (/v1/ingest) ───────────────────────
_telem_flush() {
  # DISABLED: /v1/ingest enforces a strict event-name catalog that does not
  # include our install.* names (those are reflected in /v1/install as
  # structured outcomes). Sending would either 400 or be silently dropped.
  rm -f "$_TELEM_QUEUE" 2>/dev/null || true
  return 0

  # Flush all queued events as one batch. Called at install end.
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  [[ -s "$_TELEM_QUEUE" ]] || return 0   # nothing to send

  local os_name arch_name os_ver events
  local queue_copy
  queue_copy="$(cat "$_TELEM_QUEUE" 2>/dev/null || printf '')"
  rm -f "$_TELEM_QUEUE" 2>/dev/null || true

  [[ -n "$queue_copy" ]] || return 0

  os_name="$(_telem_norm_os)"
  arch_name="$(_telem_norm_arch)"
  os_ver="$(_telem_norm_os_version)"

  # Build the events array from NDJSON lines
  events="["
  local first=true line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$first" == "true" ]]; then first=false; else events+=","; fi
    events+="$line"
  done <<< "$queue_copy"
  events+="]"

  local body
  body=$(cat <<EOF
{
  "schema": "lowkey.telemetry.v1",
  "sent_at": "$(_telem_iso)",
  "agent": {
    "version": "$(_telem_norm_version)",
    "channel": "stable",
    "os": "${os_name}",
    "arch": "${arch_name}",
    "os_version": "${os_ver}"
  },
  "machine_id": "${_TELEM_MACHINE_ID}",
  "install_id": "${_TELEM_INSTALL_ID}",
  "session_id": "${_TELEM_SESSION_ID}",
  "is_test": ${TEST_MODE:-false},
  "events": ${events}
}
EOF
  )

  _telem_post "/v1/ingest" "$body"
  return 0
}

# ── Convenience: record common installer events ────────────────────────
_telem_install_started() {
  _telem_send_install_beacon "started"
  _telem_event "install.started" "$(printf '{"method":"%s"}' \
    "${PRESELECT_METHOD:-unknown}")"
}

_telem_pack_selected() {
  _telem_event "install.pack_selected" "$(printf '{"pack":"%s","profile":"%s"}' \
    "${PACK_NAME:-unknown}" "${PROFILE_NAME:-unknown}")"
}

_telem_method_selected() {
  _telem_event "install.method_selected" "$(printf '{"method":"%s","region":"%s"}' \
    "${DEPLOY_METHOD:-unknown}" "${DEPLOY_REGION:-unknown}")"
}

_telem_deploy_started() {
  _telem_event "install.deploy_started" "$(printf '{"method":"%s","region":"%s","pack":"%s"}' \
    "${DEPLOY_METHOD:-unknown}" "${DEPLOY_REGION:-unknown}" "${PACK_NAME:-unknown}")"
}

_telem_deploy_completed() {
  local dur
  dur="$(_telem_duration_ms)"
  _telem_event "install.deploy_completed" "$(printf '{"duration_ms":%s,"method":"%s"}' \
    "$dur" "${DEPLOY_METHOD:-unknown}")"
}

_telem_bootstrap_completed() {
  _telem_event "install.bootstrap_completed" "$(printf '{"instance_id":"%s"}' \
    "${INSTANCE_ID:-unknown}")"
}

_telem_install_completed() {
  [[ -z "${_TELEM_FINAL_STATE:-}" ]] || return 0
  _TELEM_FINAL_STATE="completed"
  local dur
  dur="$(_telem_duration_ms)"
  _telem_event "install.completed" "$(printf '{"duration_ms":%s,"pack":"%s","method":"%s","region":"%s"}' \
    "$dur" "${PACK_NAME:-unknown}" "${DEPLOY_METHOD:-unknown}" "${DEPLOY_REGION:-unknown}")"
  _telem_send_install_beacon "completed" "$dur"
  _telem_flush
}

_telem_install_failed() {
  [[ -z "${_TELEM_FINAL_STATE:-}" ]] || return 0
  _TELEM_FINAL_STATE="failed"
  local exit_code="${1:-1}"
  local failure_step="${2:-unknown}"
  local dur
  dur="$(_telem_duration_ms)"
  _telem_event "install.failed" "$(printf '{"duration_ms":%s,"exit_code":%s,"step":"%s","pack":"%s","method":"%s"}' \
    "$dur" "$exit_code" "$failure_step" "${PACK_NAME:-unknown}" "${DEPLOY_METHOD:-unknown}")"
  _telem_send_install_beacon "failed" "$dur" "$failure_step" "exit_${exit_code}"
  _telem_flush
}

# ── Auto-init on source ────────────────────────────────────────────────
_telem_init
_TELEM_LIB_READY=1
