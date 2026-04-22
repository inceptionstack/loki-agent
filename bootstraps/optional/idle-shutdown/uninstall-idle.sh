#!/usr/bin/env bash
# uninstall-idle.sh — Tear down the idle-shutdown bootstrap.
#
# Safe to run multiple times. Deletes:
#   - systemd units + daemon-reload
#   - on-instance scripts
#   - EventBridge rule + target + lambda permission
#   - API Gateway + lambda permission
#   - Both Lambdas
#   - IAM roles (policies detached first)
#   - SSM parameters (bot-token, chat-id, wake-url, wake-token)
#
# Usage:
#   ./uninstall-idle.sh --region us-east-1 --instance-id i-xxx [--keep-ssm] [--dry-run]
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID=""
KEEP_SSM=false
DRY_RUN=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { printf "${CYAN}[uninstall-idle]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  !${NC} %s\n" "$*"; }
die()  { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)       REGION="$2"; shift 2 ;;
    --instance-id)  INSTANCE_ID="$2"; shift 2 ;;
    --keep-ssm)     KEEP_SSM=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "Unknown argument: $1" ;;
  esac
done

[[ -z "$INSTANCE_ID" ]] && die "--instance-id is required"
command -v aws >/dev/null || die "aws CLI not found"
command -v jq  >/dev/null || die "jq not found"

NOTIFY_LAMBDA="openclaw-idle-notify"
WAKE_LAMBDA="openclaw-idle-wake"
NOTIFY_ROLE="openclaw-idle-notify-role"
WAKE_ROLE="openclaw-idle-wake-role"
API_NAME="openclaw-idle-wake-api"
EVENT_RULE_NAME="openclaw-idle-ec2-state"

SSM_PARAMS=(
  "/openclaw/wake-config/telegram-bot-token"
  "/openclaw/wake-config/telegram-chat-id"
  "/openclaw/wake-config/wake-url"
  "/openclaw/wake-config/instance-id"
  "/openclaw/wake-config/last-stop-event-id"
  "/openclaw/wake-token"
)

try() {
  if $DRY_RUN; then
    printf "  ${YELLOW}DRY${NC} %s\n" "$*"
  else
    eval "$@" || true
  fi
}

ACCT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ---------- 1. Systemd ----------
log "1/6 systemd"
try "systemctl disable --now idle-check.timer 2>/dev/null"
try "rm -f /etc/systemd/system/idle-check.timer /etc/systemd/system/idle-check.service"
try "systemctl daemon-reload"
ok "systemd units removed"

# ---------- 2. On-instance scripts ----------
log "2/6 on-instance scripts"
for u in ec2-user ubuntu "${SUDO_USER:-}" "$(id -un)"; do
  [[ -z "$u" ]] && continue
  try "rm -f /home/${u}/.openclaw/workspace/idle-check.sh /home/${u}/.openclaw/workspace/idle-check.py"
done
ok "scripts removed"

# ---------- 3. EventBridge rule ----------
log "3/6 EventBridge"
if aws events describe-rule --name "$EVENT_RULE_NAME" --region "$REGION" >/dev/null 2>&1; then
  try "aws events remove-targets --rule \"$EVENT_RULE_NAME\" --ids 1 --region \"$REGION\" --output text > /dev/null"
  try "aws events delete-rule --name \"$EVENT_RULE_NAME\" --region \"$REGION\" --output text > /dev/null"
  ok "rule $EVENT_RULE_NAME deleted"
else
  ok "rule $EVENT_RULE_NAME already absent"
fi

# ---------- 4. API Gateway ----------
log "4/6 API Gateway"
API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='$API_NAME'].ApiId" --output text 2>/dev/null | head -1)"
if [[ -n "$API_ID" && "$API_ID" != "None" ]]; then
  try "aws apigatewayv2 delete-api --api-id \"$API_ID\" --region \"$REGION\" --output text > /dev/null"
  ok "API $API_ID deleted"
else
  ok "API $API_NAME already absent"
fi

# ---------- 5. Lambdas ----------
log "5/6 Lambdas"
for fn in "$NOTIFY_LAMBDA" "$WAKE_LAMBDA"; do
  if aws lambda get-function --function-name "$fn" --region "$REGION" >/dev/null 2>&1; then
    try "aws lambda delete-function --function-name \"$fn\" --region \"$REGION\" --output text > /dev/null"
    ok "$fn deleted"
  else
    ok "$fn already absent"
  fi
done

# ---------- 6. IAM roles ----------
log "6/6 IAM roles"
detach_and_delete() {
  local role="$1"
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || { ok "$role already absent"; return; }
  # Inline policies
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
    try "aws iam delete-role-policy --role-name \"$role\" --policy-name \"$p\" --output text > /dev/null"
  done
  # Managed policies
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    try "aws iam detach-role-policy --role-name \"$role\" --policy-arn \"$p\" --output text > /dev/null"
  done
  try "aws iam delete-role --role-name \"$role\" --output text > /dev/null"
  ok "$role deleted"
}
detach_and_delete "$NOTIFY_ROLE"
detach_and_delete "$WAKE_ROLE"

# ---------- SSM ----------
if ! $KEEP_SSM; then
  log "SSM parameters"
  for p in "${SSM_PARAMS[@]}"; do
    if aws ssm get-parameter --name "$p" --region "$REGION" >/dev/null 2>&1; then
      try "aws ssm delete-parameter --name \"$p\" --region \"$REGION\" --output text > /dev/null"
      ok "deleted $p"
    else
      ok "$p already absent"
    fi
  done
else
  warn "Skipping SSM cleanup (--keep-ssm)"
fi

echo
log "${BOLD}Uninstall complete${NC}"
