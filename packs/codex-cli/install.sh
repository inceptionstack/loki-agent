#!/usr/bin/env bash
# packs/codex-cli/install.sh — Install OpenAI Codex CLI
#
# Usage:
#   ./install.sh [--region us-east-1] [--model gpt-5.4] \
#                [--openai-api-key sk-...] [--approval-policy never] \
#                [--sandbox-mode danger-full-access]
#
# Assumes:
#   - Node.js / npm available
#   - An OpenAI API key (from platform.openai.com/api-keys)
#
# Unlike other packs, Codex CLI uses OpenAI's API directly — no bedrockify needed.
# This is the only pack that requires an external API key.
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "gpt-5.4")"
PACK_ARG_OPENAI_API_KEY="$(pack_config_get "openai-api-key" "${OPENAI_API_KEY:-}")"
PACK_ARG_APPROVAL_POLICY="$(pack_config_get "approval-policy" "never")"
PACK_ARG_SANDBOX_MODE="$(pack_config_get "sandbox-mode" "danger-full-access")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install OpenAI Codex CLI — OpenAI's coding agent for the terminal.

⚠️  Codex CLI requires an OpenAI API key. Unlike other packs that use AWS
   Bedrock for inference, Codex CLI connects directly to OpenAI's API.
   Get your key at: https://platform.openai.com/api-keys

Options:
  --region            AWS region (informational only)             (default: us-east-1)
  --model             Default model for Codex CLI                 (default: gpt-5.4)
  --openai-api-key    OpenAI API key (required — sk-...)
  --approval-policy   Approval mode: on-request|untrusted|never   (default: never)
  --sandbox-mode      Sandbox: workspace-write|workspace-read|danger-full-access
                                                                  (default: danger-full-access)
  --help              Show this help message

Note: Codex CLI is a CLI tool only — no systemd service is created.
      No bedrockify dependency — connects to OpenAI's API directly.

Examples:
  ./install.sh --openai-api-key sk-proj-abc123
  ./install.sh --model gpt-5.4 --approval-policy on-request
  ./install.sh --openai-api-key sk-proj-abc123 --sandbox-mode workspace-write
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)            usage; exit 0 ;;
    --region)             PACK_ARG_REGION="$2";           shift 2 ;;
    --model)              PACK_ARG_MODEL="$2";            shift 2 ;;
    --openai-api-key)     PACK_ARG_OPENAI_API_KEY="$2";   shift 2 ;;
    --approval-policy)    PACK_ARG_APPROVAL_POLICY="$2";  shift 2 ;;
    --sandbox-mode)       PACK_ARG_SANDBOX_MODE="$2";     shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
OPENAI_API_KEY="${PACK_ARG_OPENAI_API_KEY}"
APPROVAL_POLICY="${PACK_ARG_APPROVAL_POLICY}"
SANDBOX_MODE="${PACK_ARG_SANDBOX_MODE}"

pack_banner "codex-cli"
log "region=${REGION} model=${MODEL} approval_policy=${APPROVAL_POLICY} sandbox_mode=${SANDBOX_MODE}"

# ── Prompt for API key if not provided ────────────────────────────────────────
if [[ -z "${OPENAI_API_KEY}" ]]; then
  printf "\n"
  printf "${_CLR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n"
  printf "${_CLR_YELLOW}  OpenAI API Key Required${_CLR_NC}\n"
  printf "${_CLR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n"
  printf "\n"
  printf "  Codex CLI connects directly to OpenAI\x27s API (not AWS Bedrock).\n"
  printf "  Get your API key at: ${_CLR_CYAN}https://platform.openai.com/api-keys${_CLR_NC}\n"
  printf "\n"
  printf "  You can also skip this and run dex

# Validate key format if provided
if [[ -n "${OPENAI_API_KEY}" ]] && [[ ! "${OPENAI_API_KEY}" =~ ^sk- ]]; then
  warn "API key doesn't start with 'sk-' — this may not be a valid OpenAI key"
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd npm node curl

# ── Install Codex CLI ─────────────────────────────────────────────────────────
step "Installing Codex CLI"

if command -v codex &>/dev/null; then
  CODEX_EXISTING="$(codex --version 2>/dev/null || echo unknown)"
  log "codex already installed (${CODEX_EXISTING}) — upgrading"
fi

npm install -g @openai/codex@latest

# Add npm global bin to PATH for current session
export PATH="$(npm prefix -g)/bin:${PATH}"

if ! command -v codex &>/dev/null; then
  fail "codex command not found after install. Check PATH or install output."
fi

CODEX_VERSION="$(codex --version 2>/dev/null || echo unknown)"
ok "Codex CLI installed: ${CODEX_VERSION}"

# ── Configure Codex CLI ───────────────────────────────────────────────────────
step "Writing Codex CLI configuration"

CODEX_HOME="${HOME}/.codex"
mkdir -p "${CODEX_HOME}"

cat > "${CODEX_HOME}/config.toml" << TOML
# Codex CLI configuration
# Managed by loki-agent packs/codex-cli/install.sh

model = "${MODEL}"
approval_policy = "${APPROVAL_POLICY}"
sandbox_mode = "${SANDBOX_MODE}"

# Store credentials in file (no keyring on EC2)
cli_auth_credentials_store = "file"
TOML

chmod 600 "${CODEX_HOME}/config.toml"
ok "Config written: ${CODEX_HOME}/config.toml"

# ── Store API key securely ────────────────────────────────────────────────────
step "Configuring authentication"

if [[ -n "${OPENAI_API_KEY}" ]]; then
  # Write env file with restricted permissions
  CODEX_ENV="${CODEX_HOME}/env.sh"

  cat > "${CODEX_ENV}" << EOF
# Codex CLI — authentication
# Managed by loki-agent packs/codex-cli/install.sh
# ⚠️  Contains secret — do not share or commit
export OPENAI_API_KEY="${OPENAI_API_KEY}"
EOF

  chmod 600 "${CODEX_ENV}"

  # Source from .bashrc
  if ! grep -q '.codex/env.sh' "${HOME}/.bashrc" 2>/dev/null; then
    printf '\n[ -f "%s/.codex/env.sh" ] && source "%s/.codex/env.sh"\n' "${HOME}" "${HOME}" >> "${HOME}/.bashrc"
  fi


  # Source for current session
  export OPENAI_API_KEY="${OPENAI_API_KEY}"
  ok "API key configured (stored in ${CODEX_ENV} with mode 600)"
else
  warn "No API key — authenticate later with: codex login"
fi

# ── Sanity check ──────────────────────────────────────────────────────────────
step "Sanity check"

ok "codex --version: $(codex --version 2>/dev/null || echo unknown)"
ok "Model: ${MODEL}"
ok "Approval policy: ${APPROVAL_POLICY}"
ok "Sandbox mode: ${SANDBOX_MODE}"

if [[ -n "${OPENAI_API_KEY}" ]]; then
  ok "Auth: API key configured"
else
  warn "Auth: not configured — run 'codex login' to authenticate"
fi

# ── Post-install notice ──────────────────────────────────────────────────────
cat << 'NOTICE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [CODEX CLI] INSTALLED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Usage:
    codex                     # Start interactive TUI
    codex exec "Your prompt"  # One-shot execution
    codex exec --full-auto "Your prompt"  # Auto-approve in sandbox
    /model                    # Switch models (inside TUI)

  Auth alternatives:
    codex login               # Browser-based ChatGPT login
    # Or set OPENAI_API_KEY env var for headless/CI

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

NOTICE

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "codex-cli"
printf "\n[PACK:codex-cli] INSTALLED — codex CLI ready (model: %s)\n" "${MODEL}"
