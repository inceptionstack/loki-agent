#!/usr/bin/env bash
# packs/roundhouse/install.sh — Install Roundhouse and connect to Telegram
#
# Usage:
#   ./install.sh [--telegram-bot-token TOKEN] [--telegram-bot-token-secret SECRET_ID]
#                [--telegram-user USERNAME] [--model MODEL]
#
# Assumes:
#   - npm/node available (mise-managed)
#   - IAM role with secretsmanager:GetSecretValue (if using --telegram-bot-token-secret)
#
# The Telegram bot token is required. It can be provided via:
#   1. --telegram-bot-token flag (plaintext, for dev/test)
#   2. --telegram-bot-token-secret flag (AWS Secrets Manager id/arn, recommended)
#   3. pack config JSON key "telegram_bot_token" or "telegram_bot_token_secret"
#
# Idempotent: safe to re-run (--force).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_TELEGRAM_BOT_TOKEN="$(pack_config_get telegram_bot_token "")"
PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET="$(pack_config_get telegram_bot_token_secret "")"
PACK_ARG_TELEGRAM_USER="$(pack_config_get telegram_user "")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-opus-4-6-v1")"
PACK_ARG_SKIP_TELEMETRON="$(pack_config_get "skip-telemetron" "false")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Roundhouse and connect to Telegram.

Options:
  --telegram-bot-token         Telegram bot token (plaintext, for dev/test)
  --telegram-bot-token-secret  AWS Secrets Manager secret id containing the token
  --telegram-user              Telegram username for pairing (without @)
  --model                      AI model ID (default: us.anthropic.claude-opus-4-6-v1)
  --skip-telemetron            Skip the telemetron metrics sidecar
  --help                       Show this help message

One of --telegram-bot-token or --telegram-bot-token-secret is required.

Examples:
  ./install.sh --telegram-bot-token-secret "/my-project/telegram-bot-token" --telegram-user myuser
  ./install.sh --telegram-bot-token "123456:ABC-DEF..." --telegram-user myuser
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage; exit 0 ;;
    --telegram-bot-token)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-bot-token requires a value" >&2; exit 1; }
      PACK_ARG_TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
    --telegram-bot-token-secret)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-bot-token-secret requires a value" >&2; exit 1; }
      PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET="$2"; shift 2 ;;
    --telegram-user)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-user requires a value" >&2; exit 1; }
      PACK_ARG_TELEGRAM_USER="$2"; shift 2 ;;
    --model)
      [[ $# -gt 1 ]] || { echo "ERROR: --model requires a value" >&2; exit 1; }
      PACK_ARG_MODEL="$2"; shift 2 ;;
    --skip-telemetron)
      PACK_ARG_SKIP_TELEMETRON="true"; shift ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

# ── Resolve Telegram bot token ────────────────────────────────────────────────
step "Resolving Telegram bot token"

TELEGRAM_TOKEN=""

if [[ -n "${PACK_ARG_TELEGRAM_BOT_TOKEN}" ]]; then
  TELEGRAM_TOKEN="${PACK_ARG_TELEGRAM_BOT_TOKEN}"
  ok "Token provided directly"
elif [[ -n "${PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET}" ]]; then
  TELEGRAM_TOKEN=$(aws secretsmanager get-secret-value \
    --secret-id "${PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET}" \
    --query 'SecretString' --output text 2>/tmp/rh-sm-err.$$) || true
  if [[ -z "$TELEGRAM_TOKEN" || "$TELEGRAM_TOKEN" == "None" ]]; then
    sm_err=$(cat /tmp/rh-sm-err.$$ 2>/dev/null)
    rm -f /tmp/rh-sm-err.$$
    fail "Failed to resolve Telegram bot token from Secrets Manager: ${PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET} ${sm_err:+(${sm_err})}"
  fi
  ok "Token resolved from Secrets Manager"
else
  fail "Telegram bot token is required. Use --telegram-bot-token or --telegram-bot-token-secret"
fi

# Validate token format (basic check: number:alphanumeric)
if [[ ! "$TELEGRAM_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  fail "Invalid Telegram bot token format"
fi

# ── Install Roundhouse ────────────────────────────────────────────────────────
step "Installing Roundhouse"

npm install -g @inceptionstack/roundhouse

# Reshim if mise is available
if command -v mise &>/dev/null; then
  mise reshim 2>/dev/null || true
fi

# Ensure roundhouse is on PATH
NODE_PREFIX="$(npm prefix -g)"
export PATH="${NODE_PREFIX}/bin:$PATH"

RH_VERSION="$(roundhouse --version 2>/dev/null || echo unknown)"
ok "Roundhouse installed: ${RH_VERSION}"

# ── Run headless setup ────────────────────────────────────────────────────────
step "Running headless Telegram setup"

# roundhouse setup --telegram --headless reads TELEGRAM_BOT_TOKEN from env,
# writes config, .env, installs systemd service, and starts the daemon.
# --user is required for headless mode.
if [[ -z "${PACK_ARG_TELEGRAM_USER}" ]]; then
  fail "Telegram username is required for headless setup. Use --telegram-user"
fi

SETUP_ARGS=(
  --telegram
  --headless
  --force
  --user "${PACK_ARG_TELEGRAM_USER}"
  --model "${PACK_ARG_MODEL}"
  --provider amazon-bedrock
)

TELEGRAM_BOT_TOKEN="${TELEGRAM_TOKEN}" roundhouse setup "${SETUP_ARGS[@]}"

ok "Roundhouse setup complete"

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verifying service"

sleep 2
if systemctl is-active roundhouse.service &>/dev/null; then
  ok "Roundhouse service is running"
else
  warn "Roundhouse service may not be active yet — check: systemctl status roundhouse.service"
fi

# ── Optional sidecar: telemetron ──────────────────────────────────────────────
# Uses `telemetron detect` to auto-discover roundhouse sessions and configure
# metrics collection. Runs silently — never blocks, never warns, never prints
# on the user's terminal. All output goes to $INSTALL_LOG.

should_run_telemetron() {
  if [[ "${PACK_ARG_SKIP_TELEMETRON:-false}" = "true" ]]; then
    echo "skip: --skip-telemetron"; return
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "skip: non-Linux"; return
  fi
  if [[ "${LOWKEY_TELEMETRY:-1}" = "0" ]] \
     || [[ "${DO_NOT_TRACK:-0}" = "1" ]] \
     || [[ -f "${HOME:-}/.lowkey/telemetry-off" ]]; then
    echo "skip: lowkey telemetry opt-out"; return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "skip: systemctl not found"; return
  fi
  echo "yes"
}

_telemetron_sidecar() {
  local _raw_log="${INSTALL_LOG:-/tmp/loki-install.log}"
  local log; { >> "$_raw_log"; } 2>/dev/null && log="$_raw_log" || log=/dev/null
  local decision
  decision="$(should_run_telemetron)"
  if [[ "$decision" != "yes" ]]; then
    {
      printf '\n[telemetron] begin %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '[telemetron] %s\n' "$decision"
      printf '[telemetron] end %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >>"$log" || true
    return 0
  fi

  local endpoint="https://telemetry.loki.run/v1/metrics"
  local enroll_endpoint="https://telemetry.loki.run/v1/enroll"
  local install_url="https://raw.githubusercontent.com/inceptionstack/telemetron/main/install.sh"

  # Detect tier from AWS account. Internal = @amazon.com.
  local tier="external"
  local acct_email=""

  # Method 1: account contact info
  local contact_info
  contact_info=$(timeout 5 aws account get-contact-information --output json 2>/dev/null) || true
  if echo "$contact_info" | grep -q '@amazon\.com"'; then
    acct_email="internal@amazon.com"
  fi

  # Method 2: organization master account email
  if [[ "$acct_email" != *@amazon.com ]]; then
    acct_email=$(timeout 5 aws organizations describe-organization \
      --query 'Organization.MasterAccountEmail' --output text 2>/dev/null) || true
  fi

  # Method 3: organizations describe-account
  if [[ "$acct_email" != *@amazon.com ]]; then
    local acct_id
    acct_id=$(timeout 5 aws sts get-caller-identity --query Account --output text 2>/dev/null) || true
    if [[ -n "$acct_id" ]]; then
      acct_email=$(timeout 5 aws organizations describe-account \
        --account-id "$acct_id" --query 'Account.Email' --output text 2>/dev/null) || true
    fi
  fi

  if [[ "$acct_email" == *@amazon.com ]]; then
    tier="internal"
  fi

  # Write tier file for telemetron to read
  local home="${HOME:-/home/ec2-user}"
  for dir in "$home/.lowkey" "$home/.loki"; do
    mkdir -p "$dir" 2>/dev/null || true
    printf '%s\n' "$tier" > "$dir/tier" 2>/dev/null || true
  done

  # Install telemetron binary if not already present.
  # No env vars = install.sh only downloads the binary, skips setup.
  # We use `telemetron detect` for configuration instead.
  if ! command -v telemetron >/dev/null 2>&1 \
     && [[ ! -x /var/lib/telemetron/bin/telemetron ]]; then
    local connect_to=5
    local max_to=55
    timeout 60 bash -c "
      set -euo pipefail
      curl --connect-timeout $connect_to --max-time $max_to -fsSL '$install_url' | sudo TELEMETRON_PREFIX=/usr/local bash
    " || {
      printf '[telemetron] install failed (exit %d) — continuing\n' "$?" >>"$log"
      return 0
    }
  fi

  # Resolve telemetron binary path
  local telemetron_bin=""
  if [[ -x /var/lib/telemetron/bin/telemetron ]]; then
    telemetron_bin="/var/lib/telemetron/bin/telemetron"
  elif command -v telemetron >/dev/null 2>&1; then
    telemetron_bin="$(command -v telemetron)"
  fi

  if [[ -z "$telemetron_bin" ]]; then
    printf '[telemetron] binary not found after install — skipping\n' >>"$log"
    return 0
  fi

  # Use `telemetron detect` to auto-discover roundhouse (and any other packs)
  # and configure + enroll + start the service(s).
  timeout 30 sudo "$telemetron_bin" detect \
    --endpoint "$endpoint" \
    --enroll-endpoint "$enroll_endpoint" \
    --mode roundhouse \
    --force >>"$log" 2>&1 || {
    printf '[telemetron] detect failed (exit %d) — continuing\n' "$?" >>"$log"
    return 0
  }

  printf '[telemetron] detect completed successfully\n' >>"$log"
}

(
  set +e
  _telemetron_sidecar
) || true

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "roundhouse"
printf "\n[PACK:roundhouse] INSTALLED — Telegram bot connected (systemd: roundhouse)\n"
