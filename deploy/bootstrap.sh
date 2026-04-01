#!/bin/bash
# deploy/bootstrap.sh — Generic agent pack bootstrap dispatcher
#
# Usage:
#   bootstrap.sh --pack <name> --region <region> [--model <id>] [--key value ...]
#
# Phase 1: System setup (SSM, dnf, data volume, mise, Node.js, .openclaw symlink)
# Phase 2: Pack dispatch (resolve deps from packs/registry.yaml, run install.sh files)
# Phase 3: Post-install (brain files, Claude Code, SSM shell profile, cfn-signal)
#
# Environment variables (all optional unless noted):
#   STACK_NAME   — CloudFormation stack name (enables cfn-signal when set)
#   REGION       — AWS region (overridden by --region if provided)
#   LOGFILE      — log file path (default: /var/log/loki-bootstrap.log)

set -euo pipefail

LOGFILE="${LOGFILE:-/var/log/loki-bootstrap.log}"
exec > >(tee "$LOGFILE") 2>&1

# Trap for unexpected exits — clean up SSM publisher and signal CFN failure
trap '
  echo "[FAIL] Bootstrap exited unexpectedly at line $LINENO" >&2
  aws ssm put-parameter --name "/loki/setup-status" \
    --value "FAILED" \
    --type String --overwrite --region "${REGION:-us-east-1}" >/dev/null 2>&1 || true
  aws ssm put-parameter --name "/loki/setup-step" \
    --value "FAILED at line $LINENO" \
    --type String --overwrite --region "${REGION:-us-east-1}" >/dev/null 2>&1 || true
  touch /tmp/loki-bootstrap-done
  if [[ -n "${STACK_NAME:-}" ]]; then
    /opt/aws/bin/cfn-signal -e 1 --stack "${STACK_NAME}" --resource Instance --region "${REGION:-us-east-1}" 2>/dev/null || true
  fi
' ERR

# ── Helpers ───────────────────────────────────────────────────────────────────
STEP_COUNTER_FILE="/tmp/loki-step-counter"
STEP_TOTAL_FILE="/tmp/loki-step-total"
echo "0" > "$STEP_COUNTER_FILE"
echo "0" > "$STEP_TOTAL_FILE"

step() {
  local n
  n=$(cat "$STEP_COUNTER_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$STEP_COUNTER_FILE"
  local total
  total=$(cat "$STEP_TOTAL_FILE" 2>/dev/null || echo "?")
  echo ""
  echo "========================================"
  echo "[STEP ${n}/${total}] $(date -u '+%H:%M:%S') $1"
  echo "========================================"
  # Publish current step to SSM for the installer to display
  aws ssm put-parameter --name "/loki/setup-step" \
    --value "${n}/${total} $1" \
    --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
}
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
fail() { echo "[FAIL]  $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --pack <name> [OPTIONS]

Generic agent pack bootstrap dispatcher.

Required:
  --pack <name>     Pack to install (e.g. openclaw, hermes)

Common options:
  --region <r>      AWS region for Bedrock        (default: us-east-1)
  --model <id>      Default Bedrock model ID
  --help            Show this help message

All --key value arguments are forwarded to pack install.sh scripts.
Packs silently ignore arguments they don't recognise.

Examples:
  $(basename "$0") --pack openclaw --region us-east-1 --model us.anthropic.claude-opus-4-6-v1
  $(basename "$0") --pack hermes   --region eu-west-1

Environment:
  STACK_NAME    CloudFormation stack name (enables cfn-signal)
  LOGFILE       Override log file path (default: $LOGFILE)
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
PACK_NAME=""
REGION="${REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-}"
# Pack-specific args (written to JSON config)
MODEL=""
GW_PORT=""
MODEL_MODE=""
BEDROCKIFY_PORT=""
HERMES_MODEL=""
LITELLM_URL=""
LITELLM_KEY=""
LITELLM_MODEL=""
PROVIDER_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --pack)
      [[ $# -gt 1 ]] || { echo "ERROR: --pack requires a value" >&2; exit 1; }
      PACK_NAME="$2"
      shift 2
      ;;
    --region)
      [[ $# -gt 1 ]] || { echo "ERROR: --region requires a value" >&2; exit 1; }
      REGION="$2"
      shift 2
      ;;
    --model)
      [[ $# -gt 1 ]] || { echo "ERROR: --model requires a value" >&2; exit 1; }
      MODEL="$2"
      shift 2
      ;;
    --gw-port)
      [[ $# -gt 1 ]] || { echo "ERROR: --gw-port requires a value" >&2; exit 1; }
      GW_PORT="$2"
      shift 2
      ;;
    --model-mode)
      [[ $# -gt 1 ]] || { echo "ERROR: --model-mode requires a value" >&2; exit 1; }
      MODEL_MODE="$2"
      shift 2
      ;;
    --bedrockify-port)
      [[ $# -gt 1 ]] || { echo "ERROR: --bedrockify-port requires a value" >&2; exit 1; }
      BEDROCKIFY_PORT="$2"
      shift 2
      ;;
    --hermes-model)
      [[ $# -gt 1 ]] || { echo "ERROR: --hermes-model requires a value" >&2; exit 1; }
      HERMES_MODEL="$2"
      shift 2
      ;;
    --litellm-base-url|--litellm-url)
      [[ $# -gt 1 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      LITELLM_URL="$2"
      shift 2
      ;;
    --litellm-api-key|--litellm-key)
      [[ $# -gt 1 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      LITELLM_KEY="$2"
      shift 2
      ;;
    --litellm-model)
      [[ $# -gt 1 ]] || { echo "ERROR: --litellm-model requires a value" >&2; exit 1; }
      LITELLM_MODEL="$2"
      shift 2
      ;;
    --provider-api-key|--provider-key)
      [[ $# -gt 1 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      PROVIDER_KEY="$2"
      shift 2
      ;;
    --*)
      # Skip unknown options (with optional value)
      if [[ $# -gt 1 ]] && [[ "$2" != --* ]]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$PACK_NAME" ]]; then
  echo "ERROR: --pack is required" >&2
  echo ""
  usage
  exit 1
fi

# ── Write pack config JSON ────────────────────────────────────────────────────
PACK_CONFIG="/tmp/loki-pack-config.json"
jq -n \
  --arg pack "$PACK_NAME" \
  --arg region "$REGION" \
  --arg model "$MODEL" \
  --arg gw_port "$GW_PORT" \
  --arg model_mode "$MODEL_MODE" \
  --arg bedrockify_port "$BEDROCKIFY_PORT" \
  --arg hermes_model "$HERMES_MODEL" \
  --arg litellm_url "$LITELLM_URL" \
  --arg litellm_key "$LITELLM_KEY" \
  --arg litellm_model "$LITELLM_MODEL" \
  --arg provider_key "$PROVIDER_KEY" \
  '{pack:$pack, region:$region, model:$model, gw_port:$gw_port,
    model_mode:$model_mode, bedrockify_port:$bedrockify_port,
    hermes_model:$hermes_model, litellm_url:$litellm_url,
    litellm_key:$litellm_key, litellm_model:$litellm_model,
    provider_key:$provider_key}' > "${PACK_CONFIG}"
chmod 600 "${PACK_CONFIG}"
chown ec2-user:ec2-user "${PACK_CONFIG}"
export PACK_CONFIG
export AWS_DEFAULT_REGION="${REGION}"

# ── Locate repo root ──────────────────────────────────────────────────────────
# bootstrap.sh lives in deploy/, one level above repo root
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
PACKS_DIR="${REPO_DIR}/packs"
REGISTRY="${PACKS_DIR}/registry.yaml"

step "Bootstrap Dispatcher"
info "Pack: ${PACK_NAME} | Region: ${REGION}${STACK_NAME:+ | Stack: $STACK_NAME}"
info "Repo: ${REPO_DIR}"
info "Instance: $(curl -sf http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo unknown)"

# ── Validate pack exists in registry ─────────────────────────────────────────
if [[ ! -f "$REGISTRY" ]]; then
  fail "Registry not found: $REGISTRY"
  exit 1
fi

# Check pack key exists in registry (look for "  packname:" at start of line)
if ! grep -q "^  ${PACK_NAME}:" "$REGISTRY"; then
  fail "Pack '${PACK_NAME}' not found in registry (${REGISTRY})"
  info "Available packs:"
  grep "^  [a-z]" "$REGISTRY" | awk -F: '{print "  " $1}' | tr -d ' ' | awk '{print "    " $1}'
  exit 1
fi

ok "Pack '${PACK_NAME}' found in registry"

# ── Registry helpers (grep/awk only — no python yaml) ─────────────────────────
# registry_get_flag PACK FIELD — returns "true" or "" for boolean fields
registry_get_flag() {
  local pack="$1"
  local field="$2"
  # Find the pack block and scan until the next top-level pack entry or EOF
  awk "
    /^  ${pack}:/{found=1; next}
    found && /^  [a-z]/{exit}
    found && /^    ${field}: true/{print \"true\"; exit}
  " "$REGISTRY"
}

# registry_get_deps PACK — prints each dep on its own line
registry_get_deps() {
  local pack="$1"
  awk "
    /^  ${pack}:/{found=1; in_deps=0; next}
    found && /^  [a-z]/{exit}
    found && /^    deps:/{in_deps=1; next}
    found && in_deps && /^      - /{gsub(/^      - /, \"\"); print; next}
    found && in_deps && !/^      /{in_deps=0}
  " "$REGISTRY"
}

# registry_get_data_vol PACK — prints data_volume_gb value or "80" default
registry_get_data_vol() {
  local pack="$1"
  local val
  val=$(awk "
    /^  ${pack}:/{found=1; next}
    found && /^  [a-z]/{exit}
    found && /^    data_volume_gb:/{gsub(/^    data_volume_gb: /, \"\"); print; exit}
  " "$REGISTRY")
  echo "${val:-80}"
}

# ── Count total steps dynamically ─────────────────────────────────────────────
# Count step() calls in bootstrap.sh + all pack scripts that will run
_count_steps_in() { grep -c '^step ' "$1" 2>/dev/null || echo 0; }
_total_steps=$(_count_steps_in "${DEPLOY_DIR}/bootstrap.sh")

# Add steps from deps
while IFS= read -r _dep; do
  [[ -n "$_dep" ]] && _dep_script="${PACKS_DIR}/${_dep}/install.sh" && \
    [[ -f "$_dep_script" ]] && _total_steps=$((_total_steps + $(_count_steps_in "$_dep_script")))
done < <(registry_get_deps "${PACK_NAME}")

# Add steps from main pack
_pack_script="${PACKS_DIR}/${PACK_NAME}/install.sh"
[[ -f "$_pack_script" ]] && _total_steps=$((_total_steps + $(_count_steps_in "$_pack_script")))

echo "$_total_steps" > "$STEP_TOTAL_FILE"
chmod 666 "$STEP_COUNTER_FILE" "$STEP_TOTAL_FILE"
chown ec2-user:ec2-user "$STEP_COUNTER_FILE" "$STEP_TOTAL_FILE" 2>/dev/null || true

# ── Phase 1: SYSTEM ───────────────────────────────────────────────────────────
step "Phase 1: System Setup"

# ---- SSM Agent ----
step "SSM Agent"
dnf install -y amazon-ssm-agent 2>/dev/null || true
systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
systemctl is-active amazon-ssm-agent >/dev/null 2>&1 && ok "SSM agent running" || fail "SSM agent not running"

# ---- SSM log publisher (background) ----
(
  while [ ! -f /tmp/loki-bootstrap-done ]; do
    aws ssm put-parameter --name "/loki/setup-log" \
      --value "$(tail -c 4000 "${LOGFILE}")" \
      --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
    aws ssm put-parameter --name "/loki/setup-status" \
      --value "IN_PROGRESS" \
      --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
    sleep 30
  done
  aws ssm put-parameter --name "/loki/setup-log" \
    --value "$(tail -c 4000 "${LOGFILE}")" \
    --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
  aws ssm put-parameter --name "/loki/setup-status" \
    --value "COMPLETE" \
    --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
) &
SSM_PUB_PID=$!
ok "SSM log publisher running (pid=$SSM_PUB_PID)"

# ---- System updates ----
step "System Updates"

# Ensure ec2-user has passwordless sudo (cloud-init usually sets this, but
# some AMIs or custom configs may not; pack install scripts need sudo for
# dnf, systemctl, etc.)
if [[ ! -f /etc/sudoers.d/ec2-user-nopasswd ]]; then
  echo "ec2-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ec2-user-nopasswd
  chmod 440 /etc/sudoers.d/ec2-user-nopasswd
  ok "Passwordless sudo configured for ec2-user"
else
  ok "Passwordless sudo already configured"
fi

dnf update -y 2>&1 | tail -5
ok "System updated"

# ---- Dependencies ----
step "System Dependencies"
dnf install -y git jq htop tmux gnupg2-minimal libatomic gettext
ok "Packages installed"

# ---- Mount data volume ----
DATA_VOL_GB="$(registry_get_data_vol "${PACK_NAME}")"
step "Data Volume (pack requests ${DATA_VOL_GB}GB)"
if [[ "${DATA_VOL_GB}" -gt 0 ]]; then
  DATA_DEV=""
  for attempt in 1 2 3; do
    for dev in /dev/sdb /dev/nvme1n1 /dev/xvdb; do
      [ -b "$dev" ] && DATA_DEV="$dev" && break 2
    done
    info "Waiting for data volume (attempt $attempt)..." && sleep 10
  done
  if [ -n "$DATA_DEV" ]; then
    blkid "$DATA_DEV" | grep -q ext4 || mkfs.ext4 "$DATA_DEV"
    mkdir -p /mnt/ebs-data && mount "$DATA_DEV" /mnt/ebs-data && chown ec2-user:ec2-user /mnt/ebs-data
    ok "Data volume mounted ($DATA_DEV)"
    UUID=$(blkid -s UUID -o value "$DATA_DEV")
    grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /mnt/ebs-data ext4 defaults,nofail 0 2" >> /etc/fstab
  else
    fail "Data volume not found (expected ${DATA_VOL_GB}GB EBS)!"
  fi
else
  info "Pack requests no data volume — skipping mount"
fi

# ---- mise + Node.js (as ec2-user) ----
step "mise + Node.js"
export PACK_NAME REGION
# shellcheck disable=SC2016
sudo -u ec2-user bash << 'MISE_EOF'
set -euo pipefail
step() { echo ""; echo "========================================"; echo "[STEP] $(date -u '+%H:%M:%S') $1"; echo "========================================"; }
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }

step "mise install"
curl -fsSL https://mise.run | sh
export PATH="/home/ec2-user/.local/bin:$PATH"
eval "$(/home/ec2-user/.local/bin/mise activate bash)"
ok "mise installed: $(mise --version 2>/dev/null || echo unknown)"

# Persist mise activation to .bashrc so SSM sessions have node/npm/openclaw on PATH
if ! grep -q 'mise activate' "${HOME}/.bashrc" 2>/dev/null; then
  echo '' >> "${HOME}/.bashrc"
  echo '# mise — runtime version manager (node, python, etc.)' >> "${HOME}/.bashrc"
  echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}/.bashrc"
  echo 'eval "$(~/.local/bin/mise activate bash 2>/dev/null)"' >> "${HOME}/.bashrc"
  ok "mise activation added to .bashrc"
fi

step "Node.js"
export MISE_NODE_VERIFY=false
mise use -g node@latest
eval "$(/home/ec2-user/.local/bin/mise activate bash)"
ok "Node installed: $(node --version 2>/dev/null || echo unknown)"
MISE_EOF
ok "mise + Node.js setup complete"

# ---- Pack-specific shell profile (aliases + banner) ----
PACK_PROFILE="${PACKS_DIR}/${PACK_NAME}/resources/shell-profile.sh"
if [[ -f "$PACK_PROFILE" ]]; then
  # Source pack profile to get PACK_ALIASES, PACK_BANNER_NAME, etc.
  # Default all expected vars first — packs may omit optional ones
  PACK_ALIASES=""
  PACK_BANNER_NAME="${PACK_NAME}"
  PACK_BANNER_EMOJI="🤖"
  PACK_BANNER_COMMANDS=""
  source "$PACK_PROFILE"

  # Write aliases to ec2-user .bashrc
  sudo -u ec2-user tee -a /home/ec2-user/.bashrc > /dev/null << ALIASES_BLOCK
${PACK_ALIASES}
ALIASES_BLOCK

  # Write welcome banner to ec2-user .bashrc (unquoted heredoc: \$ → $ at write time, ${PACK_*} expanded by outer shell)
  sudo -u ec2-user tee -a /home/ec2-user/.bashrc > /dev/null << BANNER_BLOCK

# Welcome banner (only for interactive login shells)
if [[ \$- == *i* ]] && [[ -z "\$LOKI_BANNER_SHOWN" ]]; then
  export LOKI_BANNER_SHOWN=1
  printf '\n\033[1;35m${PACK_BANNER_EMOJI} InceptionStack ${PACK_BANNER_NAME}\033[0m\n\n'
  printf '${PACK_BANNER_COMMANDS}\n'
fi
BANNER_BLOCK
  ok "Pack shell profile added to .bashrc (${PACK_NAME})"
else
  warn "No shell profile found for pack ${PACK_NAME}"
fi

# ---- .openclaw symlink ----
step "Data Volume Symlink"
sudo -u ec2-user bash << 'SYMLINK_EOF'
set -euo pipefail
ok() { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }
if [ -d /mnt/ebs-data ]; then
  [ -d /mnt/ebs-data/.openclaw ] || mkdir -p /mnt/ebs-data/.openclaw
  if [ -d "${HOME}/.openclaw" ] && [ ! -L "${HOME}/.openclaw" ]; then
    mv "${HOME}/.openclaw/"* /mnt/ebs-data/.openclaw/ 2>/dev/null || true
    rm -rf "${HOME}/.openclaw"
  fi
  ln -sfn /mnt/ebs-data/.openclaw "${HOME}/.openclaw"
  chmod 700 "${HOME}/.openclaw"
  ok "Symlinked .openclaw -> /mnt/ebs-data/.openclaw"
else
  mkdir -p "${HOME}/.openclaw"
  chmod 700 "${HOME}/.openclaw"
  info "No data volume — using local .openclaw"
fi
mkdir -p "${HOME}/.openclaw/workspace"
chmod 700 "${HOME}/.openclaw/workspace"
ok "Workspace ready"
SYMLINK_EOF

# ---- Enable linger for ec2-user (allows user systemd services to survive logout) ----
step "Enable Linger"
loginctl enable-linger ec2-user
ok "Linger enabled for ec2-user"

# ── Phase 2: PACKS ────────────────────────────────────────────────────────────
step "Phase 2: Pack Dispatch"

# Resolve deps for the requested pack
DEPS=()
while IFS= read -r dep; do
  [[ -n "$dep" ]] && DEPS+=("$dep")
done < <(registry_get_deps "${PACK_NAME}")

info "Pack: ${PACK_NAME}"
if [[ ${#DEPS[@]} -gt 0 ]]; then
  info "Deps: ${DEPS[*]}"
else
  info "Deps: (none)"
fi

# Run deps first (in order)
for dep in "${DEPS[@]}"; do
  DEP_INSTALL="${PACKS_DIR}/${dep}/install.sh"
  if [[ ! -f "$DEP_INSTALL" ]]; then
    fail "Dependency install script not found: ${DEP_INSTALL}"
    exit 1
  fi
  info "Installing dependency: ${dep}"
  # Run as ec2-user with mise/node on PATH; PACK_CONFIG is auto-detected by packs
  sudo -u ec2-user --preserve-env=PACK_CONFIG,AWS_DEFAULT_REGION bash -c '
    export PATH="/home/ec2-user/.local/bin:$PATH"
    eval "$(/home/ec2-user/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true
    NODE_PREFIX=$(npm prefix -g 2>/dev/null || true)
    [ -n "$NODE_PREFIX" ] && export PATH="${NODE_PREFIX}/bin:$PATH"
    bash "$@"
  ' -- "${DEP_INSTALL}" || {
    fail "Dependency pack '${dep}' install failed"
    exit 1
  }
  ok "Dependency '${dep}' complete"
done

# Run the requested pack
PACK_INSTALL="${PACKS_DIR}/${PACK_NAME}/install.sh"
if [[ ! -f "$PACK_INSTALL" ]]; then
  fail "Pack install script not found: ${PACK_INSTALL}"
  exit 1
fi
info "Installing pack: ${PACK_NAME}"
sudo -u ec2-user --preserve-env=PACK_CONFIG,AWS_DEFAULT_REGION bash -c '
  export PATH="/home/ec2-user/.local/bin:$PATH"
  eval "$(/home/ec2-user/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true
  NODE_PREFIX=$(npm prefix -g 2>/dev/null || true)
  [ -n "$NODE_PREFIX" ] && export PATH="${NODE_PREFIX}/bin:$PATH"
  bash "$@"
' -- "${PACK_INSTALL}" || {
  fail "Pack '${PACK_NAME}' install failed"
  exit 1
}
ok "Pack '${PACK_NAME}' complete"

# ── Phase 3: POST-INSTALL ─────────────────────────────────────────────────────
step "Phase 3: Post-Install"

# ---- Brain files ----
BRAIN_FLAG="$(registry_get_flag "${PACK_NAME}" "brain")"
if [[ "${BRAIN_FLAG}" == "true" ]]; then
  step "InceptionStack Brain"
  BRAIN_REPO="https://raw.githubusercontent.com/inceptionstack/loki-agent/main/deploy/brain"
  BRAIN_DEST="/home/ec2-user/.openclaw/workspace"
  mkdir -p "${BRAIN_DEST}"
  for bf in SOUL.md IDENTITY.md USER.md TOOLS.md AGENTS.md CLAUDE.md PROJECT-GUIDELINES.md HEARTBEAT.md APP-REGISTRY.md; do
    curl -fsSL "${BRAIN_REPO}/${bf}" -o "${BRAIN_DEST}/${bf}" 2>/dev/null \
      && info "  + $bf" \
      || info "  - $bf (skip)"
  done
  chown ec2-user:ec2-user "${BRAIN_DEST}/"*.md 2>/dev/null || true
  ok "Brain files installed"
else
  info "Brain files: skipped (brain=false for ${PACK_NAME})"
fi

# ---- Claude Code ----
CC_FLAG="$(registry_get_flag "${PACK_NAME}" "claude_code")"
if [[ "${CC_FLAG}" == "true" ]]; then
  step "Claude Code"
  sudo -u ec2-user bash << 'CC_EOF'
set -euo pipefail
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }
export PATH="/home/ec2-user/.local/bin:$PATH"
eval "$(/home/ec2-user/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true

npm install -g @anthropic-ai/claude-code 2>/dev/null || info "Claude Code install failed (non-fatal)"
if command -v mise &>/dev/null; then
  mise reshim 2>/dev/null || true
fi

if command -v claude &>/dev/null; then
  mkdir -p ~/.claude
  echo "export CLAUDE_CODE_USE_BEDROCK=1" >> ~/.bashrc
  cat > ~/.claude/settings.json << CCEOF
{
  "skipDangerousModePermissionPrompt": true
}
CCEOF
  ok "Claude Code installed: $(claude --version 2>/dev/null || echo unknown)"
else
  info "Claude Code not available after install (non-fatal)"
fi
CC_EOF
else
  info "Claude Code: skipped (claude_code=false for ${PACK_NAME})"
fi

# ---- SSM Shell Profile ----
step "SSM Shell Profile"
# Re-source pack profile if available (may already be sourced, but safe to repeat)
PACK_PROFILE="${PACKS_DIR}/${PACK_NAME}/resources/shell-profile.sh"
_SSM_BANNER_EMOJI="🤖"
_SSM_BANNER_NAME="Agent Environment"
_SSM_BANNER_COMMANDS="  (no commands configured for this pack)"
if [[ -f "$PACK_PROFILE" ]]; then
  source "$PACK_PROFILE"
  _SSM_BANNER_EMOJI="${PACK_BANNER_EMOJI}"
  _SSM_BANNER_NAME="${PACK_BANNER_NAME}"
  _SSM_BANNER_COMMANDS="${PACK_BANNER_COMMANDS}"
fi
cat > /etc/profile.d/loki.sh << LOKIPROFILE
# SSM session: auto-switch to ec2-user with welcome banner
if [ "\$(whoami)" = "ssm-user" ] && [ -z "\$LOKI_PROFILE_LOADED" ]; then
  export LOKI_PROFILE_LOADED=1
  printf '\n\033[1;35m${_SSM_BANNER_EMOJI} InceptionStack ${_SSM_BANNER_NAME}\033[0m\n\n'
  printf '${_SSM_BANNER_COMMANDS}\n'
  exec sudo -iu ec2-user
fi
LOKIPROFILE
chmod 644 /etc/profile.d/loki.sh
ok "Shell profile installed (/etc/profile.d/loki.sh)"

# ---- Bedrock model access check ----
step "Bedrock Model Access Check"
sudo -u ec2-user bash << 'BEDROCK_EOF'
set -euo pipefail
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
fail() { echo "[FAIL]  $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }
if aws bedrock get-use-case-for-model-access --region us-east-1 >/dev/null 2>&1; then
  ok "Bedrock access form verified"
else
  fail "Bedrock access form not submitted — complete it at: https://us-east-1.console.aws.amazon.com/bedrock/home#/modelaccess"
fi
BEDROCK_EOF

# ---- Complete ----
# ---- Clean up config file (contains secrets) ----
rm -f "${PACK_CONFIG}"
info "Pack config cleaned up"

step "Bootstrap Complete"
touch /tmp/loki-bootstrap-done
ok "Pack '${PACK_NAME}' bootstrap complete at $(date -u)"

# ---- cfn-signal ----
if [[ -n "${STACK_NAME}" ]]; then
  step "CloudFormation Signal"
  if aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" &>/dev/null; then
    /opt/aws/bin/cfn-signal -e 0 --stack "${STACK_NAME}" --resource Instance --region "${REGION}" \
      && ok "cfn-signal sent (stack=${STACK_NAME})" \
      || fail "cfn-signal failed"
  else
    info "Stack '${STACK_NAME}' not found in region ${REGION} — skipping cfn-signal"
  fi
fi
