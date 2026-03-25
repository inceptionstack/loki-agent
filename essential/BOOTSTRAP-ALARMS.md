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
