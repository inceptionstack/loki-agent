#!/usr/bin/env bash
# packs/pi/install.sh — Install Pi Coding Agent and configure it to use bedrockify
#
# Usage:
#   ./install.sh [--region us-east-1] [--model us.anthropic.claude-sonnet-4-6-v1] [--bedrockify-port 8090]
#
# Assumes:
#   - bedrockify is already installed and running (see packs/bedrockify/)
#   - npm/node available
#   - IAM role with bedrock:InvokeModel permissions (handled by bedrockify)
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
# Defaults from config file (written by bootstrap dispatcher), then CLI overrides
# Note: reads "model" key directly — Pi accepts any OpenAI-style model ID string.
# The generic --model from the dispatcher carries Bedrock model IDs; we pass them
# through to bedrockify which handles the translation.
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_provider_primary_model "us.anthropic.claude-sonnet-4-6-v1")"
PACK_ARG_BEDROCKIFY_PORT="$(pack_config_get bedrockify_port "8090")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Pi Coding Agent and configure it to use bedrockify.

Options:
  --region           AWS region for Bedrock          (default: us-east-1)
  --model            Model ID passed to Pi            (default: us.anthropic.claude-sonnet-4-6-v1)
  --bedrockify-port  Port where bedrockify listens   (default: 8090)
  --help             Show this help message

Note: Pi is a CLI tool only — no systemd service is created.

Examples:
  ./install.sh --region us-east-1
  ./install.sh --model us.anthropic.claude-sonnet-4-6-v1 --bedrockify-port 8090
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --region)           PACK_ARG_REGION="$2";           shift 2 ;;
    --model)            PACK_ARG_MODEL="$2";             shift 2 ;;
    --bedrockify-port)  PACK_ARG_BEDROCKIFY_PORT="$2";  shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
BEDROCKIFY_PORT="${PACK_ARG_BEDROCKIFY_PORT}"

pack_banner "pi"
log "region=${REGION} model=${MODEL} bedrockify-port=${BEDROCKIFY_PORT}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl npm node

# Verify bedrockify is running
HEALTH="$(curl -sf "http://127.0.0.1:${BEDROCKIFY_PORT}/" 2>&1)" || true
if ! printf '%s' "${HEALTH}" | grep -q '"status":"ok"'; then
  fail "bedrockify is not running on port ${BEDROCKIFY_PORT}. Install bedrockify pack first."
fi
ok "bedrockify is healthy on port ${BEDROCKIFY_PORT}"

# ── Install Pi ────────────────────────────────────────────────────────────────
step "Installing Pi Coding Agent"

if command -v pi &>/dev/null; then
  PI_EXISTING="$(pi --version 2>/dev/null || echo unknown)"
  log "pi already installed (${PI_EXISTING}) — reinstalling"
fi

npm install -g @mariozechner/pi-coding-agent

# Add npm global bin to PATH for current session
NPM_GLOBAL_BIN="$(npm root -g 2>/dev/null | sed 's|/lib/node_modules||')"/bin
export PATH="${NPM_GLOBAL_BIN}:${HOME}/.local/bin:$PATH"

if ! command -v pi &>/dev/null; then
  fail "pi command not found after install. Check PATH or install output."
fi

PI_VERSION="$(pi --version 2>/dev/null || echo unknown)"
ok "Pi installed: ${PI_VERSION}"

# ── Configure Pi ─────────────────────────────────────────────────────────────
step "Configuring Pi"

mkdir -p "${HOME}/.pi/agent"

PACK_CONFIG_PATH="${PACK_CONFIG:-/tmp/loki-pack-config.json}"
PROVIDER_MODELS_JSON='[]'
if [[ -f "${PACK_CONFIG_PATH}" ]] && command -v jq &>/dev/null; then
  PROVIDER_MODELS_JSON="$(jq -c '.provider.models // []' "${PACK_CONFIG_PATH}" 2>/dev/null || echo '[]')"
fi

jq -n \
  --arg base_url "http://127.0.0.1:${BEDROCKIFY_PORT}/v1" \
  --arg primary_model "${MODEL}" \
  --argjson provider_models "${PROVIDER_MODELS_JSON}" '
  def normalized_models($primary):
    (if ($provider_models | type) == "array" then $provider_models else [] end) as $models
    | if $primary == "" then
        $models
      elif any($models[]?; .id == $primary) then
        $models
      else
        [{"id": $primary}] + $models
      end;

  {
    providers: {
      bedrockify: {
        baseUrl: $base_url,
        api: "openai-completions",
        apiKey: "not-needed",
        compat: {
          supportsDeveloperRole: false,
          supportsReasoningEffort: false
        },
        models: normalized_models($primary_model)
      }
    }
  }
' > "${HOME}/.pi/agent/models.json"

chmod 600 "${HOME}/.pi/agent/models.json"
ok "Pi config written: ${HOME}/.pi/agent/models.json"

# ── Sanity check ─────────────────────────────────────────────────────────────
step "Sanity check"

PI_VER="$(pi --version 2>/dev/null || echo unknown)"
ok "pi --version: ${PI_VER}"

# ── Done ─────────────────────────────────────────────────────────────────────
write_done_marker "pi"
printf "\n[PACK:pi] INSTALLED — pi CLI ready (model: %s via bedrockify:%s)\n" \
  "${MODEL}" "${BEDROCKIFY_PORT}"
