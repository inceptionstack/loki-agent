#!/usr/bin/env bash
# packs/kiro-cli/install.sh — Install Kiro CLI (AWS agentic IDE terminal client)
#
# Usage:
#   ./install.sh [--region us-east-1]
#                [--kiro-api-key KEY | --from-secret SECRET_ID]
#
# Kiro CLI v2 supports two auth modes:
#   1. Headless (preferred for automation): set KIRO_API_KEY env var.
#      Get a key at https://app.kiro.dev (account settings).
#   2. Interactive (browser-based SSO):
#      kiro-cli login --use-device-flow
#
# If you pass --kiro-api-key (or --from-secret pointing at a Secrets Manager
# secret containing the key), this pack will wire KIRO_API_KEY into the
# ec2-user environment so Kiro CLI picks it up automatically on login.
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_API_KEY="$(pack_config_get kiro-api-key "")"
PACK_ARG_FROM_SECRET="$(pack_config_get from-secret "")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Kiro CLI v2 — AWS agentic IDE terminal client with MCP server support.

Kiro CLI v2 can run in two modes:

  1. Headless (non-interactive, no browser) — uses KIRO_API_KEY env var
  2. Interactive (browser-based SSO)        — uses 'kiro-cli login --use-device-flow'

Options:
  --region          AWS region (informational only; Kiro uses its own inference)
                    (default: us-east-1)
  --kiro-api-key    API key for headless mode. Written to ~/.kiro/env and
                    /etc/profile.d/kiro-cli.sh so Kiro CLI picks it up.
  --from-secret     AWS Secrets Manager secret id/arn whose value is the
                    Kiro API key (alternative to --kiro-api-key).
  --help            Show this help message

Post-install authentication:
  Without API key:  kiro-cli login --use-device-flow   # browser SSO
  With API key:     already wired up — just run 'kiro-cli'

Examples:
  ./install.sh
  ./install.sh --region eu-west-1
  ./install.sh --kiro-api-key kro_xxxxx
  ./install.sh --from-secret /faststart/kiro-api-key
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage; exit 0 ;;
    --region)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --region requires a value" >&2; exit 2; }
      PACK_ARG_REGION="$2"; shift 2 ;;
    --kiro-api-key)
      [[ $# -ge 2 ]] || { echo "error: --kiro-api-key requires a value" >&2; exit 2; }
      PACK_ARG_API_KEY="$2"; shift 2 ;;
    --from-secret)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --from-secret requires a value" >&2; exit 2; }
      PACK_ARG_FROM_SECRET="$2"; shift 2 ;;
    --model)
      # Kiro CLI uses its own cloud inference — models are selected inside
      # the CLI via /model. Any --model passed in from the generic bootstrap
      # path is safely ignored. 'kiro-cloud' is our sentinel from install.sh
      # for clarity; real Bedrock ids are also tolerated for back-compat.
      if [[ $# -ge 2 && "$2" != -* ]]; then
        if [[ "$2" != "kiro-cloud" ]]; then
          log "ignoring --model '$2' — Kiro CLI uses its own cloud inference (select via /model inside the CLI)"
        fi
        shift 2
      else
        shift
      fi ;;
    --)
      shift; break ;;
    -*)
      echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      echo "error: unexpected positional argument: $1" >&2; exit 2 ;;
  esac
done

REGION="${PACK_ARG_REGION}"

# Resolve --from-secret → KIRO_API_KEY
if [[ -n "${PACK_ARG_FROM_SECRET}" ]]; then
  if [[ -n "${PACK_ARG_API_KEY}" ]]; then
    fail "cannot use --kiro-api-key and --from-secret together"
  fi
  log "Resolving Kiro API key from Secrets Manager: ${PACK_ARG_FROM_SECRET}"
  if ! PACK_ARG_API_KEY="$(aws secretsmanager get-secret-value \
        --secret-id "${PACK_ARG_FROM_SECRET}" \
        --region "${REGION}" \
        --query SecretString --output text 2>/dev/null)"; then
    fail "failed to read secret ${PACK_ARG_FROM_SECRET} in ${REGION}. Check IAM perms and secret id."
  fi
  [[ -n "${PACK_ARG_API_KEY}" ]] || fail "secret ${PACK_ARG_FROM_SECRET} is empty"
fi

pack_banner "kiro-cli"
log "region=${REGION} (informational — Kiro CLI uses its own cloud inference)"
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  log "auth mode: headless (KIRO_API_KEY will be configured)"
else
  log "auth mode: interactive (run 'kiro-cli login --use-device-flow' after install)"
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl python3

# ── Step 1: Install Kiro CLI ──────────────────────────────────────────────────
step "Installing Kiro CLI via upstream installer (stable channel → latest)"

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

# Verify v2+ (required for --no-interactive / KIRO_API_KEY headless mode)
# Version strings look like: "kiro-cli 2.0.0" — tolerate any whitespace/prefix.
KIROCLI_MAJOR="$(printf '%s' "${KIROCLI_VERSION}" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
if [[ -n "${KIROCLI_MAJOR}" && "${KIROCLI_MAJOR}" -lt 2 ]]; then
  warn "Kiro CLI v${KIROCLI_MAJOR} detected — this pack is designed for v2+. Headless mode may not work."
fi

# ── Step 2: Install MCP server prerequisites ──────────────────────────────────
step "Installing MCP server prerequisites (uv + uvenv + build tools)"

# Install build tools for MCP servers with C extensions (matches AWS sample repo)
log "Installing build tools for MCP servers..."
if command -v dnf &>/dev/null; then
  sudo dnf install -y -q gcc python3-devel 2>/dev/null || warn "Failed to install build tools (gcc, python3-devel)"
fi

# Install uv (fast Python package manager) if not present
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

# Install uvenv (MCP server installer used by AWS samples)
if ! command -v uvenv &>/dev/null; then
  log "Installing uvenv..."
  pip3 install uvenv 2>/dev/null || warn "pip3 install uvenv failed"
fi

if command -v uvenv &>/dev/null; then
  ok "uvenv available"
else
  warn "uvenv not found — will skip MCP server installs"
fi

# ── Step 3: Install common AWS MCP servers ────────────────────────────────────
step "Installing common AWS MCP servers"

if command -v uvenv &>/dev/null; then
  MCP_SERVERS=(
    "awslabs.terraform-mcp-server"
    "awslabs.ecs-mcp-server"
    "awslabs.eks-mcp-server"
    "awslabs.core-mcp-server"
    "awslabs.aws-documentation-mcp-server"
  )

  for mcp_server in "${MCP_SERVERS[@]}"; do
    log "Installing MCP server: ${mcp_server}"
    uvenv install "${mcp_server}" 2>/dev/null && \
      ok "Installed: ${mcp_server}" || \
      warn "Could not install ${mcp_server} (will be fetched on first use)"
  done
else
  warn "uvenv not available — skipping MCP server installs (install manually with: uvenv install awslabs.<server>)"
fi

# ── Step 4: Wire up KIRO_API_KEY if provided ─────────────────────────────────
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  step "Configuring KIRO_API_KEY for headless mode"

  # Target user is always ec2-user on our AMIs
  KIRO_USER="${KIRO_USER:-ec2-user}"
  KIRO_USER_HOME="$(getent passwd "${KIRO_USER}" | cut -d: -f6 2>/dev/null || echo "/home/${KIRO_USER}")"
  KIRO_ENV_FILE="${KIRO_USER_HOME}/.kiro/env"

  mkdir -p "$(dirname "${KIRO_ENV_FILE}")"

  # Write key to a dedicated env file, 0600. Prefer this over /etc/environment
  # so the secret isn't readable by other users.
  umask 077
  printf 'export KIRO_API_KEY=%q\n' "${PACK_ARG_API_KEY}" > "${KIRO_ENV_FILE}"
  umask 022
  chmod 600 "${KIRO_ENV_FILE}"
  chown -R "${KIRO_USER}:${KIRO_USER}" "$(dirname "${KIRO_ENV_FILE}")" 2>/dev/null || true

  # Source it from ec2-user's .bash_profile so interactive + non-interactive
  # SSH / SSM sessions both see it. Idempotent — only appended once.
  KIRO_PROFILE="${KIRO_USER_HOME}/.bash_profile"
  KIRO_SRC_LINE='[[ -f ~/.kiro/env ]] && source ~/.kiro/env'
  if ! grep -qxF "${KIRO_SRC_LINE}" "${KIRO_PROFILE}" 2>/dev/null; then
    echo "" >> "${KIRO_PROFILE}"
    echo "# Load KIRO_API_KEY (headless mode) — managed by lowkey kiro-cli pack" >> "${KIRO_PROFILE}"
    echo "${KIRO_SRC_LINE}" >> "${KIRO_PROFILE}"
    chown "${KIRO_USER}:${KIRO_USER}" "${KIRO_PROFILE}" 2>/dev/null || true
  fi

  ok "KIRO_API_KEY written to ${KIRO_ENV_FILE} (0600) and sourced from ~/.bash_profile"
fi

# ── Step 5: Post-install instructions ────────────────────────────────────────
step "Post-install notice"

if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  cat <<'NOTICE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [KIRO CLI v2] HEADLESS MODE READY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  KIRO_API_KEY is configured — no interactive login required.
  Kiro CLI will auto-auth on startup.

  Usage:
    kiro-cli                               # Interactive TUI
    kiro-cli --no-interactive "prompt"     # Headless one-shot (CI-friendly)
    kiro-cli --agent platform-engineer     # Start with specific agent
    /model                                 # Select model (inside CLI)
    /tools                                 # List MCP tools (inside CLI)

  Key storage: ~/.kiro/env (0600)
  Rotate via: --from-secret /your/secret OR edit ~/.kiro/env

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTICE
else
  cat <<'NOTICE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [KIRO CLI v2] AUTHENTICATION REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Choose one of the following:

  ─ INTERACTIVE (browser SSO) ─
    kiro-cli login --use-device-flow
      → prints a device code + URL; enter the code in your browser.

  ─ HEADLESS (no browser) ─
    Get an API key from https://app.kiro.dev (account settings),
    then re-run this pack with --kiro-api-key KEY (or --from-secret
    /path/in/secrets-manager), OR set KIRO_API_KEY yourself:
      export KIRO_API_KEY="kro_xxx..."
      echo 'export KIRO_API_KEY="kro_xxx..."' >> ~/.kiro/env

  Usage after auth:
    kiro-cli                              # Interactive TUI
    kiro-cli --no-interactive "prompt"    # One-shot, prints to stdout
    kiro-cli --agent platform-engineer    # Specific agent
    /model                                # Select model (inside CLI)
    /tools                                # List MCP tools (inside CLI)

  MCP server config: ~/.kiro/agents/*.json

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTICE
fi

# Install shell profile (aliases + banner)
SHELL_PROFILE="${SCRIPT_DIR}/resources/shell-profile.sh"
if [[ -f "${SHELL_PROFILE}" && -d /etc/profile.d ]]; then
  sudo cp "${SHELL_PROFILE}" /etc/profile.d/kiro-cli.sh 2>/dev/null && \
    ok "Shell profile installed: /etc/profile.d/kiro-cli.sh" || \
    warn "Could not install shell profile (permission denied?)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "kiro-cli"
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  printf "\n[PACK:kiro-cli] INSTALLED — %s, headless mode READY (KIRO_API_KEY set)\n" "${KIROCLI_VERSION}"
else
  printf "\n[PACK:kiro-cli] INSTALLED — %s, run 'kiro-cli login --use-device-flow' to authenticate\n" "${KIROCLI_VERSION}"
fi
