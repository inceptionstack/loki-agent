#!/usr/bin/env bash
# packs/common-telemetron.sh — Shared telemetron sidecar installer
#
# Sourced by pack install scripts. Provides `install_telemetron <mode>`.
# Requires: nothing (self-contained). Source after common.sh in pack scripts.
#
# Contract:
#   - Never prints to stdout/stderr (all output to log file)
#   - Never fails the caller (always returns 0)
#   - Idempotent (safe to re-run)

# ── Constants ─────────────────────────────────────────────────────────────────
_TELEMETRON_ENDPOINT="https://telemetry.loki.run/v1/metrics"
_TELEMETRON_ENROLL_ENDPOINT="https://telemetry.loki.run/v1/enroll"
_TELEMETRON_INSTALL_URL="https://raw.githubusercontent.com/inceptionstack/telemetron/main/install.sh"

# ── Gate: should telemetron run? ──────────────────────────────────────────────
_telemetron_should_run() {
  if [[ "${PACK_ARG_SKIP_TELEMETRON:-false}" = "true" ]]; then
    echo "skip: --skip-telemetron"; return
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "skip: non-Linux"; return
  fi
  if [[ "${LOWKEY_TELEMETRY:-1}" = "0" ]] \
     || [[ "${DO_NOT_TRACK:-0}" = "1" ]] \
     || [[ -f "${HOME:-}/.lowkey/telemetry-off" ]]; then
    echo "skip: telemetry opt-out"; return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "skip: no systemctl"; return
  fi
  echo "yes"
}

# ── Tier detection ────────────────────────────────────────────────────────────
# Detects whether the AWS account is internal (@amazon.com) or external.
# Tries 3 methods with 5s timeouts each. Email never leaves the machine.
_telemetron_detect_tier() {
  local acct_email=""

  # Method 1: account contact info — check all fields for @amazon.com
  local contact_info
  contact_info=$(timeout 5 aws account get-contact-information --output json 2>/dev/null) || true
  if echo "$contact_info" | grep -q '@amazon\.com"'; then
    echo "internal"; return
  fi

  # Method 2: organization master account email (works from member accounts)
  acct_email=$(timeout 5 aws organizations describe-organization \
    --query 'Organization.MasterAccountEmail' --output text 2>/dev/null) || true
  if [[ "$acct_email" == *@amazon.com ]]; then
    echo "internal"; return
  fi

  # Method 3: describe-account (management account only)
  local acct_id
  acct_id=$(timeout 5 aws sts get-caller-identity --query Account --output text 2>/dev/null) || true
  if [[ -n "$acct_id" ]]; then
    acct_email=$(timeout 5 aws organizations describe-account \
      --account-id "$acct_id" --query 'Account.Email' --output text 2>/dev/null) || true
    if [[ "$acct_email" == *@amazon.com ]]; then
      echo "internal"; return
    fi
  fi

  echo "external"
}

# ── Write tier files ──────────────────────────────────────────────────────────
_telemetron_write_tier() {
  local tier="$1"
  local home="${HOME:-/home/ec2-user}"
  for dir in "$home/.lowkey" "$home/.loki"; do
    mkdir -p "$dir" 2>/dev/null || true
    printf '%s\n' "$tier" > "$dir/tier" 2>/dev/null || true
  done
}

# ── Install binary ────────────────────────────────────────────────────────────
# Downloads and installs telemetron to /usr/local/bin via sudo.
# Returns 0 on success or if already installed, 1 on failure.
_telemetron_ensure_binary() {
  local log="$1"

  if command -v telemetron >/dev/null 2>&1 \
     || [[ -x /var/lib/telemetron/bin/telemetron ]]; then
    return 0
  fi

  if ! sudo -n true 2>/dev/null; then
    printf '[telemetron] sudo not available (non-interactive) — skipping\n' >>"$log"
    return 1
  fi

  timeout 60 bash -c "
    set -euo pipefail
    curl --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 55 \
      -fsSL '${_TELEMETRON_INSTALL_URL}' | sudo -n TELEMETRON_PREFIX=/usr/local bash
  " >>"$log" 2>&1 || {
    printf '[telemetron] binary install failed (exit %d)\n' "$?" >>"$log"
    return 1
  }
}

# ── Resolve binary path ───────────────────────────────────────────────────────
_telemetron_resolve_bin() {
  if [[ -x /var/lib/telemetron/bin/telemetron ]]; then
    echo "/var/lib/telemetron/bin/telemetron"
  elif command -v telemetron >/dev/null 2>&1; then
    command -v telemetron
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Public API
# ══════════════════════════════════════════════════════════════════════════════

# install_telemetron <mode>
#
# Installs and configures telemetron for the given pack mode.
# Uses `telemetron detect` which auto-discovers sessions by install directory.
#
# When called via `sudo`, SUDO_USER is preserved so telemetron resolves
# the correct user home (not /root).
#
# Usage:
#   install_telemetron openclaw
#   install_telemetron roundhouse
install_telemetron() {
  local mode="${1:?usage: install_telemetron <mode>}"
  (
    set +e
    local _raw_log="${INSTALL_LOG:-/tmp/loki-install.log}"
    local log
    { >> "$_raw_log"; } 2>/dev/null && log="$_raw_log" || log=/dev/null

    printf '\n[telemetron] begin %s mode=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mode" >>"$log"

    # Gate check
    local decision
    decision="$(_telemetron_should_run)"
    if [[ "$decision" != "yes" ]]; then
      printf '[telemetron] %s\n' "$decision" >>"$log"
      printf '[telemetron] end %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
      exit 0
    fi

    # Tier detection + write
    local tier
    tier="$(_telemetron_detect_tier)"
    _telemetron_write_tier "$tier"
    printf '[telemetron] tier=%s\n' "$tier" >>"$log"

    # Ensure binary installed
    if ! _telemetron_ensure_binary "$log"; then
      printf '[telemetron] end %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
      exit 0
    fi

    # Resolve binary path
    local bin
    bin="$(_telemetron_resolve_bin)"
    if [[ -z "$bin" ]]; then
      printf '[telemetron] binary not found after install\n' >>"$log"
      printf '[telemetron] end %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
      exit 0
    fi

    # Run detect — auto-discovers sessions, enrolls, starts service
    timeout 30 sudo -n "$bin" detect \
      --endpoint "$_TELEMETRON_ENDPOINT" \
      --enroll-endpoint "$_TELEMETRON_ENROLL_ENDPOINT" \
      --mode "$mode" \
      --force >>"$log" 2>&1 || {
      printf '[telemetron] detect failed (exit %d)\n' "$?" >>"$log"
      printf '[telemetron] end %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
      exit 0
    }

    printf '[telemetron] detect completed successfully\n' >>"$log"
    printf '[telemetron] end %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$log"
    exit 0
  ) || true
}
