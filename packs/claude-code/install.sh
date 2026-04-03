#!/usr/bin/env bash
# packs/claude-code/install.sh — Install Claude Code and configure it for AWS Bedrock
#
# Usage:
#   ./install.sh [--region us-east-1] [--model us.anthropic.claude-sonnet-4-6] \
#                [--haiku-model us.anthropic.claude-haiku-4-5-20251001-v1:0]
#
# Assumes:
#   - curl is available
#   - EC2 instance has an IAM role with bedrock:InvokeModel permissions
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6")"
PACK_ARG_HAIKU_MODEL="$(pack_config_get haiku_model "us.anthropic.claude-haiku-4-5-20251001-v1:0")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Claude Code and configure it to use AWS Bedrock natively.

Options:
  --region        AWS region for Bedrock                           (default: us-east-1)
  --model         Bedrock model ID (ANTHROPIC_MODEL)               (default: us.anthropic.claude-sonnet-4-6)
  --haiku-model   Bedrock model ID for Haiku fast-path             (default: us.anthropic.claude-haiku-4-5-20251001-v1:0)
  --help          Show this help message

Note: Claude Code is a CLI tool only — no systemd service is created.
      Claude Code talks to Bedrock directly via CLAUDE_CODE_USE_BEDROCK=1.
      No bedrockify dependency required.

Examples:
  ./install.sh --region us-east-1
  ./install.sh --model us.anthropic.claude-sonnet-4-6 --region eu-west-1
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)        usage; exit 0 ;;
    --region)         PACK_ARG_REGION="$2";       shift 2 ;;
    --model)          PACK_ARG_MODEL="$2";         shift 2 ;;
    --haiku-model)    PACK_ARG_HAIKU_MODEL="$2";   shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
HAIKU_MODEL="${PACK_ARG_HAIKU_MODEL}"

pack_banner "claude-code"
log "region=${REGION} model=${MODEL} haiku-model=${HAIKU_MODEL}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl

# Verify AWS credentials are available (instance profile or env vars)
if ! aws sts get-caller-identity --region "${REGION}" &>/dev/null; then
  fail "AWS credentials not available. Ensure the EC2 instance has an IAM role with Bedrock permissions."
fi
ok "AWS credentials verified (IAM role or env)"

# ── Install Claude Code ───────────────────────────────────────────────────────
step "Installing Claude Code"

if command -v claude &>/dev/null; then
  CLAUDE_EXISTING="$(claude --version 2>/dev/null || echo unknown)"
  log "claude already installed (${CLAUDE_EXISTING}) — reinstalling"
fi

# Use the official Claude Code native installer
curl -fsSL https://claude.ai/install.sh | bash

# Add ~/.local/bin to PATH for current session (installer places binary there)
export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v claude &>/dev/null; then
  fail "claude command not found after install. Check PATH or install output."
fi

CLAUDE_VERSION="$(claude --version 2>/dev/null || echo unknown)"
ok "Claude Code installed: ${CLAUDE_VERSION}"

# ── Configure Bedrock environment ─────────────────────────────────────────────
step "Configuring Bedrock environment"

# Write /etc/profile.d script so env vars are available to all login sessions
cat > /etc/profile.d/claude-code-bedrock.sh <<EOF
# Claude Code — Bedrock configuration
# Managed by loki-agent packs/claude-code/install.sh — do not edit manually.
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION="${REGION}"
export ANTHROPIC_MODEL="${MODEL}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${HAIKU_MODEL}"
EOF

chmod 644 /etc/profile.d/claude-code-bedrock.sh
ok "Bedrock env vars written to /etc/profile.d/claude-code-bedrock.sh"

# Source now for the current session
# shellcheck source=/dev/null
source /etc/profile.d/claude-code-bedrock.sh

# ── Configure Claude Code permissions ────────────────────────────────────────
step "Configuring Claude Code permissions"

mkdir -p "${HOME}/.claude"

# Write settings.json with full tool permissions (persistent --dangerously-skip-permissions)
cat > "${HOME}/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)"],
    "deny": []
  }
}
EOF

chmod 600 "${HOME}/.claude/settings.json"
ok "Claude Code permissions written: ${HOME}/.claude/settings.json"

# ── Sanity check ─────────────────────────────────────────────────────────────
step "Sanity check"

CLAUDE_VER="$(claude --version 2>/dev/null || echo unknown)"
ok "claude --version: ${CLAUDE_VER}"

# ── Done ─────────────────────────────────────────────────────────────────────
write_done_marker "claude-code"
printf "\n[PACK:claude-code] INSTALLED — claude CLI ready (model: %s via Bedrock region: %s)\n" \
  "${MODEL}" "${REGION}"
