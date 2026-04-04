#!/usr/bin/env bash
# packs/kiro-cli/install.sh — Install Kiro CLI (AWS agentic IDE terminal client)
#
# Usage:
#   ./install.sh [--region us-east-1]
#
# Kiro CLI uses its own cloud inference (not Bedrock/bedrockify).
# Requires interactive login AFTER install:
#   kiro-cli login --use-device-flow
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Kiro CLI — AWS agentic IDE terminal client with MCP server support.

Kiro CLI uses its own cloud inference endpoint (not AWS Bedrock).
No bedrockify dependency required.

Options:
  --region   AWS region (informational only; Kiro uses its own inference)
             (default: us-east-1)
  --help     Show this help message

Post-install (interactive — requires browser):
  kiro-cli login --use-device-flow

Examples:
  ./install.sh
  ./install.sh --region eu-west-1
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --region)  PACK_ARG_REGION="$2"; shift 2 ;;
    --model)   [[ $# -gt 1 ]] && shift 2 || shift ;;  # Ignore generic --model
    *)         [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"

pack_banner "kiro-cli"
log "region=${REGION} (informational — Kiro CLI uses its own cloud inference)"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl python3

# ── Step 1: Install Kiro CLI ──────────────────────────────────────────────────
step "Installing Kiro CLI via upstream installer"

if command -v kiro-cli &>/dev/null; then
  KIROCLI_EXISTING="$(kiro-cli --version 2>/dev/null || echo unknown)"
  log "kiro-cli already installed (${KIROCLI_EXISTING}) — reinstalling"
fi

curl -fsSL https://cli.kiro.dev/install -o /tmp/install-kiro-cli.sh
sudo -u ec2-user bash /tmp/install-kiro-cli.sh
rm -f /tmp/install-kiro-cli.sh

# Refresh PATH for current session
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

if ! command -v kiro-cli &>/dev/null; then
  fail "kiro-cli command not found after install. Check PATH or installer output."
fi

KIROCLI_VERSION="$(kiro-cli --version 2>/dev/null || echo unknown)"
ok "Kiro CLI installed: ${KIROCLI_VERSION}"

# ── Step 2: Install MCP server prerequisites ──────────────────────────────────
step "Installing MCP server prerequisites (uv + pip)"

if ! command -v uv &>/dev/null; then
  log "Installing uv (Python package manager)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
fi

if command -v uv &>/dev/null; then
  ok "uv available: $(uv --version 2>/dev/null || echo unknown)"
else
  warn "uv not found after install — MCP servers may not install correctly"
fi

if ! command -v uvx &>/dev/null; then
  warn "uvx not found — MCP tool runner unavailable; skipping MCP server installs"
else
  ok "uvx available"
fi

# ── Step 3: Install common AWS MCP servers ────────────────────────────────────
step "Installing common AWS MCP servers"

if command -v uvx &>/dev/null; then
  MCP_SERVERS=(
    "awslabs.terraform-mcp-server"
    "awslabs.ecs-mcp-server"
    "awslabs.eks-mcp-server"
    "awslabs.core-mcp-server"
    "awslabs.aws-documentation-mcp-server"
  )

  for mcp_server in "${MCP_SERVERS[@]}"; do
    log "Caching MCP server: ${mcp_server}"
    uvx --from "${mcp_server}" true 2>/dev/null && \
      ok "Cached: ${mcp_server}" || \
      warn "Could not pre-cache ${mcp_server} (will be fetched on first use)"
  done
else
  warn "uvx not available — skipping MCP server pre-cache (servers will be fetched on first use)"
fi

# ── Step 4: Post-install instructions ────────────────────────────────────────
step "Post-install notice"

cat <<'NOTICE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [KIRO CLI] INTERACTIVE LOGIN REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Kiro CLI requires IAM Identity Center (SSO) authentication.
  This step cannot be automated — it requires a browser.

  Run this command interactively after connecting to the instance:

    kiro-cli login --use-device-flow

  This will print a device code + URL. Open the URL in your
  browser, enter the code, and authenticate with your AWS SSO.

  Usage after login:
    kiro-cli                              # Start interactive CLI
    kiro-cli --agent platform-engineer    # Start with specific agent
    kiro-cli settings chat.defaultAgent   # Show/set default agent
    /model                                # Select AI model (inside CLI)
    /tools                                # List MCP tools (inside CLI)

  MCP server config: ~/.kiro/agents/*.json

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

NOTICE

# Install shell profile (aliases + banner)
SHELL_PROFILE="${SCRIPT_DIR}/resources/shell-profile.sh"
if [[ -f "${SHELL_PROFILE}" && -d /etc/profile.d ]]; then
  sudo cp "${SHELL_PROFILE}" /etc/profile.d/kiro-cli.sh 2>/dev/null && \
    ok "Shell profile installed: /etc/profile.d/kiro-cli.sh" || \
    warn "Could not install shell profile (permission denied?)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "kiro-cli"
printf "\n[PACK:kiro-cli] INSTALLED — run 'kiro-cli login --use-device-flow' to authenticate\n"
