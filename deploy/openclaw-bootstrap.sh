#!/bin/bash
set -euo pipefail
LOGFILE="/var/log/openclaw-setup.log"
exec > >(tee $LOGFILE) 2>&1

# Args passed via environment
# ACCT_ID, REGION, DEFAULT_MODEL, BEDROCK_REGION, GW_PORT
# MODEL_MODE, LITELLM_BASE_URL, LITELLM_API_KEY, LITELLM_MODEL, PROVIDER_API_KEY
# STACK_NAME (optional — only set by CloudFormation/SAM deploys)

step() { echo ""; echo "========================================"; echo "[STEP] $(date -u '+%H:%M:%S') $1"; echo "========================================"; }
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
fail() { echo "[FAIL]  $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }

STACK_NAME="${STACK_NAME:-}"

step "OpenClaw Instance Setup"
info "Account: $ACCT_ID | Region: $REGION${STACK_NAME:+ | Stack: $STACK_NAME}"
info "Model: $DEFAULT_MODEL | Mode: $MODEL_MODE"
info "Instance: $(curl -sf http://169.254.169.254/latest/meta-data/instance-id || echo unknown)"

# ---- SSM Agent ----
step "SSM Agent"
dnf install -y amazon-ssm-agent 2>/dev/null || true
systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
systemctl is-active amazon-ssm-agent >/dev/null 2>&1 && ok "SSM agent running" || fail "SSM agent not running"

# ---- SSM log publisher (background) ----
(
  while [ ! -f /tmp/openclaw-setup-done ]; do
    aws ssm put-parameter --name "/openclaw/setup-log" --value "$(tail -100 $LOGFILE)" --type String --overwrite --region $REGION >/dev/null 2>&1 || true
    aws ssm put-parameter --name "/openclaw/setup-status" --value "IN_PROGRESS" --type String --overwrite --region $REGION >/dev/null 2>&1 || true
    sleep 30
  done
  aws ssm put-parameter --name "/openclaw/setup-log" --value "$(tail -200 $LOGFILE)" --type String --overwrite --region $REGION >/dev/null 2>&1 || true
  aws ssm put-parameter --name "/openclaw/setup-status" --value "COMPLETE" --type String --overwrite --region $REGION >/dev/null 2>&1 || true
) &

# ---- System updates ----
step "System Updates"
dnf update -y 2>&1 | tail -5
ok "System updated"

# ---- Mount data volume ----
step "Data Volume"
DATA_DEV=""
for attempt in 1 2 3; do
  for dev in /dev/sdb /dev/nvme1n1 /dev/xvdb; do
    [ -b "$dev" ] && DATA_DEV="$dev" && break 2
  done
  echo "Waiting for data volume (attempt $attempt)..." && sleep 10
done
if [ -n "$DATA_DEV" ]; then
  blkid "$DATA_DEV" | grep -q ext4 || mkfs.ext4 "$DATA_DEV"
  mkdir -p /mnt/ebs-data && mount "$DATA_DEV" /mnt/ebs-data && chown ec2-user:ec2-user /mnt/ebs-data
  ok "Data volume mounted ($DATA_DEV)"
  UUID=$(blkid -s UUID -o value "$DATA_DEV")
  grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /mnt/ebs-data ext4 defaults,nofail 0 2" >> /etc/fstab
else
  fail "Data volume not found!"
fi

# ---- Dependencies ----
step "Dependencies"
dnf install -y git jq htop tmux gnupg2-minimal libatomic
ok "Packages installed"

# ---- ec2-user application installs ----
# Pass env vars into ec2-user context
export MODEL_MODE LITELLM_BASE_URL LITELLM_API_KEY LITELLM_MODEL DEFAULT_MODEL PROVIDER_API_KEY BEDROCK_REGION GW_PORT REGION ACCT_ID STACK_NAME
sudo -u ec2-user --preserve-env=MODEL_MODE,LITELLM_BASE_URL,LITELLM_API_KEY,LITELLM_MODEL,DEFAULT_MODEL,PROVIDER_API_KEY,BEDROCK_REGION,GW_PORT,REGION,ACCT_ID,STACK_NAME bash << 'USEREOF'
set -euo pipefail
cd ~
step() { echo ""; echo "========================================"; echo "[STEP] $(date -u '+%H:%M:%S') $1"; echo "========================================"; }
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
fail() { echo "[FAIL]  $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }

step "SSH Key"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# SSH key injection removed — use SSM Session Manager for access
chmod 600 ~/.ssh/authorized_keys
ok "Master SSH key added"

step "mise"
curl -fsSL https://mise.run | sh
echo 'eval "$(/home/ec2-user/.local/bin/mise activate bash)"' >> ~/.bashrc
export PATH="/home/ec2-user/.local/bin:$PATH"
eval "$(mise activate bash)"
ok "mise installed: $(mise --version 2>/dev/null || echo unknown)"

step "Node.js"
export MISE_NODE_VERIFY=false
mise use -g node@latest
eval "$(mise activate bash)"
ok "Node installed: $(node --version 2>/dev/null || echo unknown)"

step "OpenClaw"
npm install -g openclaw
mise reshim || true
NODE_PREFIX=$(npm prefix -g)
export PATH="$NODE_PREFIX/bin:$PATH"
ok "OpenClaw installed: $(openclaw --version 2>/dev/null || echo unknown)"


step "Claude Code"
npm install -g @anthropic-ai/claude-code 2>/dev/null || info "Claude Code install failed (non-fatal)"
mise reshim 2>/dev/null || true
if command -v claude &>/dev/null; then
  ok "Claude Code installed: $(claude --version 2>/dev/null || echo unknown)"
  mkdir -p ~/.claude
  if [ "$MODEL_MODE" = "litellm" ] && [ -n "$LITELLM_BASE_URL" ] && [ -n "$LITELLM_API_KEY" ]; then
    echo "export ANTHROPIC_BASE_URL=\"$LITELLM_BASE_URL\"" >> ~/.bashrc
    echo "export ANTHROPIC_API_KEY=\"$LITELLM_API_KEY\"" >> ~/.bashrc
    cat > ~/.claude/settings.json << CCEOF
{
  "model": "${LITELLM_MODEL:-claude-opus-4-6}",
  "skipDangerousModePermissionPrompt": true
}
CCEOF
    ok "Claude Code → LiteLLM proxy"
  else
    echo "export CLAUDE_CODE_USE_BEDROCK=1" >> ~/.bashrc
    cat > ~/.claude/settings.json << CCEOF
{
  "model": "${DEFAULT_MODEL:-us.anthropic.claude-opus-4-6-v1}",
  "skipDangerousModePermissionPrompt": true
}
CCEOF
    ok "Claude Code → Bedrock direct"
  fi
else
  info "Claude Code not available (install failed)"
fi

step "Data Volume Symlink"
if [ -d /mnt/ebs-data ] && [ ! -d /mnt/ebs-data/.openclaw ]; then mkdir -p /mnt/ebs-data/.openclaw; fi
if [ -d /mnt/ebs-data/.openclaw ]; then
  if [ -d ~/.openclaw ] && [ ! -L ~/.openclaw ]; then
    mv ~/.openclaw/* /mnt/ebs-data/.openclaw/ 2>/dev/null || true
    rm -rf ~/.openclaw
  fi
  ln -sfn /mnt/ebs-data/.openclaw ~/.openclaw
  ok "Symlinked .openclaw -> /mnt/ebs-data/.openclaw"
chmod 700 ~/.openclaw
ok "State dir secured (700)"
else
  info "No data volume, using local .openclaw"
fi

step "Workspace"
mkdir -p ~/.openclaw/workspace
ok "Workspace ready"
chmod 700 ~/.openclaw/workspace

step "OpenClaw Config"
curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/deploy/openclaw-config-gen.py -o /tmp/oc-cfggen.py
GW_TOKEN=$(openssl rand -hex 24)
python3 /tmp/oc-cfggen.py "$BEDROCK_REGION" "$DEFAULT_MODEL" "$GW_PORT" "$GW_TOKEN" "$MODEL_MODE" "$LITELLM_BASE_URL" "$LITELLM_API_KEY" "$LITELLM_MODEL" "$PROVIDER_API_KEY"
ok "Config written (mode=$MODEL_MODE)"
chmod 600 ~/.openclaw/openclaw.json
ok "Config file secured (600)"

step "Bedrock Model Access"
if aws bedrock get-use-case-for-model-access --region us-east-1 >/dev/null 2>&1; then
  ok "Bedrock form verified"
else
  fail "Bedrock form not submitted"
  curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/deploy/bedrock-motd.sh -o /tmp/bedrock-motd.sh
  bash /tmp/bedrock-motd.sh 2>/dev/null || true
fi

# Test Bedrock invoke
info "Testing Bedrock model invoke..."
echo '{"anthropic_version":"bedrock-2023-05-31","max_tokens":10,"messages":[{"role":"user","content":"Say OK"}]}' > /tmp/bedrock-test.json
if aws bedrock-runtime invoke-model --model-id $DEFAULT_MODEL --body fileb:///tmp/bedrock-test.json --content-type application/json --accept application/json --region us-east-1 /tmp/bedrock-out.json 2>&1; then
  ok "Bedrock invoke SUCCESS"
else
  fail "Bedrock invoke failed (may need 15min for auto-subscribe)"
fi

step "Systemd Service"
NODE_BIN=$(which node)
OC_MAIN=$NODE_PREFIX/lib/node_modules/openclaw/dist/index.js
OC_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/openclaw-gateway.service << SVCEOF
[Unit]
Description=OpenClaw Gateway (v$OC_VERSION)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$NODE_BIN $OC_MAIN gateway --port $GW_PORT
Restart=always
RestartSec=5
KillMode=process
Environment="HOME=/home/ec2-user"
Environment="PATH=/home/ec2-user/.local/bin:/home/ec2-user/.local/share/mise/installs/node/current/bin:$NODE_PREFIX/bin:/usr/local/bin:/usr/bin:/bin"
Environment=OPENCLAW_GATEWAY_PORT=$GW_PORT
Environment=OPENCLAW_GATEWAY_TOKEN=$GW_TOKEN
Environment="OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service"
Environment=OPENCLAW_SERVICE_MARKER=openclaw
Environment=OPENCLAW_SERVICE_KIND=gateway
Environment=OPENCLAW_SERVICE_VERSION=$OC_VERSION

[Install]
WantedBy=default.target
SVCEOF
ok "Systemd unit written"
USEREOF

# ---- SSM Session Preferences ----
step "SSM Session Preferences"
SSM_DOC_CONTENT='{"schemaVersion":"1.0","description":"SSM prefs","sessionType":"Standard_Stream","inputs":{"runAsEnabled":false,"shellProfile":{"linux":"stty -echo 2>/dev/null; clear; printf '"'"'\\n\\033[1;35m? InceptionStack OpenClaw Environment\\033[0m\\n\\n  openclaw tui    ? Launch TUI\\n  openclaw status ? Gateway status\\n\\n'"'"'; stty echo 2>/dev/null; exec sudo -iu ec2-user"}}}'
if aws ssm get-document --name SSM-SessionManagerRunShell --region $REGION >/dev/null 2>&1; then
  aws ssm update-document --name SSM-SessionManagerRunShell --content "$SSM_DOC_CONTENT" --document-version '$LATEST' --region $REGION >/dev/null 2>&1 || true
else
  aws ssm create-document --name SSM-SessionManagerRunShell --document-type Session --content "$SSM_DOC_CONTENT" --region $REGION >/dev/null 2>&1 || true
fi
ok "SSM Session doc configured"

# ---- InceptionStack Brain ----
step "InceptionStack Brain"
BRAIN_REPO="https://raw.githubusercontent.com/inceptionstack/loki-agent/main/deploy/brain"
BRAIN_DEST="/home/ec2-user/.openclaw/workspace"
for bf in SOUL.md IDENTITY.md USER.md TOOLS.md AGENTS.md CLAUDE.md PROJECT-GUIDELINES.md HEARTBEAT.md APP-REGISTRY.md; do
  curl -fsSL "$BRAIN_REPO/$bf" -o "$BRAIN_DEST/$bf" 2>/dev/null && info "  + $bf" || info "  - $bf (skip)"
done
chown ec2-user:ec2-user $BRAIN_DEST/*.md 2>/dev/null
ok "Brain installed"

# ---- Start Gateway ----
step "Start Gateway"
loginctl enable-linger ec2-user
ok "Linger enabled"
sudo -u ec2-user bash -c 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; systemctl --user daemon-reload; systemctl --user enable openclaw-gateway.service; systemctl --user start openclaw-gateway.service'
sleep 5
sudo -u ec2-user bash -c 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; systemctl --user is-active openclaw-gateway.service' 2>/dev/null && ok "Gateway RUNNING" || fail "Gateway may not have started"

# ---- Admin User Info ----
step "Admin User"
info "Admin user has API access keys only (no console login)"

step "Setup Complete"
ok "All done at $(date -u)"
touch /tmp/openclaw-setup-done

# ---- Signal CloudFormation (only for CFN/SAM deploys) ----
if [[ -n "$STACK_NAME" ]] && aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &>/dev/null; then
  /opt/aws/bin/cfn-signal -e 0 --stack "$STACK_NAME" --resource Instance --region "$REGION"
fi
