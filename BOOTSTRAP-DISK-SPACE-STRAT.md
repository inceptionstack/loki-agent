# BOOTSTRAP-DISK-SPACE-STRAT.md — EBS Data Volume + Disk Hygiene

> **Run this once on a fresh EC2 instance to set up the disk space strategy.**
> If `memory/.bootstrapped-disk-space` exists, skip.

## Overview

The EC2 instance has two volumes:
- **Root disk (40GB)** — OS, workspace, OpenClaw runtime. Keep lean.
- **EBS data volume (80GB gp3)** — Docker, `/tmp`, builds, clones. All heavy work goes here.

The strategy: bind-mount the EBS volume as `/tmp` and move Docker root there so builds, clones, and containers never eat the root disk.

---

## Step 1: Attach and Mount the EBS Volume

Attach an 80GB gp3 EBS volume to the instance in the AWS Console or via CLI, then:

```bash
# Find the device (usually nvme1n1 on Graviton)
lsblk

# Format if new
sudo mkfs -t ext4 /dev/nvme1n1

# Mount it
sudo mkdir -p /mnt/ebs-data
sudo mount /dev/nvme1n1 /mnt/ebs-data

# Get UUID for fstab
sudo blkid /dev/nvme1n1
```

Add to `/etc/fstab` for persistence across reboots:

```bash
# Add EBS data volume
echo "UUID=YOUR_UUID  /mnt/ebs-data  ext4  defaults,nofail  0  2" | sudo tee -a /etc/fstab
```

---

## Step 2: Move Docker Root to EBS

Docker images and containers are the biggest disk consumers. Move them off root:

```bash
# Stop Docker
sudo systemctl stop docker

# Move existing Docker data
sudo mv /var/lib/docker /mnt/ebs-data/docker

# Symlink it back
sudo ln -s /mnt/ebs-data/docker /var/lib/docker

# Restart Docker
sudo systemctl start docker

# Verify
docker info | grep "Docker Root Dir"
# Expected: Docker Root Dir: /mnt/ebs-data/docker
```

---

## Step 3: Bind-Mount EBS as /tmp

All builds, git clones, and temp files go to `/tmp`. Redirect it to EBS:

```bash
# Create tmp dir on EBS
sudo mkdir -p /mnt/ebs-data/tmp
sudo chmod 1777 /mnt/ebs-data/tmp

# Bind-mount (immediate)
sudo mount --bind /mnt/ebs-data/tmp /tmp

# Add to fstab for persistence
echo "/mnt/ebs-data/tmp  /tmp  none  bind  0  0" | sudo tee -a /etc/fstab
```

---

## Step 4: Set Up Disk Watchdog

Prevents runaway processes from filling root disk:

```bash
sudo tee /usr/local/bin/disk-watchdog.sh > /dev/null << 'WATCHDOG'
#!/bin/bash
# Kill processes holding >1GB deleted file handles when root disk >90%
USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$USAGE" -gt 90 ]; then
  echo "WARNING: Root disk at ${USAGE}% — scanning for large deleted file handles"
  # Find processes holding large deleted files
  lsof 2>/dev/null | awk '$4~/DEL/ && $7+0 > 1073741824 {print $2}' | sort -u | while read pid; do
    # Skip critical system processes
    name=$(ps -p $pid -o comm= 2>/dev/null)
    case "$name" in
      systemd|sshd|docker|containerd|ssm-agent|node|openclaw) continue ;;
    esac
    echo "Killing PID $pid ($name) — holding large deleted file"
    kill -9 "$pid" 2>/dev/null
  done
fi
WATCHDOG

sudo chmod +x /usr/local/bin/disk-watchdog.sh

# Run every 30 minutes via systemd timer
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

---

## Step 5: Set Up Nightly Disk Cleanup Cron

Add via OpenClaw to auto-clean on a schedule:

```
/cron add "Nightly disk cleanup" --schedule "0 3 * * *" --session isolated --message "Run nightly disk cleanup:
1. Delete node_modules/ under workspace: find ~/.openclaw/workspace -name node_modules -type d -prune -exec rm -rf {} +
2. Delete build artifacts: .next/, dist/, build/, coverage/ under workspace
3. Clean npm cache: npm cache clean --force
4. Delete /tmp files older than 2 days: find /tmp -maxdepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null
5. Prune Docker: docker system prune -af --volumes 2>/dev/null
6. Clean journal logs: sudo journalctl --vacuum-time=7d
7. Report disk usage: df -h /
Alert Roy on Telegram ONLY if root disk >75% or any directory grew unexpectedly >2GB."
```

---

## Disk Hygiene Rules (add to AGENTS.md)

```markdown
## Disk Hygiene
- Root disk (40GB): OS + workspace only. EBS /mnt/ebs-data (80GB): Docker, /tmp, builds.
- Never keep node_modules/ in workspace. Prune Docker after builds. Clean /tmp clones.
- Nightly cron auto-cleans. Watchdog kills processes if root >90%.
```

---

## Verify

```bash
df -h
# Root disk should be <50% used
# /mnt/ebs-data should show as /tmp too

mount | grep ebs
# Should show: /dev/nvme1n1 on /mnt/ebs-data and /mnt/ebs-data/tmp on /tmp

docker info | grep "Docker Root Dir"
# Should show: /mnt/ebs-data/docker

systemctl is-active disk-watchdog.timer
# Should show: active
```

---

## Finish

```bash
mkdir -p memory && echo "Disk space strategy bootstrapped $(date -u +%Y-%m-%dT%H:%M:%SZ)" > memory/.bootstrapped-disk-space
```
