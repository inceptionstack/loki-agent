#!/usr/bin/env bash
# Loki Agent — One-Shot Installer
# Usage: curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/install.sh -o /tmp/loki-install.sh && bash /tmp/loki-install.sh
# Flags: --yes / -y  Accept all defaults (non-interactive deploy)

# Require bash — printf -v and other bashisms won't work in dash/sh
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash. Run with: bash $0" >&2; exit 1
fi

set -euo pipefail

# Ensure we run from a safe CWD — avoid interference from local .env, direnv, etc.
cd "$HOME" 2>/dev/null || cd /tmp

export AWS_PAGER=""
export PAGER=""
aws() { command aws --no-cli-pager "$@"; }

# Catch unexpected exits so they're not silent; clean up temp clone dir if set
trap '
  echo -e "\n\033[0;31m✗ Installer exited unexpectedly at line $LINENO\033[0m" >&2
  if [[ -n "${CLONE_DIR:-}" && "${CLONE_DIR}" == /tmp/* && -d "$CLONE_DIR" ]]; then
    echo -e "\033[1;33m⚠ Temp clone directory left at: ${CLONE_DIR}\033[0m" >&2
  fi
  if [[ -n "${TF_WORKDIR:-}" && -d "$TF_WORKDIR" ]]; then
    echo -e "\033[1;33m⚠ Temp Terraform workdir left at: ${TF_WORKDIR}\033[0m" >&2
  fi
' ERR

REPO_URL="https://github.com/inceptionstack/loki-agent.git"
DOCS_URL="https://github.com/inceptionstack/loki-agent/wiki"
TEMPLATE_RAW_URL="https://raw.githubusercontent.com/inceptionstack/loki-agent/main/deploy/cloudformation/template.yaml"
SSM_DOC_NAME="Loki-Session"
INSTALLER_VERSION="0.5.21"

# --yes / -y: accept all defaults, minimal prompts
AUTO_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
  esac
done

# Deploy method constants
DEPLOY_CFN_CONSOLE=1
DEPLOY_CFN_CLI=2
DEPLOY_SAM=3
DEPLOY_TERRAFORM=4
# Stamped at release; fall back to git info at runtime
INSTALLER_COMMIT="${INSTALLER_COMMIT:-$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo dev)}"
INSTALLER_DATE="${INSTALLER_DATE:-$(d=$(git -C "$(dirname "$0")" log -1 --format='%ci' 2>/dev/null | cut -d' ' -f1,2); echo "${d:-unknown}")}"

# Detect AWS CloudShell (limited ~1GB home dir, use /tmp for large files)
IS_CLOUDSHELL=false
if [[ -n "${AWS_EXECUTION_ENV:-}" && "${AWS_EXECUTION_ENV}" == *"CloudShell"* ]] || [[ -d /home/cloudshell-user && "$(whoami)" == "cloudshell-user" ]]; then
  IS_CLOUDSHELL=true
fi

# ============================================================================
# UI helpers
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

prompt() {
  local text="$1" var="$2" default="${3:-}"
  if [[ "$AUTO_YES" == true && -n "$default" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local display="$text"; [[ -n "$default" ]] && display="$text [$default]"
  read -rp "$(echo -e "${BOLD}${display}:${NC} ")" value
  printf -v "$var" '%s' "${value:-$default}"
}

confirm() {
  local text="$1" default="${2:-default_no}"
  if [[ "$AUTO_YES" == true ]]; then return 0; fi
  local hint="[y/N]"; [[ "$default" == "default_yes" ]] && hint="[Y/n]"
  read -rp "$(echo -e "${BOLD}${text} ${hint}:${NC} ")" answer
  case "$default" in
    default_yes) [[ ! "$answer" =~ ^[Nn]$ ]] ;;
    *)           [[ "$answer" =~ ^[Yy]$ ]] ;;
  esac
}

toggle() {
  local text="$1" var="$2" default="${3:-true}"
  if [[ "$AUTO_YES" == true ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local hint="[Y/n]"; [[ "$default" == "false" ]] && hint="[y/N]"
  read -rp "$(echo -e "    ${text} ${hint}: ")" answer
  case "$default" in
    true)  [[ "$answer" =~ ^[Nn]$ ]] && printf -v "$var" '%s' "false" || printf -v "$var" '%s' "true" ;;
    false) [[ "$answer" =~ ^[Yy]$ ]] && printf -v "$var" '%s' "true"  || printf -v "$var" '%s' "false" ;;
  esac
}

require_cmd() { command -v "$1" &>/dev/null || fail "$2"; }

# Confirm or exit cleanly
confirm_or_abort() { confirm "$@" || { echo "Aborted."; exit 0; }; }

# Extract a key from JSON on stdin
json_field() { jq -r ".$1" 2>/dev/null; }

# URL-encode a string
url_encode() { jq -rn --arg s "$1" '$s | @uri'; }

# Verify AWS credentials with specific error messages.
# On success, sets ACCOUNT_ID and CALLER_ARN from a single STS call.
verify_aws_credentials() {
  local sts_output sts_rc=0
  sts_output=$(aws sts get-caller-identity --output json 2>&1) || sts_rc=$?
  if [[ $sts_rc -ne 0 ]]; then
    warn "aws sts get-caller-identity failed:"
    warn "$sts_output"
    if aws configure list 2>/dev/null | grep -q '<not set>'; then
      fail "AWS credentials not configured. Run 'aws configure' first."
    else
      fail "AWS credentials are configured (profile: ${AWS_PROFILE:-default}) but authentication failed. Refresh your session or check your credential process."
    fi
  fi
  # Extract account and ARN from the single STS response
  ACCOUNT_ID=$(echo "$sts_output" | json_field Account) \
    || fail "Could not determine AWS account ID"
  CALLER_ARN=$(echo "$sts_output" | json_field Arn) \
    || fail "Could not determine caller ARN"
}

# ============================================================================
# Reusable AWS helpers
# ============================================================================

# Create a private S3 bucket with versioning + KMS encryption
create_s3_bucket() {
  local bucket="$1" region="$2"
  if aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    ok "Bucket exists: ${bucket}"; return 0
  fi
  info "Creating bucket: ${bucket}"
  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
  else
    aws s3api create-bucket --bucket "$bucket" --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled --region "$region"
  aws s3api put-bucket-encryption --bucket "$bucket" --region "$region" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
  aws s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  ok "Bucket created: ${bucket}"
}

# Try to open a URL in the default browser
open_url() {
  local url="$1"
  for cmd in open xdg-open start; do
    command -v "$cmd" &>/dev/null && "$cmd" "$url" 2>/dev/null && return 0
  done
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v explorer.exe &>/dev/null \
    && explorer.exe "$url" 2>/dev/null && return 0
  return 1
}

# Run a command, capture output; on failure show full log and exit.
# Sets _RUN_LOG to the temp file path so caller can grep it.
run_or_fail() {
  local label="$1"; shift
  _RUN_LOG=$(mktemp)
  set +e; "$@" > "$_RUN_LOG" 2>&1; local rc=$?; set -e
  if [[ $rc -ne 0 ]]; then
    echo ""; warn "${label} failed:"; cat "$_RUN_LOG"; rm -f "$_RUN_LOG"
    fail "${label} exited with code $rc"
  fi
}

# Build the SSM connect command for a given instance (or placeholder)
ssm_connect_cmd() {
  local target="${1:-\$INSTANCE_ID}"
  local cmd="aws ssm start-session --target ${target}"
  if aws ssm describe-document --name "$SSM_DOC_NAME" --region "$DEPLOY_REGION" &>/dev/null 2>&1; then
    cmd+=" --document-name ${SSM_DOC_NAME}"
  fi
  cmd+=" --region ${DEPLOY_REGION}"
  echo "$cmd"
}

# ============================================================================
# Phase: Banner
# ============================================================================
show_banner() {
  # Resolve commit/date from git if running from a clone, otherwise use stamped values
  local commit="$INSTALLER_COMMIT" date="$INSTALLER_DATE"
  if [[ "$commit" == "dev" ]] && command -v git &>/dev/null; then
    local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    if [[ -d "$script_dir/.git" ]]; then
      commit=$(git -C "$script_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      date=$(git -C "$script_dir" log -1 --format='%ci' 2>/dev/null | cut -d: -f1,2 || echo "unknown")
    fi
  fi
  local version_line="v${INSTALLER_VERSION} · ${commit} · ${date}"

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       🤖 Loki Agent — AWS Installer         ║${NC}"
  printf "${BOLD}║${NC}  %-42s${BOLD}║${NC}\n" "$version_line"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
  if [[ "$AUTO_YES" == true ]]; then
    echo ""
    info "Running in auto mode (--yes) — using defaults, minimal prompts"
  fi
  echo ""
}

# ============================================================================
# Phase: Pre-flight checks
# ============================================================================
preflight_checks() {
  info "Running pre-flight checks..."

  require_cmd aws "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  ok "AWS CLI: $(aws --version 2>&1 | head -1)"

  require_cmd jq "jq is required but not found. Install: https://jqlang.github.io/jq/download/"

  verify_aws_credentials
  # ACCOUNT_ID and CALLER_ARN are now set by verify_aws_credentials (single STS call)
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

  ok "Identity: ${CALLER_ARN}"
  echo ""
  echo -e "  ${BOLD}Account:${NC}  ${ACCOUNT_ID}"
  echo -e "  ${BOLD}Region:${NC}   ${REGION}"
  echo ""
  warn "Loki will get AdministratorAccess on this ENTIRE account."
  warn "Use a dedicated sandbox account — never deploy in production."
  echo ""
  confirm_or_abort "Deploy to account ${ACCOUNT_ID} in ${REGION}?" "default_yes"

  check_permissions
  check_existing_deployments
}

check_vpc_quota() {
  local check_region="${DEPLOY_REGION:-$REGION}"
  echo ""
  info "Checking VPC quota in ${check_region}..."
  local vpc_count vpc_limit
  vpc_count=$(aws ec2 describe-vpcs --region "$check_region" \
    --query 'length(Vpcs)' --output text 2>/dev/null || echo "0")
  vpc_limit=$(aws service-quotas get-service-quota \
    --service-code vpc --quota-code L-F678F1CE --region "$check_region" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "5")
  # Truncate decimals (quota API returns 5.0) and validate numeric
  vpc_limit=${vpc_limit%%.*}
  [[ "$vpc_count" =~ ^[0-9]+$ ]] || vpc_count=0
  [[ "$vpc_limit" =~ ^[0-9]+$ ]] || vpc_limit=5

  local remaining=$((vpc_limit - vpc_count))
  if [[ $remaining -le 0 ]]; then
    echo ""
    echo -e "  ${RED}VPC quota reached: ${vpc_count}/${vpc_limit} VPCs in ${check_region}${NC}"
    echo "  Loki needs 1 VPC. You have none remaining."
    echo ""
    if confirm "Request a VPC quota increase (+5) now?" "default_yes"; then
      local request_id
      request_id=$(aws service-quotas request-service-quota-increase \
        --service-code vpc --quota-code L-F678F1CE \
        --desired-value $((vpc_limit + 5)) --region "$check_region" \
        --query 'RequestedQuota.Id' --output text 2>/dev/null || echo "")
      if [[ -n "$request_id" ]]; then
        ok "Quota increase requested (id: ${request_id})"
        info "New limit: $((vpc_limit + 5)) VPCs — usually approved within minutes"
        info "Check status: https://${check_region}.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE"
        echo ""
        confirm_or_abort "Continue with deployment (quota increase pending)?" "default_yes"
      else
        warn "Could not request quota increase automatically"
        echo "  Request manually: https://${check_region}.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE"
        confirm_or_abort "Continue anyway (deploy will likely fail)?"
      fi
    else
      confirm_or_abort "Continue anyway (deploy will likely fail)?"
    fi
  elif [[ $remaining -le 1 ]]; then
    warn "VPC quota is tight: ${vpc_count}/${vpc_limit} VPCs in ${check_region} (${remaining} remaining)"
    echo "  Loki needs 1 VPC."
    if confirm "Request a quota increase (+5) as a precaution?" ; then
      aws service-quotas request-service-quota-increase \
        --service-code vpc --quota-code L-F678F1CE \
        --desired-value $((vpc_limit + 5)) --region "$check_region" >/dev/null 2>&1 \
        && ok "Quota increase requested (+5)" \
        || warn "Could not request quota increase (non-fatal)"
    fi
  else
    ok "VPC quota: ${vpc_count}/${vpc_limit} used (${remaining} remaining)"
  fi
}

check_permissions() {
  echo ""
  info "Checking permissions..."
  if aws iam simulate-principal-policy \
    --policy-source-arn "$CALLER_ARN" \
    --action-names "cloudformation:CreateStack" "iam:CreateRole" "ec2:CreateVpc" \
    --query 'EvaluationResults[?EvalDecision!=`allowed`].EvalActionName' \
    --output text 2>/dev/null | grep -q "."; then
    warn "Some permissions may be missing."
    confirm_or_abort "Continue anyway?"
  else
    ok "Permissions verified"
  fi
}

check_existing_deployments() {
  echo ""
  info "Checking for existing Loki deployments..."
  local vpcs
  vpcs=$(aws ec2 describe-vpcs \
    --filters "Name=tag:loki:managed,Values=true" \
    --region "$REGION" \
    --query 'Vpcs[*].[VpcId, Tags[?Key==`loki:watermark`].Value|[0], Tags[?Key==`loki:deploy-method`].Value|[0], Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$vpcs" ]]; then
    local count; count=$(echo "$vpcs" | wc -l | tr -d ' ')
    warn "Found ${count} existing Loki deployment(s) in this account/region:"
    echo ""
    local -a vpc_ids=()
    while IFS=$'\t' read -r vpc_id watermark method name; do
      echo -e "    ${BOLD}${vpc_id}${NC}  watermark=${watermark:-n/a}  method=${method:-n/a}  name=${name:-n/a}"
      vpc_ids+=("$vpc_id")
    done <<< "$vpcs"
    echo ""

    # Offer to reuse an existing VPC instead of creating a new one
    local reuse_vpc=true
    if [[ "$AUTO_YES" == true ]]; then
      info "Auto mode: reusing first existing VPC"
    else
      if ! confirm "Reuse an existing VPC?" "default_yes"; then
        reuse_vpc=false
      fi
    fi

    if [[ "$reuse_vpc" == true ]]; then
      local chosen_vpc
      if [[ ${#vpc_ids[@]} -eq 1 || "$AUTO_YES" == true ]]; then
        chosen_vpc="${vpc_ids[0]}"
        info "Using VPC: ${chosen_vpc}"
      else
        echo ""
        echo "  Select a VPC to reuse:"
        local i
        for i in "${!vpc_ids[@]}"; do
          echo "    $((i+1))) ${vpc_ids[$i]}"
        done
        echo ""
        local vpc_choice
        prompt "VPC number" vpc_choice "1"
        vpc_choice="${vpc_choice//[^0-9]/}"
        [[ -z "$vpc_choice" ]] && vpc_choice=1
        local vpc_idx=$(( vpc_choice - 1 ))
        [[ $vpc_idx -lt 0 || $vpc_idx -ge ${#vpc_ids[@]} ]] && vpc_idx=0
        chosen_vpc="${vpc_ids[$vpc_idx]}"
        info "Selected VPC: ${chosen_vpc}"
      fi

      EXISTING_VPC_ID="$chosen_vpc"

      # Find the public subnet in the chosen VPC
      local subnet_id
      subnet_id=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${chosen_vpc}" "Name=tag:Name,Values=*public*" \
        --query 'Subnets[0].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "None")
      if [[ "$subnet_id" == "None" || -z "$subnet_id" ]]; then
        subnet_id=$(aws ec2 describe-subnets \
          --filters "Name=vpc-id,Values=${chosen_vpc}" "Name=mapPublicIpOnLaunch,Values=true" \
          --query 'Subnets[0].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
      fi

      if [[ -n "$subnet_id" && "$subnet_id" != "None" ]]; then
        EXISTING_SUBNET_ID="$subnet_id"
        ok "Reusing VPC: ${EXISTING_VPC_ID}  subnet: ${EXISTING_SUBNET_ID}"
      else
        warn "Could not find a public subnet in ${chosen_vpc} — creating new VPC instead"
        EXISTING_VPC_ID=""
        EXISTING_SUBNET_ID=""
      fi
    else
      # User declined reuse — proceed with a new VPC
      confirm_or_abort "Continue with a new deployment (new VPC)?"
    fi
  else
    ok "No existing Loki deployments found"
  fi
}

# ============================================================================
# Phase: Collect configuration
# ============================================================================
# Helper: get a human-readable terraform version string
terraform_version_string() {
  terraform version -json 2>/dev/null \
    | json_field terraform_version 2>/dev/null \
    || terraform version | head -1
}

choose_deploy_method() {
  echo ""
  echo "  Deployment methods:"
  echo ""
  echo "    1) CloudFormation Console -- opens browser wizard to review & launch"
  echo "    2) CloudFormation CLI     -- deploy from terminal"
  echo "    3) SAM                    -- for SAM CLI users"
  echo -e "    ${GREEN}4) Terraform${NC}              -- for Terraform shops (auto-installs if needed)"
  echo ""
  prompt "Deployment method" DEPLOY_METHOD "$DEPLOY_TERRAFORM"
  DEPLOY_METHOD=$(echo "$DEPLOY_METHOD" | tr -d '[:space:]')

  # If Terraform selected and not installed, handle it now — before config questions.
  # This avoids the user filling out all config only to be blocked at deploy time.
  if [[ "$DEPLOY_METHOD" == "$DEPLOY_TERRAFORM" ]]; then
    if ! command -v terraform &>/dev/null; then
      echo ""
      warn "Terraform is not installed on this system."
      echo ""
      echo "  Loki can install Terraform locally now (no root/sudo required)."
      echo "  This works in AWS CloudShell, EC2, macOS, and most Linux environments."
      echo ""
      if confirm "Install Terraform locally before continuing?" "default_yes"; then
        install_terraform
      else
        echo ""
        echo "  Install it manually, then re-run this installer:"
        echo "    https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli"
        echo ""
        fail "Terraform is required for the Terraform deployment method."
      fi
    else
      ok "Terraform: $(terraform_version_string)"
    fi
  fi
}

collect_config() {
  echo ""
  info "Configuration"
  echo ""

  # ---- Pack selection (dynamically discovered from registry.json) -----------
  # CLONE_DIR may not be set yet (repo is cloned after config collection).
  # If the local file isn't available, fetch from GitHub.
  local registry="${CLONE_DIR:-}/packs/registry.json"
  if [[ ! -f "$registry" ]]; then
    local registry_url="https://raw.githubusercontent.com/inceptionstack/loki-agent/main/packs/registry.json"
    registry="/tmp/loki-registry-$$.json"
    curl -sfL "$registry_url" -o "$registry" 2>/dev/null || registry=""
  fi
  local -a pack_names=()
  local -a pack_descs=()
  local -a pack_experimental=()

  # Parse agent packs from registry.json via jq
  while IFS='|' read -r pname pdesc pexp; do
    pack_names+=("$pname")
    pack_descs+=("$pdesc")
    pack_experimental+=("$pexp")
  done < <([ -n "$registry" ] && jq -r '
    .packs | to_entries[]
    | select(.value.type == "agent")
    | "\(.key)|\(.value.description // .key)|\(if .value.experimental then "true" else "false" end)"
  ' "$registry" 2>/dev/null \
    || echo "openclaw|OpenClaw -- stateful AI agent with persistent gateway|false")

  echo "  Agent to deploy:"
  local i
  for i in "${!pack_names[@]}"; do
    local num=$((i + 1))
    local tag=""
    [[ "${pack_experimental[$i]}" == "true" ]] && tag=" ${YELLOW}(experimental)${NC}"
    local rec=""
    [[ "${pack_names[$i]}" == "openclaw" ]] && rec=" ${GREEN}(recommended)${NC}"
    echo -e "    ${num}) ${BOLD}${pack_names[$i]}${NC}  -- ${pack_descs[$i]}${rec}${tag}"
  done
  echo ""
  local pack_choice
  prompt "Deploy which agent" pack_choice "1"
  # Sanitize: strip non-digits, default to 1
  pack_choice="${pack_choice//[^0-9]/}"
  [[ -z "$pack_choice" ]] && pack_choice=1
  local idx=$(( pack_choice - 1 ))
  if [[ $idx -lt 0 || $idx -ge ${#pack_names[@]} ]]; then
    idx=0  # default to first (openclaw)
  fi
  PACK_NAME="${pack_names[$idx]}"
  if [[ "${pack_experimental[$idx]}" == "true" ]]; then
    warn "${PACK_NAME} is experimental — expect rough edges"
  fi
  ok "Selected pack: ${PACK_NAME}"

  # Count existing deployments to generate a smart default env name
  local existing_count
  existing_count=$(aws ec2 describe-vpcs \
    --filters "Name=tag:loki:managed,Values=true" \
    --region "$REGION" \
    --query 'length(Vpcs)' --output text 2>/dev/null || echo "0")
  local default_env_name="${PACK_NAME}-$((existing_count + 1))"

  echo ""
  prompt "Environment name (lowercase, resource prefix)" ENV_NAME "$default_env_name"
  ENV_NAME=$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
  prompt "Loki watermark (tag to identify this deployment)" LOKI_WATERMARK "$ENV_NAME"

  # Adjust instance size default based on pack registry
  local default_size_choice="3"  # default → t4g.xlarge
  local pack_instance_type
  pack_instance_type=$([ -n "$registry" ] && jq -r --arg p "$PACK_NAME" '.packs[$p].instance_type // "t4g.xlarge"' "$registry" 2>/dev/null || echo "t4g.xlarge")
  case "$pack_instance_type" in
    t4g.medium)  default_size_choice="1"; info "${PACK_NAME} is lightweight — defaulting to t4g.medium" ;;
    t4g.large)   default_size_choice="2" ;;
    *)           default_size_choice="3" ;;
  esac
  echo ""
  echo "  Instance sizes:"
  echo "    1) t4g.medium  -- 2 vCPU, 4GB  (~\$25/mo)  light use"
  echo "    2) t4g.large   -- 2 vCPU, 8GB  (~\$50/mo)  regular use"
  echo "    3) t4g.xlarge  -- 4 vCPU, 16GB (~\$100/mo) recommended"
  echo ""
  local choice
  prompt "Instance size" choice "$default_size_choice"
  case "$choice" in
    1) INSTANCE_TYPE="t4g.medium" ;;
    2) INSTANCE_TYPE="t4g.large" ;;
    *) INSTANCE_TYPE="t4g.xlarge" ;;
  esac

  prompt "AWS region" DEPLOY_REGION "$REGION"
  collect_security_config
}

collect_security_config() {
  echo ""
  echo -e "  ${BOLD}Security services${NC} (~\$5/mo total, individually toggleable):"
  echo ""

  if confirm "Enable all security services?" "default_yes"; then
    SECURITY_HUB="true"; GUARDDUTY="true"; INSPECTOR="true"
    ACCESS_ANALYZER="true"; CONFIG_RECORDER="true"
    ok "All security services enabled"
    return
  fi

  echo ""
  echo -e "  Pick which to enable:"
  echo ""
  toggle "AWS Security Hub"    SECURITY_HUB    true
  toggle "Amazon GuardDuty"    GUARDDUTY       true
  toggle "Amazon Inspector"    INSPECTOR       true
  toggle "IAM Access Analyzer" ACCESS_ANALYZER true
  toggle "AWS Config Recorder" CONFIG_RECORDER true

  echo ""
  local enabled=""
  [[ "$SECURITY_HUB"    == "true" ]] && enabled+=" SecurityHub"
  [[ "$GUARDDUTY"        == "true" ]] && enabled+=" GuardDuty"
  [[ "$INSPECTOR"        == "true" ]] && enabled+=" Inspector"
  [[ "$ACCESS_ANALYZER"  == "true" ]] && enabled+=" AccessAnalyzer"
  [[ "$CONFIG_RECORDER"  == "true" ]] && enabled+=" Config"
  if [[ -n "$enabled" ]]; then ok "Enabled:${enabled}"; else warn "All security services disabled"; fi
}

# ============================================================================
# Parameter source-of-truth: single mapping for CFN Console, CFN CLI, Terraform
# ============================================================================
# ⚠ KEEP THESE THREE ARRAYS IN SYNC — same order, same count
PARAM_CFN_NAMES=(EnvironmentName PackName InstanceType ModelMode BedrockRegion LokiWatermark EnableSecurityHub EnableGuardDuty EnableInspector EnableAccessAnalyzer EnableConfigRecorder ExistingVpcId ExistingSubnetId)
PARAM_TF_NAMES=(environment_name pack_name instance_type model_mode bedrock_region loki_watermark enable_security_hub enable_guardduty enable_inspector enable_access_analyzer enable_config_recorder existing_vpc_id existing_subnet_id)
PARAM_VALUES=()  # populated by build_deploy_params()

# Populate PARAM_VALUES from user config (call after collect_config)
build_deploy_params() {
  PARAM_VALUES=(
    "$ENV_NAME"
    "$PACK_NAME"
    "$INSTANCE_TYPE"
    "bedrock"
    "$DEPLOY_REGION"
    "$LOKI_WATERMARK"
    "$SECURITY_HUB"
    "$GUARDDUTY"
    "$INSPECTOR"
    "$ACCESS_ANALYZER"
    "$CONFIG_RECORDER"
    "${EXISTING_VPC_ID:-}"
    "${EXISTING_SUBNET_ID:-}"
  )
  # Validate parallel arrays are in sync
  [[ ${#PARAM_CFN_NAMES[@]} -eq ${#PARAM_VALUES[@]} ]] \
    || fail "BUG: PARAM_CFN_NAMES has ${#PARAM_CFN_NAMES[@]} entries but PARAM_VALUES has ${#PARAM_VALUES[@]}"
  [[ ${#PARAM_TF_NAMES[@]} -eq ${#PARAM_VALUES[@]} ]] \
    || fail "BUG: PARAM_TF_NAMES has ${#PARAM_TF_NAMES[@]} entries but PARAM_VALUES has ${#PARAM_VALUES[@]}"
}

# Format params as CFN Console URL query string (param_Key=Value), URL-encoded
format_console_params() {
  local params=""
  for i in "${!PARAM_CFN_NAMES[@]}"; do
    local encoded_val
    encoded_val=$(url_encode "${PARAM_VALUES[$i]}")
    params+="&param_${PARAM_CFN_NAMES[$i]}=${encoded_val}"
  done
  echo "$params"
}

# Format params as CFN CLI --parameters (ParameterKey=X,ParameterValue=Y)
format_cfn_cli_params() {
  local params=""
  for i in "${!PARAM_CFN_NAMES[@]}"; do
    [[ -n "$params" ]] && params+=" "
    params+="ParameterKey=${PARAM_CFN_NAMES[$i]},ParameterValue=${PARAM_VALUES[$i]}"
  done
  echo "$params"
}

# Format params as Terraform -var arguments
format_tf_vars() {
  local vars=()
  for i in "${!PARAM_TF_NAMES[@]}"; do
    vars+=(-var="${PARAM_TF_NAMES[$i]}=${PARAM_VALUES[$i]}")
  done
  printf '%s\n' "${vars[@]}"
}

show_summary() {
  echo ""
  echo -e "  ${BOLD}╭─────────────── Deploy Summary ───────────────╮${NC}"
  echo -e "  ${BOLD}│${NC}  Environment:  ${ENV_NAME}"
  echo -e "  ${BOLD}│${NC}  Pack:         ${PACK_NAME}"
  echo -e "  ${BOLD}│${NC}  Instance:     ${INSTANCE_TYPE}"
  echo -e "  ${BOLD}│${NC}  Region:       ${DEPLOY_REGION}"
  echo -e "  ${BOLD}│${NC}  Watermark:    ${LOKI_WATERMARK}"
  if [[ -n "${EXISTING_VPC_ID:-}" ]]; then
    echo -e "  ${BOLD}│${NC}  VPC:          reuse ${EXISTING_VPC_ID} (existing)"
  fi
  echo -e "  ${BOLD}│${NC}  SecurityHub:  ${SECURITY_HUB}  GuardDuty: ${GUARDDUTY}"
  echo -e "  ${BOLD}│${NC}  Inspector:    ${INSPECTOR}  Analyzer:  ${ACCESS_ANALYZER}"
  echo -e "  ${BOLD}│${NC}  Config:       ${CONFIG_RECORDER}"
  echo -e "  ${BOLD}╰───────────────────────────────────────────────╯${NC}"
  echo ""
  confirm_or_abort "Proceed with deployment?" "default_yes"
}

# ============================================================================
# Phase: Clone / prepare repo (CLI deploys only)
# ============================================================================
prepare_repo() {
  echo ""
  local current; current=$(pwd)

  if [[ "$AUTO_YES" == true ]]; then
    # Auto mode: pick ~/.loki-agent (persistent, safe default)
    CLONE_DIR="$HOME/.loki-agent"
    mkdir -p "$(dirname "$CLONE_DIR")"
    info "Clone destination: ${CLONE_DIR} (auto)"
  else
  echo "  Clone destination:"
  echo "    1) Current directory -- ${current}/loki-agent"
  echo "    2) ~/.loki-agent     -- persistent home directory"
  echo "    3) Temp directory    -- auto-deleted when done (not for Terraform local state)"
  echo ""
  # CloudShell: default to /tmp (home is tiny)
  local default_choice="1"
  if [[ "$IS_CLOUDSHELL" == "true" ]]; then
    warn "CloudShell detected — /home has limited space (~1GB)"
    info "Defaulting to /tmp for the clone"
    default_choice="3"
  fi

  local choice
  prompt "Clone to" choice "$default_choice"
  case "$choice" in
    2) CLONE_DIR="$HOME/.loki-agent" ;;
    3) CLONE_DIR="/tmp/loki-agent-$$" ;;
    *) CLONE_DIR="${current}/loki-agent" ;;
  esac
  fi

  echo ""
  info "Cloning loki-agent into ${CLONE_DIR}..."

  if [[ -d "$CLONE_DIR/.git" ]]; then
    info "Directory exists, syncing to latest..."
    git -C "$CLONE_DIR" fetch origin 2>&1 | tail -1
    local branch
    branch=$(git -C "$CLONE_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
    if ! git -C "$CLONE_DIR" merge --ff-only "origin/$branch" 2>/dev/null; then
      warn "Local repo diverged from remote — resetting to origin/$branch"
      git -C "$CLONE_DIR" reset --hard "origin/$branch" 2>&1 | tail -1
    fi
    clean_stale_terraform "$CLONE_DIR"
  else
    rm -rf "$CLONE_DIR" 2>/dev/null || true
    git clone --depth 1 "$REPO_URL" "$CLONE_DIR" 2>&1 | tail -1
  fi

  cd "$CLONE_DIR"
  ok "Repository ready: ${CLONE_DIR}"
}

clean_stale_terraform() {
  local dir="$1"
  local tf_dir="$dir/deploy/terraform/.terraform"
  [[ -d "$tf_dir" ]] || return 0

  warn "Found .terraform/ from a previous deploy in ${dir}"
  if confirm "  Clean it so Terraform starts fresh?" "default_yes"; then
    rm -rf "$tf_dir" "$dir/deploy/terraform/backend.tf" "$dir/deploy/terraform/.terraform.lock.hcl"
    ok "Cleaned stale Terraform state"
  else
    fail "Cannot proceed with stale .terraform/. Re-run and choose a different clone location or clean it manually."
  fi
}

# ============================================================================
# Deploy: CloudFormation Console (option 1)
# ============================================================================
deploy_console() {
  echo ""
  info "Preparing CloudFormation Console launch..."

  local bucket="${ENV_NAME}-cfn-templates-${ACCOUNT_ID}"
  create_s3_bucket "$bucket" "$DEPLOY_REGION"

  local tmp; tmp=$(mktemp /tmp/loki-cfn-template.XXXXXX.yaml)
  info "Downloading template..."
  curl -sfL "$TEMPLATE_RAW_URL" -o "$tmp" || fail "Failed to download template from GitHub"
  ok "Template downloaded"

  info "Uploading template to S3..."
  aws s3 cp "$tmp" "s3://${bucket}/loki-agent/template.yaml" --region "$DEPLOY_REGION" >/dev/null
  rm -f "$tmp"
  ok "Template uploaded"

  # Generate a pre-signed URL (valid 1 hour) since the bucket blocks public access
  local s3_url
  s3_url=$(aws s3 presign "s3://${bucket}/loki-agent/template.yaml" \
    --expires-in 3600 --region "$DEPLOY_REGION") \
    || fail "Could not generate pre-signed URL for template"
  local encoded
  encoded=$(url_encode "$s3_url")

  local url="https://${DEPLOY_REGION}.console.aws.amazon.com/cloudformation/home?region=${DEPLOY_REGION}#/stacks/create/review"
  url+="?templateURL=${encoded}&stackName=${ENV_NAME}-stack"
  url+="$(format_console_params)"

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  Open this link in your browser to launch the stack wizard  ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}${url}${NC}"
  echo ""

  if open_url "$url"; then ok "Opened in your browser"
  else info "Copy the link above and paste it into your browser"; fi

  echo ""
  echo -e "  ${BOLD}What to do next:${NC}"
  echo "    1. Log in to AWS if prompted"
  echo "    2. Review the parameters — your choices are pre-filled"
  echo "    3. Check \"I acknowledge that AWS CloudFormation might create IAM resources with custom names\""
  echo "    4. Click ${BOLD}Create stack${NC}"
  echo "    5. Wait ~10 minutes for the stack to finish"
  echo "    6. Find the Instance ID in the stack ${BOLD}Outputs${NC} tab"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo "    $(ssm_connect_cmd '<instance-id>')"
  echo "    loki tui"
  echo ""
  echo -e "  ${BOLD}Docs:${NC} ${DOCS_URL}"
  echo ""
  echo -e "  ${YELLOW}Note:${NC} Template bucket ${bucket} was created in your account."
  echo "  You can delete it after the stack is created:"
  echo "    aws s3 rb s3://${bucket} --force --region ${DEPLOY_REGION}"
  echo ""
}

# ============================================================================
# Deploy: CloudFormation / SAM via CLI (options 2-3)
# ============================================================================
deploy_cfn_stack() {
  local template="$1" capabilities="$2"
  STACK_NAME="${ENV_NAME}-stack"

  # shellcheck disable=SC2046
  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://${template}" \
    --region "$DEPLOY_REGION" \
    --capabilities $capabilities \
    --parameters $(format_cfn_cli_params) \
    --output text --query 'StackId'

  info "Stack creating... this takes ~8-10 minutes"
  wait_for_cfn_stack

  INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
  PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)
}

wait_for_cfn_stack() {
  local iterations=0 max_iterations=120  # 120 × 15s = 30 minutes
  while true; do
    local status rc=0
    status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
      echo ""; fail "Stack no longer exists or is inaccessible: $status"
    fi
    echo -ne "\r  Status: ${status}          "
    case "$status" in
      CREATE_COMPLETE)     echo ""; ok "Stack created!"; break ;;
      *FAILED*|*ROLLBACK*) echo ""; fail "Stack failed: $status" ;;
      *)
        iterations=$((iterations + 1))
        if [[ $iterations -ge $max_iterations ]]; then
          echo ""
          warn "Timed out after 30 minutes waiting for stack. Check the CloudFormation console for status."
          break
        fi
        sleep 15
        ;;
    esac
  done
}

# State tracking for Terraform backend (used by deploy_terraform to tag VPC)
TF_STATE_BUCKET=""
TF_STATE_KEY=""
TF_LOCK_TABLE=""
TF_WORKDIR=""  # Set if Terraform work is moved to /tmp (CloudShell low-disk)
PACK_NAME="openclaw"  # Default pack; overridden by collect_config

# VPC reuse: set by check_existing_deployments(); empty = create new VPC
EXISTING_VPC_ID=""
EXISTING_SUBNET_ID=""

# ============================================================================
# Deploy: Terraform (option 4)
# Auto-install Terraform if not present (works on CloudShell, AL2023, Ubuntu, macOS)
install_terraform() {
  info "Installing Terraform..."

  # Detect OS and architecture
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)             fail "Unsupported architecture: $(uname -m)" ;;
  esac

  # Get latest stable version from HashiCorp checkpoint
  local version
  version=$(curl -sf https://checkpoint-api.hashicorp.com/v1/check/terraform 2>/dev/null \
    | json_field current_version 2>/dev/null \
    || echo "1.12.1")  # Fallback to known good version

  local zip_url="https://releases.hashicorp.com/terraform/${version}/terraform_${version}_${os}_${arch}.zip"
  local install_dir="${HOME}/.local/bin"
  local tmp_zip="/tmp/terraform_${version}.zip"

  info "Downloading Terraform ${version} (${os}/${arch})..."
  curl -sfL "$zip_url" -o "$tmp_zip" || fail "Failed to download Terraform from ${zip_url}"

  # Unzip — use busybox or jar as fallback if unzip not available (CloudShell may not have it)
  mkdir -p "$install_dir"
  if command -v unzip &>/dev/null; then
    unzip -o -q "$tmp_zip" -d "$install_dir"
  elif command -v busybox &>/dev/null; then
    busybox unzip -o -q "$tmp_zip" -d "$install_dir"
  elif command -v jar &>/dev/null; then
    (cd "$install_dir" && jar xf "$tmp_zip")
  else
    fail "Cannot extract terraform zip — install 'unzip': sudo yum install -y unzip (or sudo apt install unzip)"
  fi

  chmod +x "${install_dir}/terraform"
  rm -f "$tmp_zip"

  # Add to PATH for this session
  export PATH="${install_dir}:${PATH}"

  if command -v terraform &>/dev/null; then
    ok "Terraform ${version} installed to ${install_dir}/terraform"
    ok "$(terraform version | head -1)"
  else
    fail "Terraform installed but not found in PATH. Try: export PATH=${install_dir}:\$PATH"
  fi
}

ensure_terraform() {
  if command -v terraform &>/dev/null; then
    ok "Terraform: $(terraform_version_string)"
    return 0
  fi

  # Should have been handled in choose_deploy_method, but install silently as a safety net
  install_terraform
}
# ============================================================================
deploy_terraform() {
  ensure_terraform
  cd deploy/terraform
  setup_terraform_backend
  terraform_init
  terraform_apply
  INSTANCE_ID=$(terraform output -raw instance_id)
  PUBLIC_IP=$(terraform output -raw public_ip)

  # Tag VPC with state backend info so uninstall can find it
  local vpc_id
  vpc_id=$(terraform output -raw vpc_id 2>/dev/null || echo "")
  if [[ -n "$vpc_id" && -n "$TF_STATE_BUCKET" ]]; then
    aws ec2 create-tags --resources "$vpc_id" --region "$DEPLOY_REGION" --tags \
      "Key=loki:tf-state-bucket,Value=${TF_STATE_BUCKET}" \
      "Key=loki:tf-state-key,Value=${TF_STATE_KEY}" \
      "Key=loki:tf-lock-table,Value=${TF_LOCK_TABLE}" 2>/dev/null || true
    ok "Tagged VPC with Terraform state location"
  fi

  ok "Terraform apply complete!"
}

setup_terraform_backend() {
  echo ""
  echo "  Terraform state storage:"
  echo "    1) Local  -- simple, for testing"
  echo "    2) S3     -- remote with locking (recommended)"
  echo ""
  local choice
  prompt "State storage" choice "2"
  [[ "$choice" == "2" ]] || return 0

  local bucket="${ENV_NAME}-tfstate-${ACCOUNT_ID}"
  prompt "S3 bucket name" bucket "$bucket"
  local lock_table="${ENV_NAME}-tflock"
  local state_key="loki-agent/terraform.tfstate"

  # Store for VPC tagging later
  TF_STATE_BUCKET="$bucket"
  TF_STATE_KEY="$state_key"
  TF_LOCK_TABLE="$lock_table"

  create_s3_bucket "$bucket" "$DEPLOY_REGION"

  if ! aws dynamodb describe-table --table-name "$lock_table" --region "$DEPLOY_REGION" &>/dev/null; then
    aws dynamodb create-table --table-name "$lock_table" --region "$DEPLOY_REGION" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST >/dev/null
  fi
  ok "Lock table ready"

  cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "${bucket}"
    key            = "${state_key}"
    region         = "${DEPLOY_REGION}"
    dynamodb_table = "${lock_table}"
    encrypt        = true
  }
}
EOF
}

terraform_init() {
  # AWS provider is ~500MB — CloudShell /home is ~1GB. Use /tmp for plugin cache.
  if [[ -z "${TF_PLUGIN_CACHE_DIR:-}" ]]; then
    export TF_PLUGIN_CACHE_DIR="/tmp/terraform-plugin-cache"
  fi
  mkdir -p "$TF_PLUGIN_CACHE_DIR"

  # Check disk space before downloading providers
  local avail_mb
  avail_mb=$(df -Pm "$(pwd)" 2>/dev/null | awk 'NR==2{print $4}' || echo "9999")
  if [[ "$avail_mb" -lt 600 ]]; then
    warn "Low disk space (${avail_mb}MB available) — Terraform providers need ~500MB"
    if [[ "$IS_CLOUDSHELL" == "true" ]]; then
      info "CloudShell detected — moving Terraform workdir to /tmp"
      TF_WORKDIR="/tmp/loki-terraform-$$"
      mkdir -p "$TF_WORKDIR"
      cp -a . "$TF_WORKDIR/"
      cd "$TF_WORKDIR"
      info "Working from: $(pwd)"
    else
      warn "You may run out of disk space. Consider freeing space or using /tmp."
    fi
  fi

  info "Initializing Terraform (downloading providers, may take a minute)..."
  info "Plugin cache: ${TF_PLUGIN_CACHE_DIR}"
  run_or_fail "Terraform init" terraform init -input=false
  grep -E 'Initializing|Installing|Installed' "$_RUN_LOG" | while IFS= read -r line; do
    echo -e "  ${BLUE}…${NC} ${line}"
  done
  rm -f "$_RUN_LOG"
  ok "Terraform initialized"
}

terraform_apply() {
  info "Deploying (~2-3 minutes)..."
  # Build -var arguments from the single parameter source-of-truth
  local tf_vars=()
  while IFS= read -r v; do
    tf_vars+=("$v")
  done < <(format_tf_vars)
  run_or_fail "Terraform apply" terraform apply -auto-approve "${tf_vars[@]}"

  grep -E 'Creating\.\.\.|Creation complete|Apply complete|Outputs:|= ' "$_RUN_LOG" | while IFS= read -r line; do
    if   [[ "$line" == *": Creating..."* ]];       then echo -e "  ${BLUE}+${NC} ${line##*] }"
    elif [[ "$line" == *": Creation complete"* ]];  then echo -e "  ${GREEN}✓${NC} ${line##*] }"
    elif [[ "$line" == *"Apply complete"* ]];       then echo -e "\n  ${GREEN}${line}${NC}"
    elif [[ "$line" == *"Outputs:"* ]] || [[ "$line" == *" = "* ]]; then echo "  $line"
    fi
  done
  rm -f "$_RUN_LOG"
}

# ============================================================================
# Ensure Loki-Session SSM document exists (instance-scoped, not account-wide)
ensure_ssm_session_document() {
  if aws ssm describe-document --name "$SSM_DOC_NAME" --region "$DEPLOY_REGION" &>/dev/null; then
    ok "SSM session document: ${SSM_DOC_NAME}"
    return 0
  fi
  info "Creating ${SSM_DOC_NAME} SSM document (starts sessions as ec2-user)..."
  aws ssm create-document \
    --name "$SSM_DOC_NAME" \
    --document-type "Session" \
    --content '{"schemaVersion":"1.0","description":"SSM session for Loki - starts as ec2-user","sessionType":"Standard_Stream","inputs":{"runAsEnabled":true,"runAsDefaultUser":"ec2-user","shellProfile":{"linux":"cd ~ && exec bash --login"}}}' \
    --region "$DEPLOY_REGION" >/dev/null 2>&1 || {
      warn "Could not create ${SSM_DOC_NAME} document (may need ssm:CreateDocument permission)"
      info "Connect with: aws ssm start-session --target \${INSTANCE_ID} --region \${DEPLOY_REGION}"
      info "Then run: sudo su - ec2-user"
      return 0
    }
  ok "Created ${SSM_DOC_NAME} SSM document"
}

# Post-deploy: wait for bootstrap + show results
# ============================================================================
wait_for_bootstrap() {
  echo ""
  info "Waiting for Loki to bootstrap (~10 minutes)..."
  echo "  Instance: ${INSTANCE_ID} | IP: ${PUBLIC_IP}"

  # Clear stale SSM params from previous deploys to avoid false failure detection
  aws ssm delete-parameter --name "/loki/setup-status" --region "$DEPLOY_REGION" 2>/dev/null || true
  aws ssm delete-parameter --name "/loki/setup-step" --region "$DEPLOY_REGION" 2>/dev/null || true
  aws ssm delete-parameter --name "/loki/setup-log" --region "$DEPLOY_REGION" 2>/dev/null || true

  for i in $(seq 1 60); do
    # Check for failure status first (fast path — no SSM command needed)
    local setup_status
    setup_status=$(aws ssm get-parameter --name "/loki/setup-status" \
      --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
    if [[ "$setup_status" == "FAILED" ]]; then
      echo ""
      local fail_step
      fail_step=$(aws ssm get-parameter --name "/loki/setup-step" \
        --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "unknown step")
      local fail_log
      fail_log=$(aws ssm get-parameter --name "/loki/setup-log" \
        --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
      echo ""
      echo -e "  ${RED}✗ Bootstrap FAILED${NC}"
      echo -e "  ${BOLD}Step:${NC} ${fail_step}"
      if [[ -n "$fail_log" ]]; then
        echo ""
        echo -e "  ${BOLD}Last log output:${NC}"
        echo "$fail_log" | tail -20 | sed 's/^/    /'
      fi

      # Auto-fetch full bootstrap log via SSM (saves the user from manual SSM + cat)
      echo ""
      info "Fetching full bootstrap log from instance..."
      local log_cmd_id
      log_cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters 'commands=["cat /var/log/loki-bootstrap.log 2>/dev/null || echo LOG_NOT_FOUND"]' \
        --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")
      if [[ -n "$log_cmd_id" ]]; then
        sleep 8  # give SSM time to execute
        local full_log
        full_log=$(aws ssm get-command-invocation --command-id "$log_cmd_id" \
          --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
          --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
        if [[ -n "$full_log" && "$full_log" != "LOG_NOT_FOUND" ]]; then
          local log_file="/tmp/loki-bootstrap-${INSTANCE_ID}.log"
          echo "$full_log" > "$log_file"
          ok "Full bootstrap log saved to: ${log_file}"
          echo ""
          echo -e "  ${BOLD}Last 30 lines:${NC}"
          echo "$full_log" | tail -30 | sed 's/^/    /'
        else
          warn "Could not retrieve bootstrap log via SSM"
          echo "  Connect manually: $(ssm_connect_cmd "$INSTANCE_ID")"
          echo "  Then check: cat /var/log/loki-bootstrap.log"
        fi
      else
        warn "SSM command failed — instance may not be reachable yet"
        echo "  Connect manually: $(ssm_connect_cmd "$INSTANCE_ID")"
        echo "  Then check: cat /var/log/loki-bootstrap.log"
      fi

      echo ""
      return 1
    fi

    local cmd_id
    cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["test -f /tmp/loki-bootstrap-done && echo READY || echo WAITING"]' \
      --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")

    if [[ -n "$cmd_id" ]]; then
      sleep 5
      local output
      output=$(aws ssm get-command-invocation --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
      [[ "$output" == *"READY"* ]] && { echo ""; ok "Loki is ready!"; return; }
    fi
    # Read current step from SSM parameter
    local current_step
    current_step=$(aws ssm get-parameter --name "/loki/setup-step" \
      --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
    if [[ -n "$current_step" ]]; then
      printf "\r  ⏳ [%s] %-50s" "$current_step" ""
    else
      printf "\r  ⏳ Bootstrapping... (%d/60) %-30s" "$i" ""
    fi
    sleep 10
  done
  warn "Bootstrap check timed out — Loki may still be starting up"
}

show_complete() {
  local ssm_cmd
  ssm_cmd="$(ssm_connect_cmd "$INSTANCE_ID")"

  # Load pack-specific commands for the completion screen
  local pack_profile="${CLONE_DIR}/packs/${PACK_NAME}/resources/shell-profile.sh"
  local pack_commands="loki tui"
  local pack_emoji="🤖"
  local pack_name_display="Loki"
  if [[ -f "$pack_profile" ]]; then
    source "$pack_profile"
    pack_emoji="${PACK_BANNER_EMOJI:-🤖}"
    pack_name_display="${PACK_BANNER_NAME:-Loki}"
    # Use first non-empty line from PACK_BANNER_COMMANDS as the primary command
    pack_commands="${PACK_BANNER_COMMANDS}"
  fi

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║    ${pack_emoji} ${pack_name_display} — deployed and running!${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Instance:${NC}  ${INSTANCE_ID}"
  echo -e "  ${BOLD}IP:${NC}        ${PUBLIC_IP}"
  echo -e "  ${BOLD}Region:${NC}    ${DEPLOY_REGION}"
  echo -e "  ${BOLD}Account:${NC}   ${ACCOUNT_ID}"
  echo ""
  echo -e "  ${BOLD}Docs:${NC}      ${DOCS_URL}"
  echo ""
  echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│${NC}  ${BOLD}👉 NEXT STEP: Connect to your agent${NC}                         ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}                                                              ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  ${GREEN}${ssm_cmd}${NC}"
  echo -e "${CYAN}│${NC}                                                              ${CYAN}│${NC}"
  echo -e "${CYAN}│${NC}  ${BOLD}Then run:${NC}                                                   ${CYAN}│${NC}"
  echo -e "${pack_commands}" | while IFS= read -r line; do
    [[ -n "$line" ]] && echo -e "${CYAN}│${NC}  ${GREEN}${line}${NC}"
  done
  echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
  echo ""

  if [[ -n "${CLONE_DIR:-}" ]] && confirm "Remove cloned repo directory (${CLONE_DIR})?" ; then
    # Sanity check: only delete paths that look like our clone dirs
    if [[ "$CLONE_DIR" == /tmp/* || "$CLONE_DIR" == "$HOME"/.* || "$CLONE_DIR" == *"/loki-agent" ]]; then
      rm -rf "$CLONE_DIR" 2>/dev/null
      ok "Cleaned up ${CLONE_DIR}"
    else
      warn "Unexpected clone path — skipping automatic removal: ${CLONE_DIR}"
    fi
  else
    info "Repo kept at ${CLONE_DIR}"
  fi
  if [[ -n "${TF_WORKDIR:-}" && -d "$TF_WORKDIR" ]]; then
    if confirm "Remove temp Terraform workdir (${TF_WORKDIR})?" ; then
      if [[ "$TF_WORKDIR" == /tmp/* ]]; then
        rm -rf "$TF_WORKDIR" 2>/dev/null
        ok "Cleaned up ${TF_WORKDIR}"
      else
        warn "Unexpected workdir path — skipping automatic removal: ${TF_WORKDIR}"
      fi
    else
      info "Terraform workdir kept at ${TF_WORKDIR}"
    fi
  fi
}

# ============================================================================
# Main
# ============================================================================
main() {
  show_banner
  preflight_checks
  choose_deploy_method
  collect_config
  # Skip VPC quota check when reusing an existing VPC
  if [[ -z "${EXISTING_VPC_ID:-}" ]]; then
    check_vpc_quota  # Run after collect_config so we use DEPLOY_REGION
  else
    ok "Skipping VPC quota check (reusing existing VPC ${EXISTING_VPC_ID})"
  fi
  build_deploy_params  # Populate parameter arrays from user config
  show_summary

  # Console deploy exits early (no clone, no bootstrap wait)
  if [[ "$DEPLOY_METHOD" == "$DEPLOY_CFN_CONSOLE" ]]; then
    deploy_console
    exit 0
  fi

  # CLI deploys need the repo
  prepare_repo
  echo ""

  case "$DEPLOY_METHOD" in
    "$DEPLOY_CFN_CLI") info "Deploying with CloudFormation..."
       deploy_cfn_stack "deploy/cloudformation/template.yaml" "CAPABILITY_NAMED_IAM" ;;
    "$DEPLOY_SAM") info "Deploying with SAM..."
       deploy_cfn_stack "deploy/sam/template.yaml" "CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND" ;;
    "$DEPLOY_TERRAFORM") info "Deploying with Terraform..."
       deploy_terraform ;;
    *) fail "Invalid choice: $DEPLOY_METHOD" ;;
  esac

  wait_for_bootstrap
  ensure_ssm_session_document
  show_complete
}

main "$@"
