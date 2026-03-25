# BOOTSTRAP-ALARMS.md — Loki Instance Health Monitoring

Alarms to deploy on every EC2 instance running Loki. Designed to catch the failures we've actually seen — network death from crash-loops, Nitro card failures, disk fills, and silent service deaths.

## Prerequisites

- Instance must have `cloudwatch:PutMetricData`, `cloudwatch:PutMetricAlarm`, `ec2:RecoverInstances` permissions
- SNS topic for notifications (create one or pass existing ARN)
- Instance ID and region known at deploy time

## Tier 1 — Instance Survival (auto-recover)

These use built-in EC2/CloudWatch metrics. No agent needed.

### 1.1 System Status Check (Nitro / host failure)

Catches: host network death, underlying hardware failure, Nitro card issues.
**This would have caught the Mar 24 outage ~5 minutes in.**

```
Metric: AWS/EC2 StatusCheckFailed_System
Threshold: >= 1 for 2 consecutive periods (1 min each)
Action: EC2 auto-recover (stop/start, migrates to new host) + SNS notify
```

### 1.2 Instance Status Check (OS crash)

Catches: kernel panic, corrupt filesystem, network config broken inside guest.

```
Metric: AWS/EC2 StatusCheckFailed_Instance
Threshold: >= 1 for 3 consecutive periods (1 min each)
Action: EC2 reboot + SNS notify
```

### 1.3 Root Disk Usage > 85%

Catches: log growth, node_modules sprawl, temp files filling disk.

```
Metric: Custom/Loki DiskUsedPercent (Dimension: MountPath=/)
Threshold: > 85 for 1 period (5 min)
Action: SNS notify (manual intervention — auto-cleanup too risky)
```

### 1.4 Memory Usage > 90%

Catches: memory leaks, runaway processes, OOM risk.

```
Metric: Custom/Loki MemoryUsedPercent
Threshold: > 90 for 2 consecutive periods (5 min each)
Action: SNS notify
```

## Tier 2 — Something Is Wrong (alert, don't page)

### 2.1 CPU Sustained > 80%

Catches: crash-loops (the bedrock-embed-proxy was burning CPU at 22K restarts/boot), stuck processes.

```
Metric: AWS/EC2 CPUUtilization
Threshold: > 80 for 3 consecutive periods (5 min each)
Action: SNS notify
```

### 2.2 Network Out = 0

Catches: network death while kernel stays alive — exactly the Mar 24 failure pattern.
**Early warning before StatusCheckFailed fires.**

```
Metric: AWS/EC2 NetworkPacketsOut
Threshold: <= 0 for 2 consecutive periods (5 min each)
Action: SNS notify
```

### 2.3 EBS Burst Balance Low (if gp2)

Catches: IOPS exhaustion causing I/O stalls. Skip if using gp3 (no burst balance).

```
Metric: AWS/EBS BurstBalance
Threshold: < 20 for 1 period (5 min)
Action: SNS notify
```

## Tier 3 — Service Health (custom metrics)

These require the health-check script (see below) running every 60 seconds via systemd timer.

All metrics published to namespace `Custom/Loki`.

### 3.1 OpenClaw Gateway Alive

```
Metric: Custom/Loki OpenClawAlive
Value: 1 = process running, 0 = not found
Threshold: < 1 for 2 consecutive periods (1 min each)
Action: SNS notify
```

### 3.2 Embedrock Alive (conditional)

Only created if `/usr/local/bin/embedrock` exists on the instance.

```
Metric: Custom/Loki EmbedrockAlive
Value: 1 = systemd active + HTTP 200 on health endpoint, 0 = down
Threshold: < 1 for 2 consecutive periods (1 min each)
Action: SNS notify
```

### 3.3 Systemd Failed Units

Catches: any crash-looping service, not just the ones we know about.
**Would have caught the bedrock-embed-proxy crash-loop immediately.**

```
Metric: Custom/Loki FailedUnits
Value: count of systemd units in failed state
Threshold: > 0 for 1 period (1 min)
Action: SNS notify
```

### 3.4 Bedrock API Reachable

Catches: credential expiry, region issues, service disruptions, model access revoked.

```
Metric: Custom/Loki BedrockReachable
Value: 1 = test InvokeModel succeeds, 0 = fails
Threshold: < 1 for 3 consecutive periods (1 min each)
Action: SNS notify
```

## Tier 4 — Operational Awareness (optional)

These are informational. Create dashboards, not alarms (unless you want noise).

- **Bedrock throttling rate** — ThrottledCount custom metric from SDK error handling
- **EBS data volume usage** (`/mnt/ebs-data`) — same script, extra metric
- **Swap usage** — if > 0 we're in trouble, but usually OOM kills first
- **Journal error rate** — lines/sec to journald, spike = crash-loop

## Health Check Script

Deploy to `/usr/local/bin/loki-health-check.sh`. Runs via systemd timer every 60s.

Pushes all Tier 3 custom metrics in a single `put-metric-data` call (batched).

**What it checks:**
1. `pgrep -f openclaw-gatewa` — OpenClaw gateway process alive
2. `systemctl is-active embedrock` + `curl -sf localhost:8089/` — Embedrock alive + healthy (skip if not installed)
3. `systemctl list-units --failed --no-legend | wc -l` — Failed unit count
4. `df --output=pcent / | tail -1` — Root disk percent
5. `free | awk '/Mem/ {printf "%.0f", $3/$2*100}'` — Memory percent
6. Quick Bedrock `InvokeModel` with tiny payload (1 embedding, cached model) — API reachable

**Batching:** All metrics are collected, then published in one `aws cloudwatch put-metric-data` call with the `--metric-data` JSON array. One API call per run, not six.

**Dimension:** All metrics carry `InstanceId` dimension so alarms are instance-scoped.

## Systemd Timer

```ini
# /etc/systemd/system/loki-health-check.timer
[Unit]
Description=Loki health check metrics

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/loki-health-check.service
[Unit]
Description=Loki health check metrics push

[Service]
Type=oneshot
User=ec2-user
ExecStart=/usr/local/bin/loki-health-check.sh
TimeoutSec=30
```

## CloudWatch Dashboard

Dashboard name: `Loki-Instance-Health`

Provides a single-pane view of all alarms, service health, compute resources, network, and disk I/O. Replace `INSTANCE_ID` and `ACCOUNT_ID` with actual values throughout.

### Layout

| Row | Section | Widgets |
|-----|---------|---------|
| 1 | Header + Alarms | Title bar + all 10 alarm status indicators (green/red at a glance) |
| 2 | Service Health | OpenClaw Gateway (up/down) · Embedrock (up/down) · Bedrock API + Failed Units |
| 3 | Compute | CPU (80% alarm line) · Memory (90% alarm line) · Disk (85% alarm line) |
| 4 | Network & EC2 | Packets in/out · Bytes in/out · System + Instance status checks |
| 5 | Disk I/O | EBS read/write ops · EBS read/write bytes |

### Dashboard JSON

```json
{
  "widgets": [
    {
      "type": "text",
      "x": 0, "y": 0, "width": 24, "height": 1,
      "properties": {
        "markdown": "# ⚡ Loki@FastStart — Instance Health Dashboard\n"
      }
    },
    {
      "type": "alarm",
      "x": 0, "y": 1, "width": 24, "height": 2,
      "properties": {
        "title": "🚨 Alarm Status",
        "alarms": [
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-system-status-check-failed",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-instance-status-check-failed",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-openclaw-down",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-embedrock-down",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-bedrock-unreachable",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-failed-units",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-cpu-high",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-memory-high",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-disk-high",
          "arn:aws:cloudwatch:us-east-1:ACCOUNT_ID:alarm:loki-network-dead"
        ]
      }
    },
    {
      "type": "text",
      "x": 0, "y": 3, "width": 24, "height": 1,
      "properties": { "markdown": "## Service Health" }
    },
    {
      "type": "metric",
      "x": 0, "y": 4, "width": 8, "height": 4,
      "properties": {
        "title": "🤖 OpenClaw Gateway",
        "metrics": [
          [ "Custom/Loki", "OpenClawAlive", "InstanceId", "INSTANCE_ID", { "label": "Gateway Alive", "color": "#2ca02c" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 60, "stat": "Minimum",
        "yAxis": { "left": { "min": 0, "max": 1.2, "label": "1=Up 0=Down" } },
        "annotations": { "horizontal": [{ "label": "DOWN", "value": 0.5, "color": "#d62728", "fill": "below" }] }
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 4, "width": 8, "height": 4,
      "properties": {
        "title": "🪨 Embedrock",
        "metrics": [
          [ "Custom/Loki", "EmbedrockAlive", "InstanceId", "INSTANCE_ID", { "label": "Embedrock Alive", "color": "#1f77b4" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 60, "stat": "Minimum",
        "yAxis": { "left": { "min": 0, "max": 1.2, "label": "1=Up 0=Down" } },
        "annotations": { "horizontal": [{ "label": "DOWN", "value": 0.5, "color": "#d62728", "fill": "below" }] }
      }
    },
    {
      "type": "metric",
      "x": 16, "y": 4, "width": 8, "height": 4,
      "properties": {
        "title": "☁️ Bedrock API & Failed Units",
        "metrics": [
          [ "Custom/Loki", "BedrockReachable", "InstanceId", "INSTANCE_ID", { "label": "Bedrock Reachable", "color": "#ff7f0e" } ],
          [ "Custom/Loki", "FailedUnits", "InstanceId", "INSTANCE_ID", { "label": "Failed Units", "color": "#d62728", "yAxis": "right" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 60, "stat": "Maximum",
        "yAxis": { "left": { "min": 0, "max": 1.2, "label": "1=Up 0=Down" }, "right": { "min": 0, "label": "Failed Count" } }
      }
    },
    {
      "type": "text",
      "x": 0, "y": 8, "width": 24, "height": 1,
      "properties": { "markdown": "## Compute Resources" }
    },
    {
      "type": "metric",
      "x": 0, "y": 9, "width": 8, "height": 5,
      "properties": {
        "title": "🔥 CPU Utilization",
        "metrics": [
          [ "AWS/EC2", "CPUUtilization", "InstanceId", "INSTANCE_ID", { "label": "CPU %", "color": "#9467bd" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 300, "stat": "Average",
        "yAxis": { "left": { "min": 0, "max": 100, "label": "%" } },
        "annotations": { "horizontal": [{ "label": "ALARM", "value": 80, "color": "#d62728" }] }
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 9, "width": 8, "height": 5,
      "properties": {
        "title": "🧠 Memory Usage",
        "metrics": [
          [ "Custom/Loki", "MemoryUsedPercent", "InstanceId", "INSTANCE_ID", { "label": "Memory %", "color": "#e377c2" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 60, "stat": "Maximum",
        "yAxis": { "left": { "min": 0, "max": 100, "label": "%" } },
        "annotations": { "horizontal": [{ "label": "ALARM", "value": 90, "color": "#d62728" }] }
      }
    },
    {
      "type": "metric",
      "x": 16, "y": 9, "width": 8, "height": 5,
      "properties": {
        "title": "💾 Root Disk Usage",
        "metrics": [
          [ "Custom/Loki", "DiskUsedPercent", "InstanceId", "INSTANCE_ID", { "label": "Disk %", "color": "#8c564b" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 60, "stat": "Maximum",
        "yAxis": { "left": { "min": 0, "max": 100, "label": "%" } },
        "annotations": { "horizontal": [{ "label": "ALARM", "value": 85, "color": "#d62728" }] }
      }
    },
    {
      "type": "text",
      "x": 0, "y": 14, "width": 24, "height": 1,
      "properties": { "markdown": "## Network & EC2 Status" }
    },
    {
      "type": "metric",
      "x": 0, "y": 15, "width": 8, "height": 5,
      "properties": {
        "title": "🌐 Network Traffic",
        "metrics": [
          [ "AWS/EC2", "NetworkPacketsIn", "InstanceId", "INSTANCE_ID", { "label": "Packets In", "color": "#2ca02c" } ],
          [ "AWS/EC2", "NetworkPacketsOut", "InstanceId", "INSTANCE_ID", { "label": "Packets Out", "color": "#1f77b4" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 300, "stat": "Sum",
        "yAxis": { "left": { "min": 0, "label": "Packets" } }
      }
    },
    {
      "type": "metric",
      "x": 8, "y": 15, "width": 8, "height": 5,
      "properties": {
        "title": "📊 Network Bytes",
        "metrics": [
          [ "AWS/EC2", "NetworkIn", "InstanceId", "INSTANCE_ID", { "label": "Bytes In", "color": "#2ca02c" } ],
          [ "AWS/EC2", "NetworkOut", "InstanceId", "INSTANCE_ID", { "label": "Bytes Out", "color": "#1f77b4" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 300, "stat": "Sum",
        "yAxis": { "left": { "min": 0, "label": "Bytes" } }
      }
    },
    {
      "type": "metric",
      "x": 16, "y": 15, "width": 8, "height": 5,
      "properties": {
        "title": "✅ EC2 Status Checks",
        "metrics": [
          [ "AWS/EC2", "StatusCheckFailed_System", "InstanceId", "INSTANCE_ID", { "label": "System (Nitro/Host)", "color": "#d62728" } ],
          [ "AWS/EC2", "StatusCheckFailed_Instance", "InstanceId", "INSTANCE_ID", { "label": "Instance (OS)", "color": "#ff7f0e" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 60, "stat": "Maximum",
        "yAxis": { "left": { "min": 0, "max": 1.2, "label": "0=OK 1=FAIL" } }
      }
    },
    {
      "type": "text",
      "x": 0, "y": 20, "width": 24, "height": 1,
      "properties": { "markdown": "## Disk I/O" }
    },
    {
      "type": "metric",
      "x": 0, "y": 21, "width": 12, "height": 4,
      "properties": {
        "title": "📖 EBS Read/Write Ops",
        "metrics": [
          [ "AWS/EC2", "EBSReadOps", "InstanceId", "INSTANCE_ID", { "label": "Read Ops", "color": "#2ca02c" } ],
          [ "AWS/EC2", "EBSWriteOps", "InstanceId", "INSTANCE_ID", { "label": "Write Ops", "color": "#d62728" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 300, "stat": "Sum",
        "yAxis": { "left": { "min": 0, "label": "Ops" } }
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 21, "width": 12, "height": 4,
      "properties": {
        "title": "📝 EBS Read/Write Bytes",
        "metrics": [
          [ "AWS/EC2", "EBSReadBytes", "InstanceId", "INSTANCE_ID", { "label": "Read Bytes", "color": "#2ca02c" } ],
          [ "AWS/EC2", "EBSWriteBytes", "InstanceId", "INSTANCE_ID", { "label": "Write Bytes", "color": "#d62728" } ]
        ],
        "view": "timeSeries", "stacked": false, "region": "us-east-1",
        "period": 300, "stat": "Sum",
        "yAxis": { "left": { "min": 0, "label": "Bytes" } }
      }
    }
  ]
}
```

### Deploy Dashboard

```bash
# Replace placeholders
INSTANCE_ID="i-0229529f514ef6fd7"
ACCOUNT_ID="387904338202"

sed -e "s/INSTANCE_ID/$INSTANCE_ID/g" -e "s/ACCOUNT_ID/$ACCOUNT_ID/g" dashboard.json > /tmp/dashboard-resolved.json

aws cloudwatch put-dashboard \
  --dashboard-name "Loki-Instance-Health" \
  --dashboard-body file:///tmp/dashboard-resolved.json \
  --region us-east-1
```

Dashboard URL: `https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/Loki-Instance-Health`

## Deployment Order

1. **Create SNS topic** (or reuse existing) — need ARN for alarm actions
2. **Deploy Tier 1 alarms** (1.1 + 1.2) — pure CloudWatch, no script needed, highest value
3. **Deploy health check script + timer** — enables Tier 3 metrics
4. **Deploy Tier 2 + Tier 3 alarms** — once custom metrics are flowing
5. **Wire Tier 1.1 auto-recover action** — requires the alarm + EC2 recover permission

## Cost Estimate

- **10 custom metrics** × $0.30/metric/month = ~$3/month
- **~43,200 PutMetricData calls/month** (1/min) = ~$0.43/month (first 1000 free)
- **10 alarms** × $0.10/alarm/month = $1/month
- **SNS** = negligible
- **Total: ~$4.50/month per instance**

## Incident Reference

| Date | Failure | Would Alarm Have Caught It? | Which Alarm? |
|------|---------|----------------------------|--------------|
| 2026-03-24 | bedrock-embed-proxy crash-loop (22K restarts) → network death → instance unreachable for ~16 hours | Yes, within 1 minute | 3.3 FailedUnits, 2.1 CPU, then 1.1 System Status + auto-recover |
| 2026-03-23 | GuardDuty SuspiciousCommand (OpenClaw curl) | No — not an instance health issue | N/A (GuardDuty handles this) |
