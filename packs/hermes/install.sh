#!/usr/bin/env bash
# packs/hermes/install.sh — Install Hermes Agent and configure it to use bedrockify
#
# Usage:
#   ./install.sh [--region us-east-1] [--hermes-model anthropic/claude-opus-4.6] [--bedrockify-port 8090]
#
# Assumes:
#   - bedrockify is already installed and running (see packs/bedrockify/)
#   - curl available
#   - IAM role with bedrock:InvokeModel permissions (handled by bedrockify)
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
# Defaults from config file (written by bootstrap dispatcher), then CLI overrides
# Note: reads "hermes_model" key (not "model") — hermes needs OpenAI-style model ID
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get hermes_model "anthropic/claude-opus-4.6")"
PACK_ARG_BEDROCKIFY_PORT="$(pack_config_get bedrockify_port "8090")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Hermes Agent and configure it to use bedrockify.

Options:
  --region           AWS region for Bedrock         (default: us-east-1)
  --hermes-model     Model ID (OpenAI-style)        (default: anthropic/claude-opus-4.6)
  --bedrockify-port  Port where bedrockify listens  (default: 8090)
  --help             Show this help message

Note: --model is ignored (it carries Bedrock model IDs from the dispatcher).
      Use --hermes-model to override the model for Hermes.

Examples:
  ./install.sh --region us-east-1
  ./install.sh --hermes-model anthropic/claude-sonnet-4.6 --bedrockify-port 8090
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --region)           PACK_ARG_REGION="$2";           shift 2 ;;
    --hermes-model)     PACK_ARG_MODEL="$2";             shift 2 ;;
    --bedrockify-port)  PACK_ARG_BEDROCKIFY_PORT="$2";  shift 2 ;;
    --model)            [[ $# -gt 1 ]] && shift 2 || shift ;;  # Ignore generic --model (Bedrock ID); use --hermes-model
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
BEDROCKIFY_PORT="${PACK_ARG_BEDROCKIFY_PORT}"

pack_banner "hermes"
log "region=${REGION} model=${MODEL} bedrockify-port=${BEDROCKIFY_PORT}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl envsubst

# Verify bedrockify is running
HEALTH="$(curl -sf "http://127.0.0.1:${BEDROCKIFY_PORT}/" 2>&1)" || true
if ! printf '%s' "${HEALTH}" | grep -q '"status":"ok"'; then
  fail "bedrockify is not running on port ${BEDROCKIFY_PORT}. Install bedrockify pack first."
fi
ok "bedrockify is healthy on port ${BEDROCKIFY_PORT}"

# ── Install Hermes ─────────────────────────────────────────────────────────────
step "Installing Hermes Agent"

if command -v hermes &>/dev/null; then
  HERMES_EXISTING="$(hermes --version 2>/dev/null || echo unknown)"
  log "hermes already installed (${HERMES_EXISTING}) — reinstalling"
fi

curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
  | bash -s -- --skip-setup

# Add local bin to PATH for current session
export PATH="${HOME}/.local/bin:$PATH"

if ! command -v hermes &>/dev/null; then
  fail "hermes command not found after install. Check PATH or install output."
fi

HERMES_VERSION="$(hermes --version 2>/dev/null || echo unknown)"
ok "Hermes installed: ${HERMES_VERSION}"

# ── Configure Hermes ──────────────────────────────────────────────────────────
step "Configuring Hermes"

mkdir -p "${HOME}/.hermes"

# Write config from template
CONFIG_TPL="${SCRIPT_DIR}/resources/hermes-config.yaml.tpl"
if [[ ! -f "${CONFIG_TPL}" ]]; then
  fail "Config template not found at ${CONFIG_TPL}"
fi

export MODEL BEDROCKIFY_PORT
envsubst < "${CONFIG_TPL}" > "${HOME}/.hermes/config.yaml"
ok "Hermes config written: ${HOME}/.hermes/config.yaml"

# Write env file from template
ENV_TPL="${SCRIPT_DIR}/resources/hermes-env.tpl"
if [[ ! -f "${ENV_TPL}" ]]; then
  fail "Env template not found at ${ENV_TPL}"
fi

envsubst < "${ENV_TPL}" > "${HOME}/.hermes/.env"
chmod 600 "${HOME}/.hermes/.env" "${HOME}/.hermes/config.yaml"
ok "Hermes env written: ${HOME}/.hermes/.env"

# ── Verify end-to-end ─────────────────────────────────────────────────────────
step "End-to-end verification"

log "Testing bedrockify chat endpoint (quick sanity check)..."

CHAT_RESP="$(curl -sf "http://127.0.0.1:${BEDROCKIFY_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK in exactly 2 words.\"}]}" \
  --max-time 30 2>&1)" || true

if printf '%s' "${CHAT_RESP}" | grep -q '"choices"'; then
  REPLY="$(printf '%s' "${CHAT_RESP}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null \
    || echo "(parse failed)")"
  ok "Chat completions working — model replied: ${REPLY}"
else
  warn "Chat test inconclusive (IAM role may lack bedrock:InvokeModel). Response: ${CHAT_RESP}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "hermes"
printf "\n[PACK:hermes] INSTALLED — hermes CLI ready (model: %s via bedrockify:%s)\n" \
  "${MODEL}" "${BEDROCKIFY_PORT}"
