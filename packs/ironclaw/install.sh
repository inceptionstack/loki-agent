#!/usr/bin/env bash
# packs/ironclaw/install.sh — Install IronClaw (NEAR AI Rust agent) and configure it to use bedrockify
#
# Usage:
#   ./install.sh [--region us-east-1] [--model us.anthropic.claude-sonnet-4-6-v1] [--bedrockify-port 8090]
#
# Assumes:
#   - bedrockify is already installed and running (see packs/bedrockify/)
#   - curl available
#   - IAM role with bedrock:InvokeModel permissions (handled by bedrockify)
#
# Idempotent: safe to re-run.
#
# Notes:
#   - IronClaw is a single static Rust binary (musl build) — no Rust/Cargo needed.
#   - We bypass the `ironclaw onboard` OAuth wizard by writing .env directly with
#     LLM_BACKEND=openai_compatible pointing at bedrockify.
#   - Known issue: IronClaw may attempt to use the Linux secret-service (dbus) for
#     keychain operations on some code paths. On headless EC2 this can error.
#     If IronClaw adds an IRONCLAW_NO_KEYCHAIN or similar env var in a future release,
#     add it to ~/.ironclaw/.env to suppress the keychain lookup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
# Defaults from config file (written by bootstrap dispatcher), then CLI overrides
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6-v1")"
PACK_ARG_BEDROCKIFY_PORT="$(pack_config_get bedrockify_port "8090")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install IronClaw (NEAR AI Rust agent) and configure it to use bedrockify.

Options:
  --region           AWS region for Bedrock           (default: us-east-1)
  --model            Bedrock model ID (LLM_MODEL)     (default: us.anthropic.claude-sonnet-4-6-v1)
  --bedrockify-port  Port where bedrockify listens    (default: 8090)
  --help             Show this help message

Note: The --model value is passed directly as LLM_MODEL in ~/.ironclaw/.env.
      bedrockify handles the Bedrock ID mapping at inference time.

Examples:
  ./install.sh --region us-east-1
  ./install.sh --model us.anthropic.claude-opus-4-6-v1 --bedrockify-port 8090
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
require_cmd curl

# Verify bedrockify is running
HEALTH="$(curl -sf "http://127.0.0.1:${BEDROCKIFY_PORT}/" 2>&1)" || true
if ! printf '%s' "${HEALTH}" | grep -q '"status":"ok"'; then
  fail "bedrockify is not running on port ${BEDROCKIFY_PORT}. Install bedrockify pack first."
fi
ok "bedrockify is healthy on port ${BEDROCKIFY_PORT}"

# ── Install IronClaw binary ───────────────────────────────────────────────────
step "Installing IronClaw binary"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) RELEASE_ARCH="aarch64-unknown-linux-musl" ;;
  x86_64)        RELEASE_ARCH="x86_64-unknown-linux-musl" ;;
  *) fail "Unsupported architecture: $ARCH" ;;
esac
log "Architecture: ${ARCH} → ${RELEASE_ARCH}"

if command -v ironclaw &>/dev/null; then
  IRONCLAW_EXISTING="$(ironclaw --version 2>/dev/null || echo unknown)"
  log "ironclaw already installed (${IRONCLAW_EXISTING}) — reinstalling"
fi

# Ensure local bin dir exists
mkdir -p "${HOME}/.local/bin"

# Download and extract to /tmp, then find and install the binary
RELEASE_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-${RELEASE_ARCH}.tar.gz"
log "Downloading from: ${RELEASE_URL}"

EXTRACT_DIR="$(mktemp -d /tmp/ironclaw-extract-XXXXXX)"
trap 'rm -rf "${EXTRACT_DIR}"' EXIT

curl -fsSL "${RELEASE_URL}" | tar xz -C "${EXTRACT_DIR}"

# Find the ironclaw binary (may be at root or in a subdirectory)
IRONCLAW_BIN="$(find "${EXTRACT_DIR}" -type f -name "ironclaw" | head -1)"
if [[ -z "${IRONCLAW_BIN}" ]]; then
  # Some releases use the full target triple as the binary name
  IRONCLAW_BIN="$(find "${EXTRACT_DIR}" -type f \( -name "ironclaw*" \) | grep -v '\.tar\|\.gz\|\.md\|\.txt' | head -1)"
fi
if [[ -z "${IRONCLAW_BIN}" ]]; then
  fail "Could not locate ironclaw binary in extracted archive. Contents: $(find "${EXTRACT_DIR}" | head -20)"
fi
log "Found binary: ${IRONCLAW_BIN}"

install -m 755 "${IRONCLAW_BIN}" "${HOME}/.local/bin/ironclaw"

# Add local bin to PATH for current session
export PATH="${HOME}/.local/bin:$PATH"

if ! command -v ironclaw &>/dev/null; then
  fail "ironclaw command not found after install. Check PATH or install output."
fi

IRONCLAW_VERSION="$(ironclaw --version 2>/dev/null || echo unknown)"
ok "IronClaw installed: ${IRONCLAW_VERSION}"

# ── Configure IronClaw ────────────────────────────────────────────────────────
step "Configuring IronClaw"

mkdir -p "${HOME}/.ironclaw"

# Write .env to configure bedrockify as the OpenAI-compatible backend.
# This bypasses the `ironclaw onboard` OAuth wizard entirely.
cat > "${HOME}/.ironclaw/.env" <<EOF
# IronClaw configuration — managed by loki-agent pack installer
# Do not edit manually; re-run the pack installer to update.

# Use bedrockify as an OpenAI-compatible LLM backend (no NEAR AI OAuth needed)
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:${BEDROCKIFY_PORT}/v1
LLM_API_KEY=not-needed
LLM_MODEL=${MODEL}

# Headless EC2: if a future IronClaw release adds a no-keychain flag, set it here.
# Example (not yet confirmed upstream): IRONCLAW_NO_KEYCHAIN=1
EOF

chmod 600 "${HOME}/.ironclaw/.env"
ok "IronClaw config written: ${HOME}/.ironclaw/.env"

# ── Sanity check ──────────────────────────────────────────────────────────────
step "Sanity check"

IRONCLAW_HELP="$(ironclaw --help 2>&1 || ironclaw --version 2>&1 || echo failed)"
if printf '%s' "${IRONCLAW_HELP}" | grep -qi 'ironclaw\|usage\|help'; then
  ok "IronClaw responds to --help/--version"
else
  warn "IronClaw sanity check inconclusive. Output: ${IRONCLAW_HELP}"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "ironclaw"
printf "\n[PACK:ironclaw] INSTALLED — ironclaw CLI ready (model: %s via bedrockify:%s)\n" \
  "${MODEL}" "${BEDROCKIFY_PORT}"
