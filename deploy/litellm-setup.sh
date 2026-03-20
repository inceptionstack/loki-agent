#!/bin/bash
set -euo pipefail
ALB_DNS="$1"
API_KEY="$2"

# Find config
CONFIG_FILE=""
for f in /home/ec2-user/.openclaw/openclaw.json5 /home/ec2-user/.openclaw/openclaw.json; do
  [ -f "$f" ] && CONFIG_FILE="$f" && break
done
if [ -z "$CONFIG_FILE" ]; then echo "ERROR: no config found"; exit 1; fi
echo "Found config: $CONFIG_FILE"

# Backup
cp "$CONFIG_FILE" "${CONFIG_FILE}.pre-litellm"

# Convert json5 to json if needed (json5 is a superset of json)
# Try npx json5 first, fall back to stripping comments
if command -v npx &>/dev/null && npx -y json5 < "$CONFIG_FILE" > /tmp/oc-config.json 2>/dev/null; then
  echo "Converted json5 to json"
elif python3 -c "
import json, re, sys
with open('$CONFIG_FILE') as f:
    txt = f.read()
# Strip JS comments and trailing commas
txt = re.sub(r'//.*', '', txt)
txt = re.sub(r'/\*.*?\*/', '', txt, flags=re.DOTALL)
txt = re.sub(r',\s*([}\]])', r'\1', txt)
data = json.loads(txt)
json.dump(data, sys.stdout, indent=2)
" > /tmp/oc-config.json 2>/dev/null; then
  echo "Converted via python3"
else
  cp "$CONFIG_FILE" /tmp/oc-config.json
  echo "Using raw copy (hope it's valid json)"
fi

# Patch with jq
jq --arg baseUrl "http://$ALB_DNS" --arg apiKey "$API_KEY" '
  .models.providers.litellm = {
    baseUrl: $baseUrl,
    apiKey: $apiKey,
    api: "openai-completions",
    models: [
      {id: "claude-opus-4-6", name: "Claude Opus 4.6", reasoning: true, input: ["text","image"], contextWindow: 200000, maxTokens: 64000},
      {id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", reasoning: true, input: ["text","image"], contextWindow: 200000, maxTokens: 64000},
      {id: "claude-3.5-haiku", name: "Claude 3.5 Haiku", reasoning: false, input: ["text","image"], contextWindow: 200000, maxTokens: 8192}
    ]
  }
  | .agents.defaults.model.primary = "litellm/claude-opus-4-6"
  | .agents.defaults.model.fallbacks = ["litellm/claude-sonnet-4-6", "amazon-bedrock/us.anthropic.claude-opus-4-6-v1"]
' /tmp/oc-config.json > /tmp/oc-config-new.json

if [ ! -s /tmp/oc-config-new.json ]; then
  echo "FAIL: jq produced empty output"
  exit 1
fi

cp /tmp/oc-config-new.json "$CONFIG_FILE"
chown ec2-user:ec2-user "$CONFIG_FILE"
echo "OK: config patched"

jq '{primary: .agents.defaults.model.primary, fallbacks: .agents.defaults.model.fallbacks, providers: (.models.providers | keys)}' "$CONFIG_FILE"

echo "Restarting gateway..."
# Get ec2-user uid
EUID=$(id -u ec2-user)
if su - ec2-user -c "XDG_RUNTIME_DIR=/run/user/$EUID systemctl --user restart openclaw-gateway" 2>/dev/null; then
  echo "OK: restarted via systemctl"
else
  # Try sending SIGUSR1 to running gateway process
  GW_PID=$(pgrep -u ec2-user -f "openclaw gateway" | head -1)
  if [ -n "$GW_PID" ]; then
    kill -USR1 $GW_PID
    echo "OK: sent SIGUSR1 to pid $GW_PID"
  else
    echo "WARN: no gateway process found to restart"
  fi
fi

sleep 3
echo "DONE"
