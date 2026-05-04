#!/usr/bin/env bash
# packs/common.sh — shared helpers for all pack install scripts
# Source this file; do not execute directly.
# Usage: source "$(dirname "$0")/../common.sh"

# Colors
_CLR_GREEN='\033[0;32m'
_CLR_CYAN='\033[0;36m'
_CLR_RED='\033[0;31m'
_CLR_YELLOW='\033[0;33m'
_CLR_BOLD='\033[1m'
_CLR_NC='\033[0m'

# log LEVEL MESSAGE
log()  { printf "${_CLR_CYAN}→${_CLR_NC} %s\n" "$1"; }
ok()   { printf "${_CLR_GREEN}✓${_CLR_NC} %s\n" "$1"; }
fail() { printf "${_CLR_RED}✗${_CLR_NC} %s\n" "$1" >&2; exit 1; }
warn() { printf "${_CLR_YELLOW}⚠${_CLR_NC} %s\n" "$1"; }
step() {
  # Increment shared step counter (shared with bootstrap.sh)
  local counter_file="/tmp/loki-step-counter"
  local total_file="/tmp/loki-step-total"
  local n total
  n=$(cat "$counter_file" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$counter_file"
  total=$(cat "$total_file" 2>/dev/null || echo "?")
  printf "\n${_CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n"
  printf "${_CLR_BOLD}  [%s/%s] %s${_CLR_NC}\n" "$n" "$total" "$1"
  printf "${_CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n\n"
  # Publish to SSM for installer progress display
  aws ssm put-parameter --name "/loki/setup-step" \
    --value "${n}/${total} $1" \
    --type String --overwrite --region "${AWS_DEFAULT_REGION:-us-east-1}" >/dev/null 2>&1 || true
}

# require_cmd CMD [CMD...]  — fail if any command is not found
require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      fail "Required command not found: $cmd (prerequisites not met)"
    fi
  done
}

# write_done_marker PACK_NAME
write_done_marker() {
  local pack_name="$1"
  touch "/tmp/pack-${pack_name}-done"
  ok "Marker written: /tmp/pack-${pack_name}-done"
}

# Read a value from the pack config JSON file
# Usage: pack_config_get "key" "default_value"
pack_config_get() {
  local key="$1" default="${2:-}"
  local config="${PACK_CONFIG:-/tmp/loki-pack-config.json}"
  if [[ -f "$config" ]] && command -v jq &>/dev/null; then
    local val
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$config" 2>/dev/null)
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
  fi
  echo "$default"
}

# check_bedrockify_health PORT
# Verify bedrockify is running and healthy on the given port.
# Fails with a clear message if not reachable.
check_bedrockify_health() {
  local port="${1:?usage: check_bedrockify_health PORT}"
  local health
  health="$(curl -sf "http://127.0.0.1:${port}/" 2>&1)" || true
  if ! printf '%s' "${health}" | grep -q '"status":"ok"'; then
    fail "bedrockify is not running on port ${port}. Install bedrockify pack first."
  fi
  ok "bedrockify is healthy on port ${port}"
}

# pack_banner NAME ACTION
pack_banner() {
  local name="$1"
  local action="${2:-INSTALLING}"
  printf "\n${_CLR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n"
  printf "${_CLR_CYAN}  [PACK:%s] %s${_CLR_NC}\n" "$name" "$action"
  printf "${_CLR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n\n"
}

# run_optional_sidecar — best-effort bootstrap of an optional install-time
# companion (metrics agent, diagnostics daemon, etc.) with the following
# hard invariants:
#
#   - Silent:  zero bytes on caller's stdout/stderr. Every line (begin,
#              outcome, transcript of the inner installer, end) goes to
#              LOG_FILE only.
#   - Logged:  every outcome writes a tagged `[NAME] ...` line.
#   - Bounded: wall clock is capped by TIMEOUT_SECS via coreutils `timeout`.
#   - Piped:   the `curl | bash` pipeline runs under `bash -o pipefail`
#              so a curl failure cannot be masked by the RHS bash exit code.
#   - Safe:    returns 0 to the caller under any outcome. The caller's
#              `set -euo pipefail` is never tripped by a sidecar failure.
#
# Usage: run_optional_sidecar NAME URL TIMEOUT_SECS LOG_FILE [KEY=VAL ...]
#   NAME          human-readable tag, e.g. "telemetron"
#   URL           HTTPS URL serving the sidecar's install.sh on stdout
#   TIMEOUT_SECS  outer wall-clock cap, e.g. 30
#   LOG_FILE      absolute path for outcome + install transcript
#   KEY=VAL...    env vars exported into the install script
run_optional_sidecar() {
  local name="${1:?usage: run_optional_sidecar NAME URL TIMEOUT_SECS LOG_FILE [ENV...]}"
  local url="${2:?sidecar URL required}"
  local secs="${3:?sidecar timeout required}"
  local log="${4:?sidecar log path required}"
  shift 4

  # Subshell + outer `|| true` ensures nothing in here can propagate
  # a non-zero exit to the caller — not even a failed exec-redirect.
  (
    set +e
    # Redirect all output to the log. Test writability first so the
    # "silent" contract holds even if the log path is unwritable or its
    # parent directory does not exist. The test-open uses a subshell so
    # any shell diagnostic stays invisible before we commit to a dest.
    if ( >> "$log" ) 2>/dev/null; then
      exec >>"$log" 2>&1
    else
      exec >/dev/null 2>&1
    fi
    printf '\n[%s] begin %s\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] installing from %s (timeout=%ss)\n' "$name" "$url" "$secs"

    # Inner curl caps budget well under the outer wall-clock so network
    # hangs return crisply. connect 5s, transfer = outer - 5s.
    local connect_to=5
    local max_to=$(( secs > 5 ? secs - 5 : secs ))

    # Positional args (not quote-splicing) so the command reads cleanly.
    # pipefail must apply to the pipeline, so it's set on the bash -c
    # subshell, not the outer shell.
    timeout "$secs" env "$@" bash -o pipefail -c '
      curl --fail --silent --show-error --location \
        --connect-timeout "$2" --max-time "$3" \
        "$1" \
      | bash
    ' _ "$url" "$connect_to" "$max_to"
    local rc=$?

    case "$rc" in
      0)          printf '[%s] installed and enrolled\n' "$name" ;;
      124|137|143) printf '[%s] install aborted: %ss outer timeout reached (rc=%s)\n' "$name" "$secs" "$rc" ;;
      *)          printf '[%s] install failed (rc=%s); see log above\n' "$name" "$rc" ;;
    esac
    printf '[%s] end %s\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit 0
  ) || true
}
