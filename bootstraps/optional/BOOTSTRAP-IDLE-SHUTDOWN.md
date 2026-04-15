# BOOTSTRAP-IDLE-SHUTDOWN.md — Idle Shutdown for EC2 Agents

> **Purpose:** Automatically shut down the EC2 instance when the user has been idle for over 1 hour. Sends a Telegram warning with a **one-tap wake link** before shutdown. Fully independent of the OpenClaw gateway — runs via systemd timer.

---

## How It Works

1. A systemd timer fires every 5 minutes
2. It runs a bash script that reads the OpenClaw session JSONL files to find the last user message timestamp
3. If idle > 1 hour: generates a one-time wake token, stores it in SSM Parameter Store, and sends a Telegram alert with a clickable wake link
4. On the next run (5 min later), if still idle: `sudo shutdown -h now`
5. State is tracked in `memory/heartbeat-state.json` (`idleShutdownAlertSent` flag)

### Wake Link Flow

```
Idle script → generates UUID token → stores in SSM → sends Telegram with link
User taps link → API Gateway → Lambda → validates token → sends Telegram "starting up" → starts EC2
```

- The wake link is **one-time use** — token is deleted after first use
- If the instance is already running, the Lambda detects it and responds accordingly
- Expired/invalid tokens show a friendly error page

---

## Prerequisites

- EC2 instance with `sudo` access for `ec2-user`
- OpenClaw installed and configured with Telegram channel
- Telegram bot token and your Telegram chat ID (numeric)
- Python 3 available (`/usr/bin/python3`)
- IAM permissions for SSM Parameter Store, Lambda, API Gateway, and EC2

---

## Step 1 — Create the Python Helper

Save to `~/.openclaw/workspace/idle-check.py`:

```python
#!/usr/bin/env python3
"""Helper for idle-check scripts"""
import sys, json
from datetime import datetime, timezone

def parse_ts(ts):
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try:
            return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
        except:
            pass
    return None

cmd = sys.argv[1]

if cmd == '--latest-ts':
    latest = None
    for line in sys.stdin:
        try:
            obj = json.loads(line)
            ts = obj.get('createdAt') or obj.get('timestamp') or obj.get('ts')
            if ts and (latest is None or ts > latest):
                latest = ts
        except:
            pass
    print(latest or '')

elif cmd == '--hours-idle':
    ts = sys.argv[2]
    dt = parse_ts(ts)
    if dt is None:
        print('PARSE_ERROR')
        sys.exit(1)
    now = datetime.now(timezone.utc)
    hours = (now - dt).total_seconds() / 3600
    print(f'{hours:.4f}')

elif cmd == '--should-shutdown':
    hours = float(sys.argv[2])
    threshold = float(sys.argv[3])
    print('yes' if hours > threshold else 'no')

elif cmd == '--get-state':
    state_file = sys.argv[2]
    key = sys.argv[3]
    try:
        with open(state_file) as f:
            d = json.load(f)
        print(str(d.get(key, False)).lower())
    except:
        print('false')

elif cmd == '--set-state':
    state_file = sys.argv[2]
    key = sys.argv[3]
    val = sys.argv[4]
    parsed_val = True if val == 'true' else False if val == 'false' else val
    try:
        with open(state_file) as f:
            d = json.load(f)
    except:
        d = {}
    d[key] = parsed_val
    with open(state_file, 'w') as f:
        json.dump(d, f, indent=2)
```

---

## Step 2 — Deploy the Wake Lambda + API Gateway

The wake link is powered by a Lambda behind an HTTP API Gateway. The Lambda validates the one-time token, notifies you on Telegram, and starts the instance.

### 2.1 — Store Configuration in SSM

All configuration is stored in SSM Parameter Store — nothing is hardcoded in the Lambda:

```bash
INSTANCE_ID="YOUR_INSTANCE_ID"
TELEGRAM_CHAT_ID="YOUR_NUMERIC_CHAT_ID"
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"

aws ssm put-parameter --name "/openclaw/wake-config/instance-id" \
  --value "$INSTANCE_ID" --type String --overwrite

aws ssm put-parameter --name "/openclaw/wake-config/telegram-chat-id" \
  --value "$TELEGRAM_CHAT_ID" --type String --overwrite

aws ssm put-parameter --name "/openclaw/wake-config/telegram-bot-token" \
  --value "$TELEGRAM_BOT_TOKEN" --type SecureString --overwrite
```

### 2.2 — Create the Lambda IAM Role

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="us-east-1"

aws iam create-role \
  --role-name loki-wake-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

aws iam put-role-policy \
  --role-name loki-wake-lambda-role \
  --policy-name wake-permissions \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"ec2:StartInstances\"],
        \"Resource\": \"arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"ec2:DescribeInstanceStatus\"],
        \"Resource\": \"*\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"ssm:GetParameter\", \"ssm:DeleteParameter\"],
        \"Resource\": [
          \"arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/openclaw/wake-token\",
          \"arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/openclaw/wake-config/*\"
        ]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
        \"Resource\": \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:*\"
      }
    ]
  }"

# Wait for IAM propagation
sleep 10
```

### 2.3 — Create the Lambda Function

Save as `wake-lambda/index.mjs`:

```javascript
import { SSMClient, GetParameterCommand, DeleteParameterCommand } from "@aws-sdk/client-ssm";
import { EC2Client, StartInstancesCommand, DescribeInstanceStatusCommand } from "@aws-sdk/client-ec2";

const ssm = new SSMClient({});
const ec2 = new EC2Client({});
const TOKEN_PARAM = "/openclaw/wake-token";
const CONFIG_PREFIX = "/openclaw/wake-config/";

async function getParam(name, decrypt = false) {
  const res = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: decrypt }));
  return res.Parameter.Value;
}

async function sendTelegram(botToken, chatId, text) {
  await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
  });
}

const html = (title, msg, emoji) => ({
  statusCode: 200,
  headers: { "content-type": "text/html; charset=utf-8" },
  body: `<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>
  <style>body{font-family:-apple-system,system-ui,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#0D1117;color:#F0F6FC;text-align:center}
  .card{background:#161B22;border:1px solid #30363D;border-radius:12px;padding:2rem;max-width:400px}
  h1{font-size:3rem;margin:0}p{color:#8B949E;font-size:1.1rem}</style></head>
  <body><div class="card"><h1>${emoji}</h1><h2>${title}</h2><p>${msg}</p></div></body></html>`
});

export const handler = async (event) => {
  const token = event.queryStringParameters?.token;
  if (!token) return html("Missing Token", "No wake token provided.", "❌");

  // Validate token
  let stored;
  try {
    stored = await getParam(TOKEN_PARAM);
  } catch (e) {
    if (e.name === "ParameterNotFound") return html("Expired", "This wake link has already been used or expired.", "⏰");
    throw e;
  }
  if (token !== stored) return html("Invalid Token", "This wake link is not valid.", "🚫");

  // Token valid — consume it
  await ssm.send(new DeleteParameterCommand({ Name: TOKEN_PARAM }));

  // Load config from SSM
  const [instanceId, chatId, botToken] = await Promise.all([
    getParam(CONFIG_PREFIX + "instance-id"),
    getParam(CONFIG_PREFIX + "telegram-chat-id"),
    getParam(CONFIG_PREFIX + "telegram-bot-token", true),
  ]);

  // Check if already running
  try {
    const status = await ec2.send(new DescribeInstanceStatusCommand({
      InstanceIds: [instanceId], IncludeAllInstances: true
    }));
    const state = status.InstanceStatuses?.[0]?.InstanceState?.Name;
    if (state === "running") {
      await sendTelegram(botToken, chatId, "🐺 Already running — no action needed.");
      return html("Already Running", "Instance is already up and running!", "✅");
    }
  } catch (e) {
    // Describe failed — proceed with start attempt anyway
  }

  // Alert on Telegram first, then start
  await sendTelegram(botToken, chatId, "🐺 Starting up now — should be ready in about 60 seconds.");

  try {
    await ec2.send(new StartInstancesCommand({ InstanceIds: [instanceId] }));
  } catch (e) {
    if (!e.message?.includes("cannot be started")) throw e;
    // Already starting/running — that's fine
  }

  return html("Waking Up! 🐺", "Instance is starting. Give it about 60 seconds.", "🐺");
};
```

Deploy it:

```bash
cd wake-lambda && zip -j /tmp/wake-lambda.zip index.mjs

aws lambda create-function \
  --function-name loki-wake \
  --runtime nodejs22.x \
  --handler index.handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/loki-wake-lambda-role" \
  --zip-file fileb:///tmp/wake-lambda.zip \
  --timeout 10 \
  --memory-size 128 \
  --architectures arm64 \
  --region $REGION
```

### 2.4 — Create HTTP API Gateway

Lambda Function URLs may be blocked by Organization SCPs. HTTP API Gateway is the reliable alternative ($1/million requests — effectively free for this use case).

```bash
# Create HTTP API
API_ID=$(aws apigatewayv2 create-api \
  --name "loki-wake" \
  --protocol-type HTTP \
  --region $REGION \
  --query 'ApiId' --output text)

# Create Lambda integration
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:loki-wake" \
  --payload-format-version "2.0" \
  --region $REGION \
  --query 'IntegrationId' --output text)

# Create route
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /wake" \
  --target "integrations/$INTEGRATION_ID" \
  --region $REGION

# Create auto-deploy stage
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy \
  --region $REGION

# Grant API Gateway permission to invoke Lambda
aws lambda add-permission \
  --function-name loki-wake \
  --statement-id apigateway-invoke \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region $REGION

# Get the endpoint URL
WAKE_URL=$(aws apigatewayv2 get-api --api-id "$API_ID" --region $REGION --query 'ApiEndpoint' --output text)
echo "Wake URL: ${WAKE_URL}/wake"
```

Save the wake URL — you'll need it for the idle check script.

### 2.5 — Verify

```bash
# Should return "Missing Token" page
curl -s "${WAKE_URL}/wake" | grep -o '<h2>.*</h2>'

# Should return "Invalid Token" page
curl -s "${WAKE_URL}/wake?token=fake" | grep -o '<h2>.*</h2>'
```

---

## Step 3 — Create the Idle Check Script

Save to `~/.openclaw/workspace/loki-idle-check.sh`. **Replace the placeholder values.**

```bash
#!/bin/bash
# loki-idle-check.sh — Standalone idle monitor, runs via systemd timer every 5 min
# No model involved. Checks last user message and shuts down if idle > 1 hour.
# Sends Telegram alert with one-time wake link before shutdown.

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
STATE_FILE="$HOME/.openclaw/workspace/memory/heartbeat-state.json"
SESSIONS_DIR="$HOME/.openclaw/agents/main/sessions"
PYTHON_SCRIPT="$SCRIPT_DIR/idle-check.py"
IDLE_THRESHOLD_HOURS=1.0
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_NUMERIC_CHAT_ID_HERE"
WAKE_LAMBDA_URL="YOUR_API_GATEWAY_URL/wake"

LATEST_TS=$(grep -h '"role":"user"' "$SESSIONS_DIR"/*.jsonl 2>/dev/null | python3 "$PYTHON_SCRIPT" --latest-ts)

if [[ -z "$LATEST_TS" ]]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: No user messages found." >> /tmp/loki-idle-check.log
  exit 1
fi

HOURS_IDLE=$(python3 "$PYTHON_SCRIPT" --hours-idle "$LATEST_TS")

if [[ "$HOURS_IDLE" == "PARSE_ERROR" ]]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: Could not parse timestamp: $LATEST_TS" >> /tmp/loki-idle-check.log
  exit 1
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) idle=${HOURS_IDLE}h last_msg=${LATEST_TS}" >> /tmp/loki-idle-check.log

SHOULD_SHUTDOWN=$(python3 "$PYTHON_SCRIPT" --should-shutdown "$HOURS_IDLE" "$IDLE_THRESHOLD_HOURS")

if [[ "$SHOULD_SHUTDOWN" == "yes" ]]; then
  ALERT_SENT=$(python3 "$PYTHON_SCRIPT" --get-state "$STATE_FILE" idleShutdownAlertSent)

  if [[ "$ALERT_SENT" == "false" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) IDLE >1h — generating wake token + sending Telegram alert" >> /tmp/loki-idle-check.log

    # Generate one-time wake token and store in SSM
    WAKE_TOKEN=$(python3 -c "import uuid; print(uuid.uuid4())")
    aws ssm put-parameter --name "/openclaw/wake-token" --value "$WAKE_TOKEN" --type String --overwrite --region us-east-1 > /dev/null 2>&1

    WAKE_LINK="${WAKE_LAMBDA_URL}?token=${WAKE_TOKEN}"

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🐺 Idle for over an hour. Shutting down in ~5 min to save costs.\n\n👉 Tap to wake me up: ${WAKE_LINK}\",\"disable_web_page_preview\":true}" \
      >> /tmp/loki-idle-check.log 2>&1

    python3 "$PYTHON_SCRIPT" --set-state "$STATE_FILE" idleShutdownAlertSent true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Alert sent with wake link. Will shutdown on next run." >> /tmp/loki-idle-check.log

  else
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Alert already sent — SHUTTING DOWN NOW" >> /tmp/loki-idle-check.log
    sudo shutdown -h now
  fi

else
  # Active — reset alert flag if user came back
  python3 "$PYTHON_SCRIPT" --set-state "$STATE_FILE" idleShutdownAlertSent false
fi
```

---

## Step 4 — Create the Systemd Timer

```bash
sudo tee /etc/systemd/system/loki-idle-check.service << 'EOF'
[Unit]
Description=Loki idle check — shutdown if user is away for over 1 hour

[Service]
Type=oneshot
User=ec2-user
ExecStart=/bin/bash /home/ec2-user/.openclaw/workspace/loki-idle-check.sh
TimeoutSec=30
EOF

sudo tee /etc/systemd/system/loki-idle-check.timer << 'EOF'
[Unit]
Description=Loki idle check timer — every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now loki-idle-check.timer
```

Verify:
```bash
sudo systemctl status loki-idle-check.timer
```

Test immediately:
```bash
sudo systemctl start loki-idle-check.service
cat /tmp/loki-idle-check.log
```

---

## Step 5 — Create Wake IAM User (Optional)

For waking the instance from a CLI (laptop/phone) without the web link:

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
INSTANCE_ID="YOUR_INSTANCE_ID"
REGION="us-east-1"

aws iam create-policy --policy-name loki-wakeup-policy --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Action\": [\"ec2:StartInstances\"],
    \"Resource\": \"arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}\"
  },{
    \"Effect\": \"Allow\",
    \"Action\": \"ec2:DescribeInstances\",
    \"Resource\": \"*\"
  }]
}"

aws iam create-user --user-name loki-wakeup
aws iam attach-user-policy --user-name loki-wakeup \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/loki-wakeup-policy"
aws iam create-access-key --user-name loki-wakeup
# Save the output — use in wake script below
```

Save locally as `wake-loki.sh`:

```bash
#!/bin/bash
AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY \
AWS_SECRET_ACCESS_KEY=YOUR_SECRET_KEY \
AWS_DEFAULT_REGION=us-east-1 \
aws ec2 start-instances --instance-ids YOUR_INSTANCE_ID \
  && echo "✅ Instance is starting up! Give it ~60 seconds."
```

Store credentials in Secrets Manager for future reference:
```bash
aws secretsmanager create-secret \
  --name "openclaw/loki-wakeup-credentials" \
  --secret-string '{"access_key_id":"...","secret_access_key":"...","instance_id":"...","region":"us-east-1"}'
```

---

## Security

**Wake link security layers:**

1. **API Gateway URL** — random subdomain, not guessable or indexed
2. **One-time UUID token** — stored in SSM, deleted after first use. Expired tokens return a friendly error
3. **Lambda scoped permissions** — can only start one specific instance
4. **No hardcoded secrets** — all config (instance ID, Telegram credentials) stored in SSM Parameter Store

**Cost:** Effectively $0/month — Lambda free tier (1M requests) + HTTP API Gateway ($1/million requests) + SSM free tier.

> **Note on Lambda Function URLs:** These are simpler to set up but may be blocked by AWS Organizations SCPs (Service Control Policies). If you get `Forbidden` errors with Function URLs, use HTTP API Gateway instead — that's what this bootstrap uses.

---

## State File

`~/.openclaw/workspace/memory/heartbeat-state.json`:
```json
{
  "idleShutdownAlertSent": false
}
```

---

## Log File

Check `/tmp/loki-idle-check.log` to see every run:
```
2026-04-05T08:06:23Z idle=0.0077h last_msg=2026-04-05T08:05:55.617Z
2026-04-05T09:10:01Z IDLE >1h — generating wake token + sending Telegram alert
2026-04-05T09:10:02Z Alert sent with wake link. Will shutdown on next run.
```

---

## Notes

- The timer is **completely independent of OpenClaw** — if the gateway crashes, idle shutdown still works
- Telegram alert uses **direct Bot API** via `curl` — no OpenClaw dependency
- The two-step shutdown (alert → wait 5min → shutdown) gives the user time to come back or tap the wake link
- Session JSONL path: `~/.openclaw/agents/main/sessions/*.jsonl` — user messages have `"role":"user"`
- Idle threshold is `IDLE_THRESHOLD_HOURS=1.0` — change to any value
- The wake link works even after shutdown — it starts the instance directly via EC2 API
