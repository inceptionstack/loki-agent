#!/usr/bin/env bash
# Loki Agent — One-Shot Installer
# Usage: bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/install.sh)
set -euo pipefail

REPO_URL="https://github.com/inceptionstack/loki-agent.git"
TEMPLATE_RAW_URL="https://raw.githubusercontent.com/inceptionstack/loki-agent/main/deploy/cloudformation/template.yaml"

# ============================================================================
# UI helpers
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

prompt() {
  local text="$1" var="$2" default="${3:-}"
  local display="$text"; [[ -n "$default" ]] && display="$text [$default]"
  read -rp "$(echo -e "${BOLD}${display}:${NC} ")" value
  eval "$var=\"\${value:-$default}\""
}

confirm() {
  local text="$1" default="${2:-default_no}"
  local hint="[y/N]"; [[ "$default" == "default_yes" ]] && hint="[Y/n]"
  read -rp "$(echo -e "${BOLD}${text} ${hint}:${NC} ")" answer
  case "$default" in
    default_yes) [[ ! "$answer" =~ ^[Nn]$ ]] ;;
    *)           [[ "$answer" =~ ^[Yy]$ ]] ;;
  esac
}

toggle() {
  local text="$1" var="$2" default="${3:-true}"
  local hint="[Y/n]"; [[ "$default" == "false" ]] && hint="[y/N]"
  read -rp "$(echo -e "    ${text} ${hint}: ")" answer
  case "$default" in
    true)  [[ "$answer" =~ ^[Nn]$ ]] && eval "$var=false" || eval "$var=true" ;;
    false) [[ "$answer" =~ ^[Yy]$ ]] && eval "$var=true"  || eval "$var=false" ;;
  esac
}

require_cmd() { command -v "$1" &>/dev/null || fail "$2"; }

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

# ============================================================================
# Phase: Banner
# ============================================================================
show_banner() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       🤖 Loki Agent — AWS Installer         ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""
}

# ============================================================================
# Phase: Pre-flight checks
# ============================================================================
preflight_checks() {
  info "Running pre-flight checks..."

  require_cmd aws "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  ok "AWS CLI: $(aws --version 2>&1 | head -1)"

  aws sts get-caller-identity &>/dev/null \
    || fail "AWS credentials not configured. Run 'aws configure' first."

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

  ok "Identity: ${CALLER_ARN}"
  echo ""
  echo -e "  ${BOLD}Account:${NC}  ${ACCOUNT_ID}"
  echo -e "  ${BOLD}Region:${NC}   ${REGION}"
  echo ""
  warn "Loki will get AdministratorAccess on this ENTIRE account."
  warn "Use a dedicated sandbox account — never deploy in production."
  echo ""
  confirm "Deploy to account ${ACCOUNT_ID} in ${REGION}?" || { echo "Aborted."; exit 0; }

  check_permissions
  check_existing_deployments
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
    confirm "Continue anyway?" || { echo "Aborted."; exit 0; }
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
    while IFS=$'\t' read -r vpc_id watermark method name; do
      echo -e "    ${BOLD}${vpc_id}${NC}  watermark=${watermark:-n/a}  method=${method:-n/a}  name=${name:-n/a}"
    done <<< "$vpcs"
    echo ""
    warn "Deploying another Loki will create a separate VPC and resources."
    confirm "Continue with a new deployment?" || { echo "Aborted."; exit 0; }
  else
    ok "No existing Loki deployments found"
  fi
}

# ============================================================================
# Phase: Collect configuration
# ============================================================================
choose_deploy_method() {
  echo ""
  echo "  Deployment methods:"
  echo ""
  echo -e "    ${GREEN}1) CloudFormation Console${NC} -- opens browser wizard to review & launch"
  echo "    2) CloudFormation CLI     -- deploy from terminal"
  echo "    3) SAM                    -- for SAM CLI users"
  echo "    4) Terraform              -- for Terraform shops"
  echo ""
  prompt "Deployment method" DEPLOY_METHOD "1"
}

collect_config() {
  echo ""
  info "Configuration"
  echo ""

  prompt "Environment name (lowercase, resource prefix)" ENV_NAME "loki"
  ENV_NAME=$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
  prompt "Loki watermark (tag to identify this deployment)" LOKI_WATERMARK "$ENV_NAME"

  echo ""
  echo "  Instance sizes:"
  echo "    1) t4g.medium  -- 2 vCPU, 4GB  (~\$25/mo)  light use"
  echo "    2) t4g.large   -- 2 vCPU, 8GB  (~\$50/mo)  regular use"
  echo "    3) t4g.xlarge  -- 4 vCPU, 16GB (~\$100/mo) recommended"
  echo ""
  local choice
  prompt "Instance size" choice "3"
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

show_summary() {
  echo ""
  echo -e "  ${BOLD}╭─────────────── Deploy Summary ───────────────╮${NC}"
  echo -e "  ${BOLD}│${NC}  Environment:  ${ENV_NAME}"
  echo -e "  ${BOLD}│${NC}  Instance:     ${INSTANCE_TYPE}"
  echo -e "  ${BOLD}│${NC}  Region:       ${DEPLOY_REGION}"
  echo -e "  ${BOLD}│${NC}  Watermark:    ${LOKI_WATERMARK}"
  echo -e "  ${BOLD}│${NC}  SecurityHub:  ${SECURITY_HUB}  GuardDuty: ${GUARDDUTY}"
  echo -e "  ${BOLD}│${NC}  Inspector:    ${INSPECTOR}  Analyzer:  ${ACCESS_ANALYZER}"
  echo -e "  ${BOLD}│${NC}  Config:       ${CONFIG_RECORDER}"
  echo -e "  ${BOLD}╰───────────────────────────────────────────────╯${NC}"
  echo ""
  confirm "Proceed with deployment?" "default_yes" || { echo "Aborted."; exit 0; }
}

# ============================================================================
# Phase: Clone / prepare repo (CLI deploys only)
# ============================================================================
prepare_repo() {
  echo ""
  local current; current=$(pwd)
  echo "  Clone destination:"
  echo "    1) Current directory -- ${current}/loki-agent"
  echo "    2) ~/.loki-agent     -- persistent home directory"
  echo "    3) Temp directory    -- auto-deleted when done (not for Terraform local state)"
  echo ""
  local choice
  prompt "Clone to" choice "1"
  case "$choice" in
    2) CLONE_DIR="$HOME/.loki-agent" ;;
    3) CLONE_DIR="$(mktemp -d)/loki-agent" ;;
    *) CLONE_DIR="${current}/loki-agent" ;;
  esac

  echo ""
  info "Cloning loki-agent into ${CLONE_DIR}..."

  if [[ -d "$CLONE_DIR/.git" ]]; then
    info "Directory exists, pulling latest..."
    git -C "$CLONE_DIR" pull --ff-only 2>&1 | tail -1
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

  local s3_url="https://${bucket}.s3.amazonaws.com/loki-agent/template.yaml"
  local encoded; encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${s3_url}', safe=''))" 2>/dev/null \
    || echo "$s3_url")

  local url="https://${DEPLOY_REGION}.console.aws.amazon.com/cloudformation/home?region=${DEPLOY_REGION}#/stacks/create/review"
  url+="?templateURL=${encoded}&stackName=${ENV_NAME}-stack"
  url+="&param_EnvironmentName=${ENV_NAME}&param_InstanceType=${INSTANCE_TYPE}"
  url+="&param_BedrockRegion=${DEPLOY_REGION}&param_LokiWatermark=${LOKI_WATERMARK}"
  url+="&param_EnableSecurityHub=${SECURITY_HUB}&param_EnableGuardDuty=${GUARDDUTY}"
  url+="&param_EnableInspector=${INSPECTOR}&param_EnableAccessAnalyzer=${ACCESS_ANALYZER}"
  url+="&param_EnableConfigRecorder=${CONFIG_RECORDER}"

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
  echo "    aws ssm start-session --target <instance-id> --region ${DEPLOY_REGION}"
  echo "    openclaw tui"
  echo ""
  echo -e "  ${BOLD}Docs:${NC} https://github.com/inceptionstack/loki-agent/wiki"
  echo ""
  echo -e "  ${YELLOW}Note:${NC} Template bucket ${bucket} was created in your account."
  echo "  You can delete it after the stack is created:"
  echo "    aws s3 rb s3://${bucket} --force --region ${DEPLOY_REGION}"
  echo ""
}

# ============================================================================
# Deploy: CloudFormation / SAM via CLI (options 2-3)
# ============================================================================
cfn_parameters() {
  echo "ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME}" \
       "ParameterKey=InstanceType,ParameterValue=${INSTANCE_TYPE}" \
       "ParameterKey=ModelMode,ParameterValue=bedrock" \
       "ParameterKey=BedrockRegion,ParameterValue=${DEPLOY_REGION}" \
       "ParameterKey=EnableSecurityHub,ParameterValue=${SECURITY_HUB}" \
       "ParameterKey=EnableGuardDuty,ParameterValue=${GUARDDUTY}" \
       "ParameterKey=EnableInspector,ParameterValue=${INSPECTOR}" \
       "ParameterKey=EnableAccessAnalyzer,ParameterValue=${ACCESS_ANALYZER}" \
       "ParameterKey=EnableConfigRecorder,ParameterValue=${CONFIG_RECORDER}" \
       "ParameterKey=LokiWatermark,ParameterValue=${LOKI_WATERMARK}"
}

deploy_cfn_stack() {
  local template="$1" capabilities="$2"
  STACK_NAME="${ENV_NAME}-stack"

  # shellcheck disable=SC2046
  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://${template}" \
    --region "$DEPLOY_REGION" \
    --capabilities $capabilities \
    --parameters $(cfn_parameters) \
    --output text --query 'StackId'

  info "Stack creating... this takes ~8-10 minutes"
  wait_for_cfn_stack

  INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
  PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)
}

wait_for_cfn_stack() {
  while true; do
    local status
    status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1)
    echo -ne "\r  Status: ${status}          "
    case "$status" in
      CREATE_COMPLETE)     echo ""; ok "Stack created!"; break ;;
      *FAILED*|*ROLLBACK*) echo ""; fail "Stack failed: $status" ;;
      *)                   sleep 15 ;;
    esac
  done
}

# ============================================================================
# Deploy: Terraform (option 4)
# ============================================================================
deploy_terraform() {
  require_cmd terraform "Terraform not found. Install: https://developer.hashicorp.com/terraform/install"
  cd deploy/terraform
  setup_terraform_backend
  terraform_init
  terraform_apply
  INSTANCE_ID=$(terraform output -raw instance_id)
  PUBLIC_IP=$(terraform output -raw public_ip)
  ok "Terraform apply complete!"
}

setup_terraform_backend() {
  echo ""
  echo "  Terraform state storage:"
  echo "    1) Local  -- simple, for testing"
  echo "    2) S3     -- remote with locking (recommended)"
  echo ""
  local choice
  prompt "State storage" choice "1"
  [[ "$choice" == "2" ]] || return 0

  local bucket="${ENV_NAME}-tfstate-${ACCOUNT_ID}"
  prompt "S3 bucket name" bucket "$bucket"
  local lock_table="${ENV_NAME}-tflock"

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
    key            = "loki-agent/terraform.tfstate"
    region         = "${DEPLOY_REGION}"
    dynamodb_table = "${lock_table}"
    encrypt        = true
  }
}
EOF
}

terraform_init() {
  info "Initializing Terraform (downloading providers, may take a minute)..."
  run_or_fail "Terraform init" terraform init -input=false
  grep -E 'Initializing|Installing|Installed' "$_RUN_LOG" | while IFS= read -r line; do
    echo -e "  ${BLUE}…${NC} ${line}"
  done
  rm -f "$_RUN_LOG"
  ok "Terraform initialized"
}

terraform_apply() {
  info "Deploying (~2-3 minutes)..."
  run_or_fail "Terraform apply" terraform apply -auto-approve \
    -var="environment_name=${ENV_NAME}" \
    -var="instance_type=${INSTANCE_TYPE}" \
    -var="model_mode=bedrock" \
    -var="bedrock_region=${DEPLOY_REGION}" \
    -var="enable_security_hub=${SECURITY_HUB}" \
    -var="enable_guardduty=${GUARDDUTY}" \
    -var="enable_inspector=${INSPECTOR}" \
    -var="enable_access_analyzer=${ACCESS_ANALYZER}" \
    -var="enable_config_recorder=${CONFIG_RECORDER}" \
    -var="loki_watermark=${LOKI_WATERMARK}"

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
# Post-deploy: wait for bootstrap + show results
# ============================================================================
wait_for_bootstrap() {
  echo ""
  info "Waiting for Loki to bootstrap (~5 minutes)..."
  echo "  Instance: ${INSTANCE_ID} | IP: ${PUBLIC_IP}"

  for i in $(seq 1 30); do
    local cmd_id
    cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["test -f /tmp/openclaw-setup-done && echo READY || echo WAITING"]' \
      --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")

    if [[ -n "$cmd_id" ]]; then
      sleep 5
      local output
      output=$(aws ssm get-command-invocation --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
      [[ "$output" == *"READY"* ]] && { ok "Loki is ready!"; return; }
    fi
    echo -ne "\r  Bootstrapping... (${i}/30)    "
    sleep 10
  done
  warn "Bootstrap check timed out — Loki may still be starting up"
}

show_complete() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║         🤖 Loki is deployed and running!    ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Instance:${NC}  ${INSTANCE_ID}"
  echo -e "  ${BOLD}IP:${NC}        ${PUBLIC_IP}"
  echo -e "  ${BOLD}Region:${NC}    ${DEPLOY_REGION}"
  echo -e "  ${BOLD}Account:${NC}   ${ACCOUNT_ID}"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}   aws ssm start-session --target ${INSTANCE_ID} --region ${DEPLOY_REGION}"
  echo -e "  ${BOLD}Then run:${NC}  openclaw tui"
  echo ""
  echo -e "  ${BOLD}Docs:${NC}      https://github.com/inceptionstack/loki-agent/wiki"
  echo -e "  ${BOLD}Clone dir:${NC} ${CLONE_DIR}"
  echo ""

  if confirm "Remove cloned repo directory (${CLONE_DIR})?" ; then
    rm -rf "$CLONE_DIR" 2>/dev/null
    ok "Cleaned up ${CLONE_DIR}"
  else
    info "Repo kept at ${CLONE_DIR}"
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
  show_summary

  # Console deploy exits early (no clone, no bootstrap wait)
  if [[ "$DEPLOY_METHOD" == "1" ]]; then
    deploy_console
    exit 0
  fi

  # CLI deploys need the repo
  prepare_repo
  echo ""

  case "$DEPLOY_METHOD" in
    2) info "Deploying with CloudFormation..."
       deploy_cfn_stack "deploy/cloudformation/template.yaml" "CAPABILITY_NAMED_IAM" ;;
    3) info "Deploying with SAM..."
       deploy_cfn_stack "deploy/sam/template.yaml" "CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND" ;;
    4) info "Deploying with Terraform..."
       deploy_terraform ;;
    *) fail "Invalid choice: $DEPLOY_METHOD" ;;
  esac

  wait_for_bootstrap
  show_complete
}

main "$@"
