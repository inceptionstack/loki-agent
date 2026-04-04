#!/usr/bin/env bash
# packs/nemoclaw/install.sh — Install NemoClaw (OpenClaw in sandboxed OpenShell via bedrockify)
#
# Usage:
#   ./install.sh [--region us-east-1] [--model us.anthropic.claude-sonnet-4-6] [--bedrockify-port 8090]
#               [--sandbox-name loki-assistant] [--telegram-token TOKEN] [--allowed-chat-ids IDS]
#
# Assumes:
#   - bedrockify is already installed and running (see packs/bedrockify/)
#   - Docker available (installed by Step 1 if absent)
#   - IAM role with bedrock:InvokeModel permissions (handled by bedrockify)
#   - Profile: personal_assistant ONLY (sandbox blocks AWS API access)
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6")"
PACK_ARG_BEDROCKIFY_PORT="$(pack_config_get bedrockify_port "8090")"
PACK_ARG_SANDBOX_NAME="$(pack_config_get sandbox_name "loki-assistant")"
PACK_ARG_TELEGRAM_TOKEN="$(pack_config_get telegram_token "")"
PACK_ARG_ALLOWED_CHAT_IDS="$(pack_config_get allowed_chat_ids "")"
PACK_ARG_PROFILE="$(pack_config_get profile "")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install NemoClaw — OpenClaw in sandboxed OpenShell with Bedrock inference.
Only compatible with the personal_assistant profile (sandbox blocks AWS API access).

Options:
  --region           AWS region for Bedrock              (default: us-east-1)
  --model            Bedrock model ID (via bedrockify)   (default: us.anthropic.claude-sonnet-4-6)
  --bedrockify-port  Port where bedrockify listens        (default: 8090)
  --sandbox-name     NemoClaw sandbox name               (default: loki-assistant)
  --telegram-token   Telegram bot token (optional)
  --allowed-chat-ids Comma-separated Telegram chat IDs (optional)
  --profile          Deployment profile name             (checked: personal_assistant only)
  --help             Show this help message

Profiles:
  personal_assistant  ✓ Supported — Bedrock inference via bedrockify on host
  builder             ✗ Blocked  — sandbox isolates AWS API access
  account_assistant   ✗ Blocked  — sandbox isolates AWS API access

Examples:
  ./install.sh --region us-east-1
  ./install.sh --sandbox-name my-agent --telegram-token 123456:ABC
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)           usage; exit 0 ;;
    --region)            PACK_ARG_REGION="$2";            shift 2 ;;
    --model)             PACK_ARG_MODEL="$2";             shift 2 ;;
    --bedrockify-port)   PACK_ARG_BEDROCKIFY_PORT="$2";  shift 2 ;;
    --sandbox-name)      PACK_ARG_SANDBOX_NAME="$2";     shift 2 ;;
    --telegram-token)    PACK_ARG_TELEGRAM_TOKEN="$2";   shift 2 ;;
    --allowed-chat-ids)  PACK_ARG_ALLOWED_CHAT_IDS="$2"; shift 2 ;;
    --profile)           PACK_ARG_PROFILE="$2";          shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
BEDROCKIFY_PORT="${PACK_ARG_BEDROCKIFY_PORT}"
SANDBOX_NAME="${PACK_ARG_SANDBOX_NAME}"
TELEGRAM_TOKEN="${PACK_ARG_TELEGRAM_TOKEN}"
ALLOWED_CHAT_IDS="${PACK_ARG_ALLOWED_CHAT_IDS}"
PROFILE="${PACK_ARG_PROFILE}"

pack_banner "nemoclaw"
log "region=${REGION} model=${MODEL} bedrockify-port=${BEDROCKIFY_PORT} sandbox-name=${SANDBOX_NAME}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
require_cmd curl python3

# ── Step 0: Profile Guard ─────────────────────────────────────────────────────
step "Profile compatibility check"

# Allowlist check — only personal_assistant is compatible; empty/unset is tolerated for standalone use
if [[ -n "${PROFILE}" && "${PROFILE}" != "personal_assistant" ]]; then
  printf "\n"
  fail "NemoClaw is only compatible with the personal_assistant profile. The '${PROFILE}' profile requires AWS API access, which NemoClaw's sandbox blocks. Use --pack openclaw for this profile."
fi
ok "Profile check passed (profile='${PROFILE:-standalone}')"

# ── Step 1: Install Docker ────────────────────────────────────────────────────
step "Installing Docker + cgroup v2 configuration"

if systemctl is-active --quiet docker 2>/dev/null; then
  log "Docker is already running — skipping install"
else
  log "Installing Docker..."
  if command -v dnf &>/dev/null; then
    sudo dnf install -y docker
  elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y docker.io
  else
    fail "Unsupported package manager — cannot install Docker"
  fi
fi

# Configure cgroup v2 (required for NemoClaw preflight on AL2023)
DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_NEEDS_RESTART=false
if [[ ! -f "${DAEMON_JSON}" ]] || ! grep -q '"default-cgroupns-mode"' "${DAEMON_JSON}" 2>/dev/null; then
  log "Configuring Docker cgroup v2 mode..."
  sudo mkdir -p /etc/docker
  if [[ -f "${DAEMON_JSON}" ]] && [[ -s "${DAEMON_JSON}" ]] && command -v jq &>/dev/null; then
    # Merge into existing config to avoid clobbering other settings
    jq '. + {"default-cgroupns-mode": "host"}' "${DAEMON_JSON}" | sudo tee "${DAEMON_JSON}.tmp" > /dev/null \
      && sudo mv "${DAEMON_JSON}.tmp" "${DAEMON_JSON}"
  else
    echo '{"default-cgroupns-mode": "host"}' | sudo tee "${DAEMON_JSON}" > /dev/null
  fi
  DOCKER_NEEDS_RESTART=true
  ok "Docker daemon.json updated with cgroup v2 config"
else
  log "Docker cgroup v2 already configured"
fi

# Enable and start Docker
if ! systemctl is-enabled --quiet docker 2>/dev/null; then
  sudo systemctl enable docker
fi
if ! systemctl is-active --quiet docker 2>/dev/null; then
  sudo systemctl start docker
elif [[ "${DOCKER_NEEDS_RESTART}" == "true" ]]; then
  log "Restarting Docker to apply cgroup v2 config..."
  sudo systemctl restart docker
fi

# Add ec2-user to docker group (idempotent)
if id ec2-user &>/dev/null; then
  sudo usermod -aG docker ec2-user 2>/dev/null || true
fi

# Verify Docker is functional
# NOTE: bootstrap.sh runs packs via 'sudo -u ec2-user' which doesn't pick up
# newly added groups. Use 'sudo docker' for verification.
if ! sudo docker info &>/dev/null; then
  fail "Docker is installed but not functional. Check systemctl status docker."
fi
ok "Docker is running and functional"

# ── Step 2: Verify bedrockify health ─────────────────────────────────────────
step "Verifying bedrockify health"

check_bedrockify_health "${BEDROCKIFY_PORT}"

# ── Step 3: Install NemoClaw + OpenShell ─────────────────────────────────────
step "Installing NemoClaw + OpenShell"

if command -v nemoclaw &>/dev/null; then
  NEMOCLAW_EXISTING="$(nemoclaw --version 2>/dev/null || echo unknown)"
  log "nemoclaw already installed (${NEMOCLAW_EXISTING}) — reinstalling"
fi

# NOTE: npm install -g is broken (upstream bug GH-503)
# Use the upstream curl installer which clones repo + npm links
export NEMOCLAW_NON_INTERACTIVE=1
export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

# Refresh PATH for current session
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

if ! command -v nemoclaw &>/dev/null; then
  fail "nemoclaw command not found after install. Check PATH or install output."
fi

NEMOCLAW_VERSION="$(nemoclaw --version 2>/dev/null || echo unknown)"
ok "NemoClaw installed: ${NEMOCLAW_VERSION}"

# AL2023 has sha256sum but not shasum — NemoClaw's OpenShell installer needs shasum
if ! command -v shasum &>/dev/null && command -v sha256sum &>/dev/null; then
  log "Creating shasum wrapper for AL2023 compatibility (NemoClaw/OpenShell needs shasum)..."
  cat > /tmp/shasum-wrapper.sh << 'SHAWRAP'
#!/usr/bin/env bash
# shasum compatibility wrapper for AL2023 (sha256sum → shasum -a 256)
if [[ "$1" == "-a" && "$2" == "256" ]]; then
  shift 2
  sha256sum "$@"
else
  sha256sum "$@"
fi
SHAWRAP
  chmod +x /tmp/shasum-wrapper.sh
  sudo cp /tmp/shasum-wrapper.sh /usr/local/bin/shasum
  ok "shasum wrapper installed at /usr/local/bin/shasum"
fi

if ! command -v openshell &>/dev/null; then
  warn "openshell command not found — may be installed in a non-standard location"
else
  OPENSHELL_VERSION="$(openshell --version 2>/dev/null || echo unknown)"
  ok "OpenShell installed: ${OPENSHELL_VERSION}"
fi

# ── Step 4: Create sandbox (non-interactive onboard) ─────────────────────────
step "Creating NemoClaw sandbox (non-interactive)"

# Apply network policy
NETWORK_POLICY="${SCRIPT_DIR}/resources/network-policy.yaml"
if [[ -f "${NETWORK_POLICY}" ]]; then
  log "Network policy: ${NETWORK_POLICY}"
fi

# CRITICAL: NemoClaw's onboard checks Docker internally as the current user.
# bootstrap.sh runs packs via 'sudo -u ec2-user' which doesn't pick up newly
# added docker group. We need to re-exec with the docker group active.
# Use 'sg docker' to spawn a subshell with the group, then run onboard inside it.
sg docker -c "
  export NEMOCLAW_NON_INTERACTIVE=1
  export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
  export NEMOCLAW_SANDBOX_NAME='${SANDBOX_NAME}'
  export NEMOCLAW_PROVIDER=custom
  export COMPATIBLE_API_KEY=unused
  export NEMOCLAW_ENDPOINT_URL='http://127.0.0.1:${BEDROCKIFY_PORT}/v1'
  export NEMOCLAW_MODEL='${MODEL}'
  export NEMOCLAW_POLICY_MODE=suggested
  export NEMOCLAW_NETWORK_POLICY='${NETWORK_POLICY}'
  export PATH='/home/ec2-user/.local/bin:/usr/local/bin:${PATH}'
  eval \"\$(/home/ec2-user/.local/bin/mise activate bash 2>/dev/null)\" 2>/dev/null || true
  nemoclaw onboard --non-interactive --yes-i-accept-third-party-software
"

# Verify sandbox created
if ! nemoclaw "${SANDBOX_NAME}" status &>/dev/null; then
  warn "nemoclaw status check inconclusive — sandbox may still be initializing"
fi
ok "Sandbox '${SANDBOX_NAME}' onboarded"

# ── Step 5: Configure Telegram bridge ────────────────────────────────────────
step "Configuring Telegram bridge"

if [[ -n "${TELEGRAM_TOKEN}" ]]; then
  log "Setting up Telegram bridge for sandbox '${SANDBOX_NAME}'..."
  export TELEGRAM_BOT_TOKEN="${TELEGRAM_TOKEN}"
  export ALLOWED_CHAT_IDS="${ALLOWED_CHAT_IDS}"
  # NemoClaw's host-side bridge picks up these env vars automatically
  ok "Telegram bridge environment configured (token set)"
else
  log "No Telegram token provided — Telegram bridge skipped"
fi

# ── Step 6: Inject brain files ────────────────────────────────────────────────
step "Injecting brain files into sandbox"

BRAIN_DIR="${HOME}/.openclaw/workspace"
BRAIN_FILES=(SOUL.md USER.md IDENTITY.md AGENTS.md)

# Get running container ID for the sandbox (exact match first, fallback to substring)
CONTAINER_ID="$(sg docker -c "docker ps --filter 'name=^/${SANDBOX_NAME}\$' --format '{{.ID}}'" 2>/dev/null | head -1)"
if [[ -z "${CONTAINER_ID}" ]]; then
  CONTAINER_ID="$(sg docker -c "docker ps --filter 'name=${SANDBOX_NAME}' -q" 2>/dev/null | head -1)"
fi

if [[ -z "${CONTAINER_ID}" ]]; then
  warn "Sandbox container '${SANDBOX_NAME}' not found in running containers — skipping brain injection"
  warn "Run brain injection manually after sandbox starts: docker cp SOUL.md <container>:/sandbox/.openclaw/workspace/"
else
  SANDBOX_WORKSPACE="/sandbox/.openclaw/workspace"
  for brain_file in "${BRAIN_FILES[@]}"; do
    src="${BRAIN_DIR}/${brain_file}"
    if [[ -f "${src}" ]]; then
      sg docker -c "docker cp '${src}' '${CONTAINER_ID}:${SANDBOX_WORKSPACE}/'" 2>/dev/null && \
        ok "Injected ${brain_file}" || \
        warn "Failed to inject ${brain_file} (container may not have ${SANDBOX_WORKSPACE})"
    else
      warn "Brain file not found, skipping: ${src}"
    fi
  done
fi

# ── Step 7: Health check polling + done marker ────────────────────────────────
step "Health check"

log "Polling for sandbox '${SANDBOX_NAME}' to reach running state (timeout: 120s)..."

if timeout 120 bash -c "
  until nemoclaw '${SANDBOX_NAME}' status --json 2>/dev/null | \\
    python3 -c \"import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('sandbox',{}).get('status')=='running' else 1)\" >/dev/null 2>&1; do
    sleep 5
  done
" 2>/dev/null; then
  ok "Sandbox '${SANDBOX_NAME}' is running"
else
  warn "Sandbox did not reach running state within 120s — check: nemoclaw ${SANDBOX_NAME} status"
fi

write_done_marker "nemoclaw"

# Install shell profile (aliases + banner) if /etc/profile.d exists
SHELL_PROFILE="${SCRIPT_DIR}/resources/shell-profile.sh"
if [[ -f "${SHELL_PROFILE}" && -d /etc/profile.d ]]; then
  sudo cp "${SHELL_PROFILE}" /etc/profile.d/nemoclaw.sh 2>/dev/null && \
    ok "Shell profile installed: /etc/profile.d/nemoclaw.sh" || \
    warn "Could not install shell profile (permission denied?)"
fi

printf "\n[PACK:nemoclaw] INSTALLED — sandbox '%s' ready (model: %s via bedrockify:%s)\n" \
  "${SANDBOX_NAME}" "${MODEL}" "${BEDROCKIFY_PORT}"
