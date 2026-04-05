# BOOTSTRAP-IDLE-SHUTDOWN.md — Idle Shutdown for EC2 Agents

> **Purpose:** Automatically shut down the EC2 instance when the user has been idle for over 1 hour. Sends a Telegram warning before shutdown. Fully independent of the OpenClaw gateway — runs via systemd timer.

---

## How It Works

1. A systemd timer fires every 5 minutes
2. It runs a bash script that reads the OpenClaw session JSONL files to find the last user message timestamp
3. If idle > 1 hour: sends a Telegram alert via Bot API (direct curl, no OpenClaw dependency)
4. On the next run (5 min later), if still idle: `sudo shutdown -h now`
5. State is tracked in `memory/heartbeat-state.json` (`idleShutdownAlertSent` flag)

---

## Prerequisites

- EC2 instance with `sudo` access for `ec2-user`
- OpenClaw installed and configured with Telegram channel
- Telegram bot token and your Telegram chat ID (numeric)
- Python 3 available (`/usr/bin/python3`)

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

## Step 2 — Create the Idle Check Script

Save to `~/.openclaw/workspace/loki-idle-check.sh`. **Replace the bot token and chat ID with your own.**

```bash
#!/bin/bash
# loki-idle-check.sh — Standalone idle monitor, runs via systemd timer every 5 min
# No model involved. Checks last user message and shuts down if idle > 1 hour.
# Sends Telegram alert before shutdown using Bot API directly (no openclaw needed).

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
STATE_FILE="$HOME/.openclaw/workspace/memory/heartbeat-state.json"
SESSIONS_DIR="$HOME/.openclaw/agents/main/sessions"
PYTHON_SCRIPT="$SCRIPT_DIR/idle-check.py"
IDLE_THRESHOLD_HOURS=1.0
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_NUMERIC_CHAT_ID_HERE"

# Get latest user message timestamp
LATEST_TS=$(grep -h '"role":"user"' "$SESSIONS_DIR"/*.jsonl 2>/dev/null | python3 "$PYTHON_SCRIPT" --latest-ts)

if [[ -z "$LATEST_TS" ]]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: No user messages found in session logs." >> /tmp/loki-idle-check.log
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
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) IDLE >1h — sending Telegram alert" >> /tmp/loki-idle-check.log

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"🐺 Loki here — I've been idle for over an hour. Shutting down in ~5 minutes to save costs. Run wake-loki.sh to bring me back.\"}" \
      >> /tmp/loki-idle-check.log 2>&1

    python3 "$PYTHON_SCRIPT" --set-state "$STATE_FILE" idleShutdownAlertSent true
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Alert sent. Will shutdown on next run." >> /tmp/loki-idle-check.log

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

## Step 3 — Create the Systemd Timer

Run as root (or with sudo):

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

Verify it's running:
```bash
sudo systemctl status loki-idle-check.timer
```

Test immediately:
```bash
sudo systemctl start loki-idle-check.service
cat /tmp/loki-idle-check.log
```

---

## Step 4 — Create the Wake Script

Save locally (on your laptop/phone) as `wake-loki.sh`. Needs an IAM user with only `ec2:StartInstances` on the specific instance.

```bash
#!/bin/bash
# wake-loki.sh — Start the Loki EC2 instance
AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY \
AWS_SECRET_ACCESS_KEY=YOUR_SECRET_KEY \
AWS_DEFAULT_REGION=us-east-1 \
aws ec2 start-instances --instance-ids YOUR_INSTANCE_ID \
  && echo "✅ Loki is starting up! Give it ~60 seconds."
```

Create a minimal IAM user for the wake script:
```bash
# Create policy — only allows starting this one instance
aws iam create-policy --policy-name loki-wakeup-policy --policy-document '{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ec2:StartInstances"],
    "Resource": "arn:aws:ec2:REGION:ACCOUNT_ID:instance/INSTANCE_ID"
  },{
    "Effect": "Allow",
    "Action": "ec2:DescribeInstances",
    "Resource": "*"
  }]
}'

aws iam create-user --user-name loki-wakeup
aws iam attach-user-policy --user-name loki-wakeup --policy-arn arn:aws:iam::ACCOUNT_ID:policy/loki-wakeup-policy
aws iam create-access-key --user-name loki-wakeup
# Save the output — bake into wake-loki.sh
```

Store credentials in Secrets Manager for future reference:
```bash
aws secretsmanager create-secret \
  --name "openclaw/loki-wakeup-credentials" \
  --secret-string '{"access_key_id":"...","secret_access_key":"...","instance_id":"...","region":"us-east-1"}'
```

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
2026-04-05T08:06:26Z idle=0.0085h last_msg=2026-04-05T08:05:55.617Z
```

---

## Notes

- The timer is **completely independent of OpenClaw** — if the gateway crashes, idle shutdown still works
- Telegram alert uses **direct Bot API** via `curl` — no openclaw dependency
- The two-step shutdown (alert → wait 5min → shutdown) gives the user time to come back
- Session JSONL path: `~/.openclaw/agents/main/sessions/*.jsonl` — user messages have `"role":"user"`
- Idle threshold is `IDLE_THRESHOLD_HOURS=1.0` — change to any value
