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

  # IDs
  _TELEM_INSTALL_ID="$(_telem_uuid)"
  _TELEM_SESSION_ID="$(_telem_uuid)"
  _TELEM_MACHINE_ID="$(_telem_machine_id)"
  _TELEM_T0="$(_telem_epoch_ms)"

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
  if command -v sha256sum &>/dev/null; then
    printf 'sha256:%s\n' "$(printf '%s' "$raw" | sha256sum 2>/dev/null | cut -d' ' -f1 2>/dev/null || printf '%s' "${_TELEM_INSTALL_ID:-unknown}")"
  elif command -v shasum &>/dev/null; then
    printf 'sha256:%s\n' "$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -d' ' -f1 2>/dev/null || printf '%s' "${_TELEM_INSTALL_ID:-unknown}")"
  else
    # Fallback: use the install_id (less stable but non-identifying)
    printf 'fallback:%s\n' "${_TELEM_INSTALL_ID:-unknown}"
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
  os_name="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf 'unknown')"
  arch_name="$(hw_arch 2>/dev/null || uname -m 2>/dev/null || printf 'unknown')"
  os_ver="$(uname -r 2>/dev/null | cut -d. -f1-2 2>/dev/null || printf 'unknown')"
  install_method="${PRESELECT_METHOD:-unknown}"

  local body
  body=$(cat <<EOF
{
  "schema": "lowkey.install.v1",
  "sent_at": "$(_telem_iso)",
  "install_id": "${_TELEM_INSTALL_ID}",
  "machine_id": "${_TELEM_MACHINE_ID}",
  "agent": {
    "version": "${INSTALLER_VERSION:-unknown}",
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
  # Flush all queued events as one batch. Called at install end.
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  [[ -s "$_TELEM_QUEUE" ]] || return 0   # nothing to send

  local os_name arch_name os_ver events
  local queue_copy
  queue_copy="$(cat "$_TELEM_QUEUE" 2>/dev/null || printf '')"
  rm -f "$_TELEM_QUEUE" 2>/dev/null || true

  [[ -n "$queue_copy" ]] || return 0

  os_name="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf 'unknown')"
  arch_name="$(hw_arch 2>/dev/null || uname -m 2>/dev/null || printf 'unknown')"
  os_ver="$(uname -r 2>/dev/null | cut -d. -f1-2 2>/dev/null || printf 'unknown')"

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
    "version": "${INSTALLER_VERSION:-unknown}",
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
  local dur
  dur="$(_telem_duration_ms)"
  _telem_event "install.completed" "$(printf '{"duration_ms":%s,"pack":"%s","method":"%s","region":"%s"}' \
    "$dur" "${PACK_NAME:-unknown}" "${DEPLOY_METHOD:-unknown}" "${DEPLOY_REGION:-unknown}")"
  _telem_send_install_beacon "completed" "$dur"
  _telem_flush
}

_telem_install_failed() {
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
