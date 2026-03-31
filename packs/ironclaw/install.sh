#!/usr/bin/env bash
# packs/ironclaw/install.sh — Install IronClaw and configure it to use bedrockify
#
# Usage:
#   ./install.sh [--region us-east-1] [--model us.anthropic.claude-sonnet-4-6-v1] [--bedrockify-port 8090]
#
# Assumes:
#   - bedrockify is already installed and running (see packs/bedrockify/)
#   - curl available
#   - IAM role with bedrock:InvokeModel permissions (handled by bedrockify)
#
# IronClaw is a single static Rust binary — no Rust/Cargo needed at runtime.
# We download the pre-built musl binary from GitHub releases.
#
# Note: IronClaw has an `ironclaw onboard` wizard that tries browser-based
# NEAR AI OAuth. We bypass this entirely by writing .env directly with
# LLM_BACKEND=openai_compatible, pointing at bedrockify.
#
# Known issue: IronClaw may attempt dbus/secret-service for keychain access
# on Linux. On headless EC2, this may fail silently. Since we set
# LLM_BACKEND=openai_compatible with explicit credentials in .env,
# the OS credential store path should not be triggered for LLM access.
# If startup fails with dbus errors, install dbus: sudo dnf install -y dbus
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6-v1")"
PACK_ARG_BEDROCKIFY_PORT="$(pack_config_get bedrockify_port "8090")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install IronClaw and configure it to use bedrockify.

Options:
  --region           AWS region for Bedrock          (default: us-east-1)
  --model            Model ID for LLM_MODEL           (default: us.anthropic.claude-sonnet-4-6-v1)
  --bedrockify-port  Port where bedrockify listens   (default: 8090)
  --help             Show this help message

Note: IronClaw is a CLI tool — no systemd service is created.
      NEAR AI OAuth is bypassed; bedrockify handles all LLM access.

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

pack_banner "ironclaw"
log "region=${REGION} model=${MODEL} bedrockify-port=${BEDROCKIFY_PORT}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl tar

check_bedrockify_health "${BEDROCKIFY_PORT}"

# ── Install IronClaw ──────────────────────────────────────────────────────────
step "Installing IronClaw"

if command -v ironclaw &>/dev/null; then
  IC_EXISTING="$(ironclaw --version 2>/dev/null || echo unknown)"
  log "ironclaw already installed (${IC_EXISTING}) — reinstalling"
fi

# Detect architecture and pick the right release binary
ARCH="$(uname -m)"
case "${ARCH}" in
  aarch64|arm64) RELEASE_ARCH="aarch64-unknown-linux-musl" ;;
  x86_64)        RELEASE_ARCH="x86_64-unknown-linux-musl" ;;
  *)             fail "Unsupported architecture: ${ARCH}" ;;
esac

DOWNLOAD_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-${RELEASE_ARCH}.tar.gz"
TEMP_DIR="$(mktemp -d)"

log "Downloading ironclaw-${RELEASE_ARCH} from GitHub releases..."
if ! curl -fsSL "${DOWNLOAD_URL}" -o "${TEMP_DIR}/ironclaw.tar.gz"; then
  rm -rf "${TEMP_DIR}"
  fail "Failed to download IronClaw from ${DOWNLOAD_URL}"
fi

# Extract and find the binary (tar layout may vary across releases)
tar xzf "${TEMP_DIR}/ironclaw.tar.gz" -C "${TEMP_DIR}"
IRONCLAW_BIN="$(find "${TEMP_DIR}" -name 'ironclaw' -type f -executable 2>/dev/null | head -1)"
if [[ -z "${IRONCLAW_BIN}" ]]; then
  # Fallback: binary might not have +x in the archive
  IRONCLAW_BIN="$(find "${TEMP_DIR}" -name 'ironclaw' -type f 2>/dev/null | head -1)"
fi
if [[ -z "${IRONCLAW_BIN}" ]]; then
  rm -rf "${TEMP_DIR}"
  fail "Could not find ironclaw binary in downloaded archive"
fi

mkdir -p "${HOME}/.local/bin"
install -m 755 "${IRONCLAW_BIN}" "${HOME}/.local/bin/ironclaw"
rm -rf "${TEMP_DIR}"

export PATH="${HOME}/.local/bin:$PATH"

if ! command -v ironclaw &>/dev/null; then
  fail "ironclaw command not found after install. Check PATH."
fi

IC_VERSION="$(ironclaw --version 2>/dev/null || echo unknown)"
ok "IronClaw installed: ${IC_VERSION}"

# ── Configure IronClaw ────────────────────────────────────────────────────────
step "Configuring IronClaw"

mkdir -p "${HOME}/.ironclaw"

# Write .env with bedrockify config — bypasses NEAR AI OAuth entirely
cat > "${HOME}/.ironclaw/.env" <<EOF
# IronClaw config — using bedrockify as OpenAI-compatible backend
# No NEAR AI auth needed; bedrockify handles Bedrock via IAM instance profile
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:${BEDROCKIFY_PORT}/v1
LLM_API_KEY=not-needed
LLM_MODEL=${MODEL}
EOF

chmod 600 "${HOME}/.ironclaw/.env"
ok "IronClaw config written: ${HOME}/.ironclaw/.env"

# ── Sanity check ─────────────────────────────────────────────────────────────
step "Sanity check"

IC_VER="$(ironclaw --version 2>/dev/null || ironclaw --help 2>/dev/null | head -1 || echo unknown)"
ok "ironclaw version: ${IC_VER}"

# ── Done ─────────────────────────────────────────────────────────────────────
write_done_marker "ironclaw"
printf "\n[PACK:ironclaw] INSTALLED — ironclaw CLI ready (model: %s via bedrockify:%s)\n" \
  "${MODEL}" "${BEDROCKIFY_PORT}"
