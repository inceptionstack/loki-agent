# BOOTSTRAP-DAILY-UPDATE.md — Daily AWS Account Digest

> **Applies to:** All agents (with agent-specific sections below)

> **Run this once to set up a daily morning briefing.**
> If `memory/.bootstrapped-daily-update` exists, skip.

## Overview

Sets up a daily cron that sends a consolidated morning briefing to the operator via Telegram covering:
- AWS costs (yesterday + MTD vs last month)
- Security findings (new HIGH/CRITICAL since yesterday)
- Pipeline health (any failures in last 24h)
- EC2/service health
- Any anomalies worth knowing about

## Step 1: Add the Daily Update Cron

```
/cron add "Daily morning briefing" --cron "0 8 * * *" --tz "YOUR_TIMEZONE"
```

Or add it directly via OpenClaw:

```bash
openclaw cron add \
  --name "daily-briefing" \
  --cron "0 8 * * *" \
  --tz "YOUR_TIMEZONE" \
  --session isolated \
  --announce \
  --channel telegram \
  --message "$(cat <<'EOF'
Run the daily AWS account briefing. Be concise — this goes to Telegram so no tables, use bullet lists.

## 1. Costs
- Run: aws ce get-cost-and-usage for yesterday and MTD
- Compare MTD to same period last month
- Flag any service that increased >20% vs last month
- Show top 3 cost drivers this month

## 2. Security (new findings since yesterday)
- GuardDuty: aws guardduty list-findings with HIGH/CRITICAL severity, created in last 24h
- Security Hub: aws securityhub get-findings with CRITICAL/HIGH, last 24h
- Access Analyzer: aws accessanalyzer list-findings for any new ACTIVE findings
- If nothing new: one line saying "No new security findings"

## 3. Pipeline Health
- Check CodePipeline for any FAILED executions in last 24h:
  aws codepipeline list-pipeline-executions for each active pipeline
  Active pipelines: faststart-mission-control-pipeline, solo-mission-control-pipeline, faststart-registry-pipeline, faststart-landing-pipeline
- List any failures with pipeline name and commit message

## 4. EC2 Health
- aws ec2 describe-instance-status for running instances
- Check disk: df -h / and flag if >80%
- Check bedrockify service: systemctl is-active bedrockify

## 5. Format for Telegram
Structure the output as:
☀️ Daily Briefing — [DATE]

💰 Costs: [MTD total] ([+/-X%] vs last month)
• Top drivers: ...

🔒 Security: [X new findings / No new findings]
• [findings if any]

🚀 Pipelines: [all green / X failures]
• [failures if any]

🖥️ EC2: [healthy / issues]

Keep the whole message under 400 words. Link to AWS Console for details rather than dumping everything.
EOF
)"
```

## Step 2: Set Your Timezone

Replace `YOUR_TIMEZONE` with your local timezone so the briefing arrives at a useful time:

```
UTC        → 0 8 * * * (8am UTC)
US/Eastern → use tz="America/New_York"  
US/Pacific → use tz="America/Los_Angeles"
Israel     → use tz="Asia/Jerusalem"
```

## Step 3: Required IAM Permissions

The EC2 instance role needs these for the cost/security checks:

```json
{
  "Effect": "Allow",
  "Action": [
    "ce:GetCostAndUsage",
    "ce:GetCostForecast",
    "guardduty:ListDetectors",
    "guardduty:ListFindings",
    "guardduty:GetFindings",
    "securityhub:GetFindings",
    "accessanalyzer:ListFindings",
    "codepipeline:ListPipelines",
    "codepipeline:ListPipelineExecutions",
    "ec2:DescribeInstanceStatus"
  ],
  "Resource": "*"
}
```

These are all read-only — safe to add broadly.

## Step 4: Verify

Trigger a test run immediately:

```
/cron run daily-briefing
```

Or ask Loki: *"Run the daily briefing now"*

## What Gets Alerted vs Silenced

**Always included (even if nothing to report):** costs, pipeline status
**Only included if findings exist:** security issues, EC2 problems
**Silent (don't wake the operator):** routine low/medium security findings already known

## Pi-Specific Configuration

Pi has no built-in cron system. Use the system crontab to schedule daily briefings, wrapping `pi -p "prompt"` as a one-shot invocation:

```bash
# Add to crontab: crontab -e
0 8 * * * /usr/local/bin/pi -p "Run the daily AWS account briefing. Check costs, security findings, pipeline health, and EC2 status. Format for Telegram (no tables, bullet lists). Keep under 400 words." >> /tmp/pi-daily-briefing.log 2>&1
```

Pi has no built-in Telegram delivery — pipe the output to a script that sends it via the Telegram Bot API, or to another delivery mechanism. Pi is a one-shot CLI tool; it will run the task and exit.

## IronClaw-Specific Configuration

IronClaw has **built-in scheduled routines** — configure daily briefings natively:

```bash
# In ~/.ironclaw/.env or IronClaw's routine config
ROUTINE_DAILY_BRIEFING_SCHEDULE=0 8 * * *
ROUTINE_DAILY_BRIEFING_PROMPT="Run the daily AWS account briefing. Check costs, security findings, pipeline health, and EC2 status. Format for Telegram (no tables, bullet lists). Keep under 400 words."
ROUTINE_DAILY_BRIEFING_CHANNEL=telegram
```

Or via IronClaw's TOML config if supported:

```toml
[[routines]]
name = "daily-briefing"
schedule = "0 8 * * *"
prompt = "Run the daily AWS account briefing..."
channel = "telegram"
```

IronClaw delivers the output via its built-in Telegram channel — no external scripting needed. Refer to IronClaw's documentation for the exact routine config format.

## Finish

```bash
mkdir -p memory && echo "Daily update bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-daily-update
```

---

## OpenClaw-Specific Configuration

The cron setup above uses OpenClaw's built-in `openclaw cron` system. No additional configuration needed — it works out of the box.

## Hermes-Specific Configuration

Hermes supports promoted cron jobs natively. Set up the daily briefing using Hermes's cron system:

```bash
hermes cron add \
  --name "daily-briefing" \
  --schedule "0 8 * * *" \
  --message "Run the daily AWS account briefing. Check costs, security findings, pipeline health, and EC2 status. Format output for Telegram (no tables, use bullet lists). Keep under 400 words."
```

Refer to the Hermes documentation for cron job configuration options.
