#!/bin/bash
# idle-check.sh — Idle monitor (systemd timer, every 5 min)
# Shuts down after 30 min of no real user messages.
# Sends Telegram alert with one-time wake link before shutdown.
#
# Safety:
#   - flock run lock (prevents overlapping runs)
#   - SCAN_ERROR = fail closed (don't stop on scan failures)
#   - Telegram is best-effort (failure doesn't block shutdown)
#   - No sudo shutdown fallback (retry next cycle on IMDS failure)
#   - All secrets fetched from SSM at runtime
#
# Usage:
#   ./idle-check.sh              # normal mode
#   ./idle-check.sh --dry-run    # log what would happen, don't shutdown or alert
set -euo pipefail

# --- Config ---
REGION="us-east-1"
IDLE_THRESHOLD_HOURS=1.0       # 60 minutes (was 0.5 — too aggressive for mid-response)
MIN_UPTIME_HOURS=0.25          # skip shutdown if booted < 15 min ago
MAX_NO_ACTIVITY_HOURS=1.0      # shutdown if no user messages ever after this
LOG_MAX_LINES=500
SSM_TOKEN_PARAM="/openclaw/wake-token"
SSM_BOT_TOKEN_PARAM="/openclaw/wake-config/telegram-bot-token"
SSM_CHAT_ID_PARAM="/openclaw/wake-config/telegram-chat-id"
SSM_WAKE_URL_PARAM="/openclaw/wake-config/wake-url"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
STATE_FILE="$HOME/.openclaw/workspace/memory/heartbeat-state.json"
SESSIONS_DIR="$HOME/.openclaw/agents/main/sessions"
PY="$SCRIPT_DIR/idle-check.py"
# Log lives under $HOME/.openclaw/logs/ so it survives systemd PrivateTmp=yes
# and stays reachable from ordinary user shells (no sudo needed to tail).
LOG_DIR="$HOME/.openclaw/logs"
LOG="$LOG_DIR/idle-check.log"
mkdir -p "$LOG_DIR"

# --- Run lock (prevent overlapping runs) ---
# Lock under $LOG_DIR too — with PrivateTmp=yes each service invocation sees
# a fresh /tmp, so flock(/tmp/idle-check.lock) would never actually overlap.
LOCK_FILE="$LOG_DIR/idle-check.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) SKIP: Another instance is running" >> "$LOG"
  exit 0
fi

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# --- Helpers ---
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

truncate_log() {
  if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > LOG_MAX_LINES )); then
    tail -n "$LOG_MAX_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  fi
}

fetch_ssm() {
  local param="$1"
  local decrypt="${2:-false}"
  if [[ "$decrypt" == "true" ]]; then
    aws ssm get-parameter --name "$param" --region "$REGION" \
      --query Parameter.Value --output text --with-decryption 2>/dev/null
  else
    aws ssm get-parameter --name "$param" --region "$REGION" \
      --query Parameter.Value --output text 2>/dev/null
  fi
}

get_instance_id() {
  local token
  token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' 2>/dev/null) || true
  if [[ -n "$token" ]]; then
    curl -sf -H "X-aws-ec2-metadata-token: $token" \
      http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null
  fi
}

send_telegram() {
  # Pass values via env vars — no shell interpolation into Python source
  local text="$1"
  local tg_token tg_chat
  tg_token=$(fetch_ssm "$SSM_BOT_TOKEN_PARAM" true)
  tg_chat=$(fetch_ssm "$SSM_CHAT_ID_PARAM")

  if [[ -z "$tg_token" || -z "$tg_chat" ]]; then
    log "ERROR: Failed to fetch Telegram credentials from SSM"
    return 1
  fi

  TG_BOT_TOKEN="$tg_token" TG_CHAT_ID="$tg_chat" TG_TEXT="$text" \
    python3 -c '
import json, os, urllib.request
bot_token = os.environ["TG_BOT_TOKEN"]
data = json.dumps({
    "chat_id": os.environ["TG_CHAT_ID"],
    "text": os.environ["TG_TEXT"],
    "disable_web_page_preview": True
}).encode()
url = "https://api.telegram.org/bot" + bot_token + "/sendMessage"
req = urllib.request.Request(
    url,
    data=data,
    headers={"Content-Type": "application/json"}
)
resp = urllib.request.urlopen(req, timeout=10)
if resp.status != 200:
    raise RuntimeError(f"Telegram returned {resp.status}")
' >> "$LOG" 2>&1
}

# --- Main ---
truncate_log

if $DRY_RUN; then log "=== DRY RUN ==="; fi

# Combined idle check (compares parsed datetimes, not strings)
IDLE_RESULT=$(python3 "$PY" --idle-hours "$SESSIONS_DIR")

# SCAN_ERROR = fail closed — do NOT stop the instance on scan failures
if [[ "$IDLE_RESULT" == SCAN_ERROR* ]]; then
  log "ERROR: Session scan failed — ${IDLE_RESULT}"
  log "FAIL CLOSED: Not shutting down on scan error — will retry next cycle"
  exit 0
fi

if [[ "$IDLE_RESULT" == "NO_MESSAGES" ]]; then
  # Bootstrap policy: no user messages ever found
  UPTIME_H=$(python3 "$PY" --uptime-hours)
  EXCEEDED=$(python3 "$PY" --float-gt "$UPTIME_H" "$MAX_NO_ACTIVITY_HOURS")
  if [[ "$EXCEEDED" == "yes" ]]; then
    log "NO ACTIVITY EVER — uptime=${UPTIME_H}h > ${MAX_NO_ACTIVITY_HOURS}h — shutting down"
    if ! $DRY_RUN; then
      INSTANCE_ID=$(get_instance_id)
      if [[ -n "$INSTANCE_ID" ]]; then
        aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
      else
        log "ERROR: Could not determine instance ID — will retry next cycle"
      fi
    fi
  else
    log "No user messages yet — uptime=${UPTIME_H}h < ${MAX_NO_ACTIVITY_HOURS}h — waiting"
  fi
  exit 0
fi

# Parse combined output: "HOURS_IDLE LATEST_TS FILE_FAILURES PARSE_FAILURES"
HOURS_IDLE=$(echo "$IDLE_RESULT" | awk '{print $1}')
LATEST_TS=$(echo "$IDLE_RESULT" | awk '{print $2}')
FILE_FAILURES=$(echo "$IDLE_RESULT" | awk '{print $3}')
PARSE_FAILURES=$(echo "$IDLE_RESULT" | awk '{print $4}')

log "idle=${HOURS_IDLE}h last_msg=${LATEST_TS} file_failures=${FILE_FAILURES} parse_failures=${PARSE_FAILURES}"

SHOULD_SHUTDOWN=$(python3 "$PY" --should-shutdown "$HOURS_IDLE" "$IDLE_THRESHOLD_HOURS")

if [[ "$SHOULD_SHUTDOWN" != "yes" ]]; then
  python3 "$PY" --set-state "$STATE_FILE" idleShutdownAlertSent false
  exit 0
fi

# FAIL CLOSED: if scan was degraded (unreadable files or parse failures),
# don't trust the idle time for shutdown decisions
if [[ "${FILE_FAILURES:-0}" != "0" || "${PARSE_FAILURES:-0}" != "0" ]]; then
  log "FAIL CLOSED: degraded scan (file_failures=${FILE_FAILURES} parse_failures=${PARSE_FAILURES}) — not shutting down"
  exit 0
fi

# Guard: skip if instance just booted (prevents wake → immediate re-shutdown)
UPTIME_H=$(python3 "$PY" --uptime-hours)
TOO_FRESH=$(python3 "$PY" --float-lt "$UPTIME_H" "$MIN_UPTIME_HOURS")
if [[ "$TOO_FRESH" == "yes" ]]; then
  log "SKIP: uptime=${UPTIME_H}h < ${MIN_UPTIME_HOURS}h — recently booted"
  python3 "$PY" --set-state "$STATE_FILE" idleShutdownAlertSent false
  exit 0
fi

ALERT_SENT=$(python3 "$PY" --get-state "$STATE_FILE" idleShutdownAlertSent)

if [[ "$ALERT_SENT" == "false" ]]; then
  log "IDLE >${IDLE_THRESHOLD_HOURS}h — generating wake token"

  if $DRY_RUN; then
    log "DRY RUN: Would generate wake token, store in SSM, send Telegram alert"
    exit 0
  fi

  # Generate and store one-time wake token
  WAKE_TOKEN=$(python3 -c "import uuid; print(uuid.uuid4())")
  if ! aws ssm put-parameter --name "$SSM_TOKEN_PARAM" --value "$WAKE_TOKEN" \
       --type String --overwrite --region "$REGION" > /dev/null 2>&1; then
    log "ERROR: Failed to store wake token in SSM"
    exit 1
  fi

  # Fetch wake URL from SSM (not hardcoded)
  WAKE_URL=$(fetch_ssm "$SSM_WAKE_URL_PARAM")
  if [[ -z "$WAKE_URL" ]]; then
    log "ERROR: Failed to fetch wake URL from SSM"
    exit 1
  fi

  # Set state FIRST — ensures shutdown proceeds on next run even if Telegram fails
  python3 "$PY" --set-state "$STATE_FILE" idleShutdownAlertSent true

  # Telegram is best-effort — failure doesn't block shutdown progression
  WAKE_LINK="${WAKE_URL}?token=${WAKE_TOKEN}"
  if ! send_telegram "🐺 Idle for over ${IDLE_THRESHOLD_HOURS}h. Shutting down in ~5 min to save costs.

👉 Tap to wake me up: ${WAKE_LINK}"; then
    log "WARNING: Telegram alert failed — shutdown will still proceed on next run"
  fi

  log "Alert state set. Will shutdown on next run."

else
  if $DRY_RUN; then
    log "DRY RUN: Would shutdown NOW (alert was already sent)"
    exit 0
  fi

  log "Alert already sent — SHUTTING DOWN NOW"
  INSTANCE_ID=$(get_instance_id)
  if [[ -n "$INSTANCE_ID" ]]; then
    aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
  else
    # No sudo fallback — retry next cycle instead of changing shutdown mechanism
    log "ERROR: Could not determine instance ID — will retry next cycle"
    exit 1
  fi
fi
