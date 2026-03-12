# AWS Secrets Manager Integration for OpenClaw on EC2

This document describes how to configure OpenClaw to fetch secrets from AWS Secrets Manager on an EC2 instance using an exec-based secrets provider.

## Overview

OpenClaw does **not** have a built-in AWS Secrets Manager provider. The only supported secret source types are `env`, `file`, and `exec`. To use AWS Secrets Manager, you must write a small resolver script and register it as an `exec` provider.

## Architecture

```
openclaw gateway
  └─ exec provider spawns → openclaw-aws-secrets (script)
       └─ calls → aws secretsmanager get-secret-value
            └─ authenticates via → EC2 instance role (IMDS)
```

## Prerequisites

- AWS CLI v2 installed and on PATH (`/usr/bin/aws`)
- EC2 instance role with `secretsmanager:GetSecretValue` permission for the relevant secrets
- Python 3 available (used by the resolver script)
- Secrets already created in AWS Secrets Manager (plain string, not key/value)

## Step 1: Create the Resolver Script

Create `/home/ec2-user/.local/bin/openclaw-aws-secrets`:

```python
#!/usr/bin/env python3
"""OpenClaw SecretRef exec resolver for AWS Secrets Manager.

Protocol v1: reads JSON request from stdin, writes JSON response to stdout.
"""
import json
import subprocess
import sys

request = json.load(sys.stdin)
ids = request.get("ids", [])

values = {}
errors = {}

for secret_id in ids:
    try:
        result = subprocess.run(
            [
                "aws", "secretsmanager", "get-secret-value",
                "--secret-id", secret_id,
                "--query", "SecretString",
                "--output", "text",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            values[secret_id] = result.stdout.rstrip("\n")
        else:
            errors[secret_id] = {"message": result.stderr.strip() or f"aws exited with code {result.returncode}"}
    except Exception as e:
        errors[secret_id] = {"message": str(e)}

resp = {"protocolVersion": 1, "values": values}
if errors:
    resp["errors"] = errors
json.dump(resp, sys.stdout)
```

Make it executable:

```bash
chmod +x /home/ec2-user/.local/bin/openclaw-aws-secrets
```

## Step 2: Test the Script Manually

The script speaks a JSON protocol over stdin/stdout. Test it like this:

```bash
echo '{"protocolVersion":1,"provider":"aws-sm","ids":["openclaw/telegram-bot-token"]}' \
  | /home/ec2-user/.local/bin/openclaw-aws-secrets
```

Expected output:

```json
{"protocolVersion": 1, "values": {"openclaw/telegram-bot-token": "<your-secret-value>"}}
```

If this fails, the gateway will also fail. Fix this first before proceeding.

## Step 3: Register the Provider in openclaw.json

Add the provider under `secrets.providers` in `~/.openclaw/openclaw.json`:

```json
{
  "secrets": {
    "providers": {
      "aws-sm": {
        "source": "exec",
        "command": "/home/ec2-user/.local/bin/openclaw-aws-secrets",
        "passEnv": [
          "HOME",
          "PATH",
          "AWS_DEFAULT_REGION"
        ]
      }
    }
  }
}
```

## Step 4: Reference Secrets Using SecretRef

Any credential field that supports SecretRef can now pull from AWS Secrets Manager. Example for a Telegram bot token:

```json
{
  "channels": {
    "telegram": {
      "botToken": {
        "source": "exec",
        "provider": "aws-sm",
        "id": "openclaw/telegram-bot-token"
      }
    }
  }
}
```

The `id` field is passed directly as the `--secret-id` argument to the AWS CLI, so it must match the secret name in AWS Secrets Manager exactly.

## Step 5: Restart the Gateway

```bash
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
  systemctl --user restart openclaw-gateway.service
```

Or foreground test first:

```bash
openclaw gateway run --port 18789
```

---

## Critical Gotchas

### 1. The Exec Provider Uses a JSON Protocol — NOT Command-Line Arguments

This is the single most important thing to know. OpenClaw's exec provider does **not** pass the secret ID as a CLI argument (`$1`). Instead it:

- Sends a JSON request on **stdin**: `{"protocolVersion": 1, "provider": "aws-sm", "ids": ["secret/name"]}`
- Expects a JSON response on **stdout**: `{"protocolVersion": 1, "values": {"secret/name": "the-value"}}`

A simple bash script like `aws secretsmanager get-secret-value --secret-id "$1"` **will silently fail** with exit code 1 because `$1` is empty (no arguments are passed). The error message from OpenClaw (`Exec provider "..." exited with code 1`) gives no indication that the protocol is wrong.

### 2. Do NOT Name Your Provider `"aws"`

The provider name `"aws"` appears to conflict with internal OpenClaw handling. When named `"aws"`, the exec script is never actually invoked (confirmed: debug log files written by the script are never created). Use a different name like `"aws-sm"`, `"aws-secrets"`, or `"secretsmanager"`.

### 3. The `passEnv` Field Controls What the Script Can See

OpenClaw strips the environment before spawning the exec provider. Only variables listed in `passEnv` are forwarded. On EC2 with instance roles, the `aws` CLI gets credentials from IMDS (no env vars needed), but it still needs `PATH` to find the `aws` binary and `HOME` to find `~/.aws/config` if present. `AWS_DEFAULT_REGION` is included in case it's set, but the AWS CLI can auto-detect region from IMDS on EC2.

### 4. The `command` Field Must Be an Absolute Path

Relative paths and bare command names are not accepted. Always use the full path:
```json
"command": "/home/ec2-user/.local/bin/openclaw-aws-secrets"
```

### 5. Secrets Are Resolved Eagerly at Startup

OpenClaw resolves all SecretRefs into an in-memory snapshot at startup. If resolution fails, the gateway **refuses to start** and enters a crash loop. During a hot reload (config change detected while running), a failure is non-fatal only if the gateway already has a cached snapshot — but if the gateway is subsequently restarted, it will fail on startup.

### 6. Config Changes Trigger Hot Reload Which Re-resolves Secrets

Editing `openclaw.json` while the gateway is running triggers a hot reload. If the secrets provider fails at that moment (even transiently), the reload fails. If something then causes a full restart (e.g. `openclaw gateway restart`, or a crash), the gateway can't start because there's no cached snapshot.

### 7. `systemctl --user` Requires DBUS_SESSION_BUS_ADDRESS

When SSH'd into the EC2 instance, `DBUS_SESSION_BUS_ADDRESS` may not be set. Without it, `systemctl --user` and `openclaw gateway install` fail with: `Failed to connect to bus: Permission denied`. Fix:

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
```

Consider adding this to `~/.bashrc`.

---

## Troubleshooting

### "Exec provider exited with code 1" — Gateway Won't Start

1. **Test the script manually** with the JSON protocol (see Step 2 above). If this works, the issue is environmental.
2. **Check the provider name** — if it's `"aws"`, rename it (see Gotcha #2).
3. **Check the script is executable** — `chmod +x` on the script file.
4. **Check the command path** — must be absolute, must exist.
5. **Simulate the restricted environment**: `env -i HOME=/home/ec2-user PATH=/usr/local/bin:/usr/bin:/bin /home/ec2-user/.local/bin/openclaw-aws-secrets <<< '{"protocolVersion":1,"ids":["your/secret"]}'`

### "systemctl --user unavailable: Failed to connect to bus"

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
```

### Gateway Was Working, Then Broke After Config Edit

A config edit triggers hot reload → secrets re-resolution. If that fails and the gateway later restarts, it crash-loops. Check journal logs:

```bash
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" \
  journalctl --user -u openclaw-gateway.service --since "30 min ago" --no-pager | tail -40
```

Look for `[SECRETS_RELOADER_DEGRADED]` entries to find when it first failed.

### Adding Debug Logging to the Resolver Script

Add this near the top of the Python script to log each invocation:

```python
import datetime, os
with open("/tmp/openclaw-aws-secrets-debug.log", "a") as f:
    f.write(f"{datetime.datetime.now()} PID={os.getpid()} request={request}\n")
```

If the log file is never created, OpenClaw is not invoking your script at all (likely a provider name collision — see Gotcha #2).

---

## Storing Secrets in AWS Secrets Manager

Create secrets as plain strings (not key/value JSON):

```bash
aws secretsmanager create-secret \
  --name "openclaw/telegram-bot-token" \
  --secret-string "YOUR_BOT_TOKEN_HERE" \
  --region us-east-1
```

The secret name becomes the `id` in the SecretRef. Use a consistent prefix like `openclaw/` for organization.

---

## EC2 Instance Role Permissions

The instance role needs at minimum:

```json
{
  "Effect": "Allow",
  "Action": "secretsmanager:GetSecretValue",
  "Resource": "arn:aws:secretsmanager:us-east-1:ACCOUNT_ID:secret:openclaw/*"
}
```

---

## Reference: Exec Provider Protocol (v1)

Full protocol docs: https://docs.openclaw.ai/gateway/secrets.md

**Request** (sent to script's stdin):
```json
{
  "protocolVersion": 1,
  "provider": "aws-sm",
  "ids": ["openclaw/telegram-bot-token", "openclaw/another-secret"]
}
```

**Success response** (script writes to stdout):
```json
{
  "protocolVersion": 1,
  "values": {
    "openclaw/telegram-bot-token": "the-token-value",
    "openclaw/another-secret": "another-value"
  }
}
```

**Partial failure response**:
```json
{
  "protocolVersion": 1,
  "values": {
    "openclaw/telegram-bot-token": "the-token-value"
  },
  "errors": {
    "openclaw/another-secret": {"message": "secret not found"}
  }
}
```

Multiple secret IDs can be requested in a single invocation. The script must handle all of them.
