# BOOTSTRAP-DISK-SPACE-STRAT.md — EC2 Disk Space Strategy

> **Assumption: This agent runs on an EC2 instance on AWS.**
> If that's not the case, ignore this file.
>
> If `memory/.bootstrapped-disk-space` exists, skip.

## Overview

EC2 instances that run builds, Docker images, and git clones will fill their root volume unless you actively manage it. The strategy:

- **Root volume** — OS, workspace, OpenClaw runtime only. Keep lean.
- **Secondary EBS data volume** — Docker, `/tmp`, builds, clones. All heavy work goes here.

This keeps the root volume from filling up and avoids costly instance resizes.

---

## Step 1: Check Your Current Disk Situation

```bash
# What volumes do you have?
lsblk

# What's the current usage?
df -h

# What's eating space?
du -sh /* /home/*/ 2>/dev/null | sort -rh | head -20

# Is Docker installed? How much is it using?
docker system df 2>/dev/null
```

Identify:
- Your root device (usually `nvme0n1` on Graviton, `xvda` on x86)
- Whether a secondary data volume exists (if not, create and attach one in the AWS Console or via CLI)
- The biggest space consumers

---

## Step 2: Attach a Secondary EBS Volume (if not already attached)

If you only have a root volume, attach a secondary EBS gp3 volume for data. **Recommended: 80GB gp3** — this agent will accumulate many Docker images over time (base images, build layers, cached intermediate layers) and generate large volumes of temp files from git clones, builds, and npm installs. 80GB gives comfortable headroom for this workload. gp3 costs ~$0.08/GB/month (~$6.40/month for 80GB). Size up if you expect heavy multi-project work.

```bash
# After attaching in AWS Console, find the device
lsblk

# Format if new (replace nvme1n1 with your device)
sudo mkfs -t ext4 /dev/nvme1n1

# Mount it
sudo mkdir -p /mnt/ebs-data
sudo mount /dev/nvme1n1 /mnt/ebs-data

# Make it persistent — get UUID first
sudo blkid /dev/nvme1n1

# Add to /etc/fstab
echo "UUID=YOUR_UUID  /mnt/ebs-data  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
```

---

## Step 3: Move Docker Root to EBS

Docker images are usually the biggest root disk consumer. Move them to the data volume:

```bash
# Stop Docker
sudo systemctl stop docker

# Move Docker data to EBS
sudo mv /var/lib/docker /mnt/ebs-data/docker

# Symlink back so Docker finds it
sudo ln -s /mnt/ebs-data/docker /var/lib/docker

# Restart and verify
sudo systemctl start docker
docker info | grep "Docker Root Dir"
# Expected: Docker Root Dir: /mnt/ebs-data/docker
```

---

## Step 4: Bind-Mount EBS as /tmp

All builds, git clones, and temp files land in `/tmp`. Redirect it to EBS so they never touch the root volume:

```bash
# Create tmp dir on EBS
sudo mkdir -p /mnt/ebs-data/tmp
sudo chmod 1777 /mnt/ebs-data/tmp

# Bind-mount immediately
sudo mount --bind /mnt/ebs-data/tmp /tmp

# Make persistent in fstab
echo "/mnt/ebs-data/tmp  /tmp  none  bind  0  0" | sudo tee -a /etc/fstab
```

---

## Step 5: Set Up a Disk Watchdog

Runaway processes can hold large deleted file handles, filling the disk invisibly. A watchdog catches this:

```bash
sudo tee /usr/local/bin/disk-watchdog.sh > /dev/null << 'WATCHDOG'
#!/bin/bash
# Kill processes holding large deleted file handles when root disk is critically full
THRESHOLD=${DISK_WATCHDOG_THRESHOLD:-90}
USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

if [ "$USAGE" -gt "$THRESHOLD" ]; then
  echo "WARNING: Root disk at ${USAGE}% (threshold: ${THRESHOLD}%) — scanning for large deleted file handles"
  lsof 2>/dev/null | awk '$4~/DEL/ && $7+0 > 1073741824 {print $2}' | sort -u | while read pid; do
    name=$(ps -p $pid -o comm= 2>/dev/null)
    # Never kill critical system or agent processes
    case "$name" in
      systemd|sshd|docker|containerd|ssm-agent|node|openclaw) continue ;;
    esac
    echo "Killing PID $pid ($name) — holding >1GB deleted file handle"
    kill -9 "$pid" 2>/dev/null
  done
fi
WATCHDOG

sudo chmod +x /usr/local/bin/disk-watchdog.sh

sudo tee /etc/systemd/system/disk-watchdog.timer > /dev/null << 'EOF'
[Unit]
Description=Disk watchdog timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

sudo tee /etc/systemd/system/disk-watchdog.service > /dev/null << 'EOF'
[Unit]
Description=Disk watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-watchdog.sh
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now disk-watchdog.timer
```

The threshold defaults to 90% but can be overridden via `DISK_WATCHDOG_THRESHOLD` env var.

---

## Step 6: Set Up Nightly Cleanup Cron

Add via OpenClaw to auto-clean on a schedule:

```
/cron add "Nightly disk cleanup" --schedule "0 3 * * *" --session isolated --message "Run nightly disk cleanup. Log ALL output to memory/disk-cleanup-latest.log (overwrite each run).

At the top of the log, write the timestamp.

Steps:
1. Log df -h / (before)
2. Delete node_modules/ under workspace
3. Delete build artifacts (.next/, dist/, build/, coverage/) under workspace
4. Clean npm/pip/uv cache
5. Delete /tmp files older than 2 days
6. Prune Docker (stopped containers, unused images, dangling volumes, build cache): docker system prune -af --volumes
7. Vacuum journal logs older than 7 days: sudo journalctl --vacuum-time=7d
8. Log df -h / (after)
9. Log summary: space freed, any warnings

Alert the operator on Telegram ONLY if root disk exceeds 75% after cleanup, or if any unexpected directory has grown by more than 2GB."
```

---

## Disk Hygiene Rules (add to AGENTS.md)

```markdown
## Disk Hygiene
- Root volume: OS + workspace only. Secondary EBS: Docker, /tmp, builds.
- Never commit node_modules/ or build artifacts to workspace.
- Prune Docker after builds. Clean /tmp clones when done.
- Nightly cron auto-cleans. Watchdog kills stuck processes if root disk is critically full.
```

---

## Verify

```bash
# All volumes and mounts look correct
df -h

# Docker is on EBS
docker info | grep "Docker Root Dir"

# /tmp points to EBS
mount | grep tmp

# Watchdog is active
systemctl is-active disk-watchdog.timer
```

---

## Finish

```bash
mkdir -p memory && echo "Disk space strategy bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-disk-space
```
