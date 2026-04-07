#!/usr/bin/env bash
# packs/codex-cli/install.sh — Install OpenAI Codex CLI and configure it for Bedrock via bedrockify
#
# Usage:
#   ./install.sh [--region us-east-1] [--model gpt-5.4] \
#                [--approval-policy never] [--sandbox-mode danger-full-access]
#
# Assumes:
#   - Node.js / npm available
#   - bedrockify running on port 8090 (dependency)
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "gpt-5.4")"
PACK_ARG_APPROVAL_POLICY="$(pack_config_get "approval-policy" "never")"
PACK_ARG_SANDBOX_MODE="$(pack_config_get "sandbox-mode" "danger-full-access")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install OpenAI Codex CLI and configure it to use AWS Bedrock via bedrockify.

Codex CLI connects to bedrockify's OpenAI-compatible endpoint on localhost:8090,
which proxies requests to Amazon Bedrock. No OpenAI API key required.

Options:
  --region            AWS region for Bedrock                     (default: us-east-1)
  --model             Model name for Codex CLI                   (default: gpt-5.4)
  --approval-policy   Approval mode: on-request|untrusted|never  (default: never)
  --sandbox-mode      Sandbox: workspace-write|workspace-read|danger-full-access
                                                                 (default: danger-full-access)
  --help              Show this help message

Note: Codex CLI is a CLI tool only — no systemd service is created.
      Requires bedrockify running on port 8090 for model inference.

Examples:
  ./install.sh --region us-east-1
  ./install.sh --model gpt-5.4 --approval-policy on-request
  ./install.sh --sandbox-mode workspace-write
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)            usage; exit 0 ;;
    --region)             PACK_ARG_REGION="$2";           shift 2 ;;
    --model)              PACK_ARG_MODEL="$2";            shift 2 ;;
    --approval-policy)    PACK_ARG_APPROVAL_POLICY="$2";  shift 2 ;;
    --sandbox-mode)       PACK_ARG_SANDBOX_MODE="$2";     shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
APPROVAL_POLICY="${PACK_ARG_APPROVAL_POLICY}"
SANDBOX_MODE="${PACK_ARG_SANDBOX_MODE}"

pack_banner "codex-cli"
log "region=${REGION} model=${MODEL} approval_policy=${APPROVAL_POLICY} sandbox_mode=${SANDBOX_MODE}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd npm node curl

# Verify bedrockify is running
check_bedrockify_health 8090

# ── Install Codex CLI ─────────────────────────────────────────────────────────
step "Installing Codex CLI"

if command -v codex &>/dev/null; then
  CODEX_EXISTING="$(codex --version 2>/dev/null || echo unknown)"
  log "codex already installed (${CODEX_EXISTING}) — reinstalling"
fi

npm install -g @openai/codex@latest

# Add npm global bin to PATH for current session
export PATH="$(npm prefix -g)/bin:${PATH}"

if ! command -v codex &>/dev/null; then
  fail "codex command not found after install. Check PATH or install output."
fi

CODEX_VERSION="$(codex --version 2>/dev/null || echo unknown)"
ok "Codex CLI installed: ${CODEX_VERSION}"

# ── Configure bedrockify as provider ──────────────────────────────────────────
step "Configuring Codex CLI for bedrockify (Bedrock proxy)"

CODEX_HOME="${HOME}/.codex"
mkdir -p "${CODEX_HOME}"

cat > "${CODEX_HOME}/config.toml" << TOML
# Codex CLI — bedrockify configuration
# Managed by loki-agent packs/codex-cli/install.sh — do not edit manually.

model = "${MODEL}"
model_provider = "bedrockify"

approval_policy = "${APPROVAL_POLICY}"
sandbox_mode = "${SANDBOX_MODE}"

[model_providers.bedrockify]
name = "Bedrockify (Bedrock proxy)"
base_url = "http://127.0.0.1:8090/v1"

[features]
multi_agent = true
shell_snapshot = true
TOML

chmod 600 "${CODEX_HOME}/config.toml"
ok "Config written: ${CODEX_HOME}/config.toml"

# ── Set environment variables ─────────────────────────────────────────────────
step "Configuring environment"

# Codex CLI needs OPENAI_API_KEY set (bedrockify accepts any value)
if [[ $EUID -eq 0 ]]; then
  PROFILE_TARGET="/etc/profile.d/codex-cli.sh"
else
  PROFILE_TARGET="${HOME}/.codex/env.sh"
  if ! grep -q 'codex/env.sh' "${HOME}/.bashrc" 2>/dev/null; then
    printf '\n[ -f "%s/.codex/env.sh" ] && source "%s/.codex/env.sh"\n' "${HOME}" "${HOME}" >> "${HOME}/.bashrc"
  fi
fi

mkdir -p "$(dirname "${PROFILE_TARGET}")"
cat > "${PROFILE_TARGET}" << EOF
# Codex CLI — environment
# Managed by loki-agent packs/codex-cli/install.sh
export OPENAI_API_KEY="bedrock-proxy"
export AWS_REGION="${REGION}"
EOF

chmod 644 "${PROFILE_TARGET}"
ok "Environment written: ${PROFILE_TARGET}"

# Source for current session
# shellcheck source=/dev/null
source "${PROFILE_TARGET}"

# ── Sanity check ──────────────────────────────────────────────────────────────
step "Sanity check"

CODEX_VER="$(codex --version 2>/dev/null || echo unknown)"
ok "codex --version: ${CODEX_VER}"
ok "Provider: bedrockify @ http://127.0.0.1:8090/v1"
ok "Model: ${MODEL}"
ok "Approval policy: ${APPROVAL_POLICY}"
ok "Sandbox mode: ${SANDBOX_MODE}"

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "codex-cli"
printf "\n[PACK:codex-cli] INSTALLED — codex CLI ready (model: %s via bedrockify, region: %s)\n" \
  "${MODEL}" "${REGION}"
