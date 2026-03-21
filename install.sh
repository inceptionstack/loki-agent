#!/usr/bin/env bash
# Loki Agent — One-Shot Installer
# Usage: bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/install.sh)
set -euo pipefail

# ============================================================================
# Helpers
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

TEMPLATE_RAW_URL="https://raw.githubusercontent.com/inceptionstack/loki-agent/main/deploy/cloudformation/template.yaml"

info() { echo -e "${BLUE}▸${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }

prompt() {
  local text="$1" var="$2" default="${3:-}"
  local display="$text"
  [[ -n "$default" ]] && display="$text [$default]"
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

require_cmd() {
  command -v "$1" &>/dev/null || fail "$2"
}

# Toggle a setting on/off interactively
toggle() {
  local text="$1" var="$2" default="${3:-true}"
  local hint="[Y/n]"; [[ "$default" == "false" ]] && hint="[y/N]"
  read -rp "$(echo -e "    ${text} ${hint}: ")" answer
  case "$default" in
    true)  [[ "$answer" =~ ^[Nn]$ ]] && eval "$var=false" || eval "$var=true" ;;
    false) [[ "$answer" =~ ^[Yy]$ ]] && eval "$var=true"  || eval "$var=false" ;;
  esac
}

# Try to open a URL in the user's browser
open_url() {
  local url="$1"
  if command -v open &>/dev/null; then
    open "$url" 2>/dev/null && return 0
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$url" 2>/dev/null && return 0
  elif command -v start &>/dev/null; then
    start "$url" 2>/dev/null && return 0
  elif [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v explorer.exe &>/dev/null; then
    explorer.exe "$url" 2>/dev/null && return 0
  fi
  return 1
}

# Shared: deploy a CFN-based stack (works for both CloudFormation and SAM)
deploy_cfn_stack() {
  local template="$1" capabilities="$2"
  STACK_NAME="${ENV_NAME}-stack"

  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://${template}" \
    --region "$DEPLOY_REGION" \
    --capabilities $capabilities \
    --parameters \
      ParameterKey=EnvironmentName,ParameterValue="$ENV_NAME" \
      ParameterKey=InstanceType,ParameterValue="$INSTANCE_TYPE" \
      ParameterKey=ModelMode,ParameterValue=bedrock \
      ParameterKey=BedrockRegion,ParameterValue="$DEPLOY_REGION" \
      ParameterKey=EnableSecurityHub,ParameterValue="$SECURITY_HUB" \
      ParameterKey=EnableGuardDuty,ParameterValue="$GUARDDUTY" \
      ParameterKey=EnableInspector,ParameterValue="$INSPECTOR" \
      ParameterKey=EnableAccessAnalyzer,ParameterValue="$ACCESS_ANALYZER" \
      ParameterKey=EnableConfigRecorder,ParameterValue="$CONFIG_RECORDER" \
      ParameterKey=LokiWatermark,ParameterValue="$LOKI_WATERMARK" \
    --output text --query 'StackId'

  info "Stack creating... this takes ~8-10 minutes"

  while true; do
    STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1)
    echo -ne "\r  Status: ${STATUS}          "
    case "$STATUS" in
      CREATE_COMPLETE)    echo ""; ok "Stack created!"; break ;;
      *FAILED*|*ROLLBACK*) echo ""; fail "Stack failed: $STATUS" ;;
      *)                  sleep 15 ;;
    esac
  done

  INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
  PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)
}

# ============================================================================
# Banner
# ============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       🤖 Loki Agent — AWS Installer         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Pre-flight checks (required for all options — AWS CLI needed)
# ============================================================================
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

# ============================================================================
# Permission check
# ============================================================================
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

# ============================================================================
# Detect existing Loki deployments
# ============================================================================
echo ""
info "Checking for existing Loki deployments..."

LOKI_VPCS=$(aws ec2 describe-vpcs \
  --filters "Name=tag:loki:managed,Values=true" \
  --region "$REGION" \
  --query 'Vpcs[*].[VpcId, Tags[?Key==`loki:watermark`].Value|[0], Tags[?Key==`loki:deploy-method`].Value|[0], Tags[?Key==`Name`].Value|[0]]' \
  --output text 2>/dev/null || echo "")

if [[ -n "$LOKI_VPCS" ]]; then
  LOKI_COUNT=$(echo "$LOKI_VPCS" | wc -l | tr -d ' ')
  warn "Found ${LOKI_COUNT} existing Loki deployment(s) in this account/region:"
  echo ""
  while IFS=$'\t' read -r vpc_id watermark method name; do
    echo -e "    ${BOLD}${vpc_id}${NC}  watermark=${watermark:-n/a}  method=${method:-n/a}  name=${name:-n/a}"
  done <<< "$LOKI_VPCS"
  echo ""
  warn "Deploying another Loki will create a separate VPC and resources."
  confirm "Continue with a new deployment?" || { echo "Aborted."; exit 0; }
else
  ok "No existing Loki deployments found"
fi

# ============================================================================
# Choose deployment method
# ============================================================================
echo ""
echo "  Deployment methods:"
echo ""
echo -e "    ${GREEN}1) CloudFormation Console${NC} -- opens browser wizard to review & launch"
echo "    2) CloudFormation CLI     -- deploy from terminal"
echo "    3) SAM                    -- for SAM CLI users"
echo "    4) Terraform              -- for Terraform shops"
echo ""
prompt "Deployment method" DEPLOY_METHOD "1"

# ============================================================================
# Configuration
# ============================================================================
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
prompt "Instance size" INST_CHOICE "3"
case "$INST_CHOICE" in
  1) INSTANCE_TYPE="t4g.medium" ;;
  2) INSTANCE_TYPE="t4g.large" ;;
  *) INSTANCE_TYPE="t4g.xlarge" ;;
esac

prompt "AWS region" DEPLOY_REGION "$REGION"

# ============================================================================
# Security services — interactive toggles
# ============================================================================
echo ""
echo -e "  ${BOLD}Security services${NC} (~\$5/mo total, individually toggleable):"
echo ""

if confirm "Enable all security services?" "default_yes"; then
  SECURITY_HUB="true"; GUARDDUTY="true"; INSPECTOR="true"; ACCESS_ANALYZER="true"; CONFIG_RECORDER="true"
  ok "All security services enabled"
else
  echo ""
  echo -e "  Pick which to enable:"
  echo ""
  toggle "AWS Security Hub"      SECURITY_HUB    true
  toggle "Amazon GuardDuty"      GUARDDUTY       true
  toggle "Amazon Inspector"      INSPECTOR       true
  toggle "IAM Access Analyzer"   ACCESS_ANALYZER true
  toggle "AWS Config Recorder"   CONFIG_RECORDER true
  echo ""
  ENABLED=""
  [[ "$SECURITY_HUB"    == "true" ]] && ENABLED="${ENABLED} SecurityHub"
  [[ "$GUARDDUTY"        == "true" ]] && ENABLED="${ENABLED} GuardDuty"
  [[ "$INSPECTOR"        == "true" ]] && ENABLED="${ENABLED} Inspector"
  [[ "$ACCESS_ANALYZER"  == "true" ]] && ENABLED="${ENABLED} AccessAnalyzer"
  [[ "$CONFIG_RECORDER"  == "true" ]] && ENABLED="${ENABLED} Config"
  if [[ -n "$ENABLED" ]]; then
    ok "Enabled:${ENABLED}"
  else
    warn "All security services disabled"
  fi
fi

# ============================================================================
# Summary
# ============================================================================
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

# ============================================================================
# Option 1: CloudFormation Console — upload template to S3, open browser
# ============================================================================
if [[ "$DEPLOY_METHOD" == "1" ]]; then
  echo ""
  info "Preparing CloudFormation Console launch..."

  # Create a private bucket for the template
  CFN_BUCKET="${ENV_NAME}-cfn-templates-${ACCOUNT_ID}"

  if ! aws s3api head-bucket --bucket "$CFN_BUCKET" --region "$DEPLOY_REGION" 2>/dev/null; then
    info "Creating template bucket: ${CFN_BUCKET}"
    if [[ "$DEPLOY_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$CFN_BUCKET" --region "$DEPLOY_REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$CFN_BUCKET" --region "$DEPLOY_REGION" \
        --create-bucket-configuration LocationConstraint="$DEPLOY_REGION" >/dev/null
    fi
    ok "Bucket created: ${CFN_BUCKET}"
  else
    ok "Bucket exists: ${CFN_BUCKET}"
  fi

  # Download template from GitHub and upload to S3
  TEMPLATE_TMP=$(mktemp /tmp/loki-cfn-template.XXXXXX.yaml)
  info "Downloading template..."
  curl -sfL "$TEMPLATE_RAW_URL" -o "$TEMPLATE_TMP" \
    || fail "Failed to download template from GitHub"
  ok "Template downloaded"

  info "Uploading template to S3..."
  aws s3 cp "$TEMPLATE_TMP" "s3://${CFN_BUCKET}/loki-agent/template.yaml" \
    --region "$DEPLOY_REGION" >/dev/null
  rm -f "$TEMPLATE_TMP"
  ok "Template uploaded"

  # Build the S3 HTTPS URL (CloudFormation-compatible format)
  TEMPLATE_S3_URL="https://${CFN_BUCKET}.s3.amazonaws.com/loki-agent/template.yaml"

  # URL-encode for console
  ENCODED_URL=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TEMPLATE_S3_URL}', safe=''))" 2>/dev/null \
    || python -c "import urllib; print(urllib.quote('${TEMPLATE_S3_URL}', safe=''))" 2>/dev/null \
    || echo "$TEMPLATE_S3_URL")

  # Build console URL with pre-filled parameters
  CONSOLE_URL="https://${DEPLOY_REGION}.console.aws.amazon.com/cloudformation/home?region=${DEPLOY_REGION}#/stacks/create/review"
  CONSOLE_URL="${CONSOLE_URL}?templateURL=${ENCODED_URL}"
  CONSOLE_URL="${CONSOLE_URL}&stackName=${ENV_NAME}-stack"
  CONSOLE_URL="${CONSOLE_URL}&param_EnvironmentName=${ENV_NAME}"
  CONSOLE_URL="${CONSOLE_URL}&param_InstanceType=${INSTANCE_TYPE}"
  CONSOLE_URL="${CONSOLE_URL}&param_BedrockRegion=${DEPLOY_REGION}"
  CONSOLE_URL="${CONSOLE_URL}&param_EnableSecurityHub=${SECURITY_HUB}"
  CONSOLE_URL="${CONSOLE_URL}&param_EnableGuardDuty=${GUARDDUTY}"
  CONSOLE_URL="${CONSOLE_URL}&param_EnableInspector=${INSPECTOR}"
  CONSOLE_URL="${CONSOLE_URL}&param_EnableAccessAnalyzer=${ACCESS_ANALYZER}"
  CONSOLE_URL="${CONSOLE_URL}&param_EnableConfigRecorder=${CONFIG_RECORDER}"
  CONSOLE_URL="${CONSOLE_URL}&param_LokiWatermark=${LOKI_WATERMARK}"

  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  Open this link in your browser to launch the stack wizard  ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}${CONSOLE_URL}${NC}"
  echo ""

  if open_url "$CONSOLE_URL"; then
    ok "Opened in your browser"
  else
    info "Copy the link above and paste it into your browser"
  fi

  echo ""
  echo -e "  ${BOLD}What to do next:${NC}"
  echo "    1. Log in to AWS if prompted"
  echo "    2. Review the parameters — your choices are pre-filled"
  echo "    3. Scroll down and check \"I acknowledge that AWS CloudFormation might create IAM resources with custom names\""
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
  echo -e "  ${YELLOW}Note:${NC} Template bucket ${CFN_BUCKET} was created in your account."
  echo "  You can delete it after the stack is created:"
  echo "    aws s3 rb s3://${CFN_BUCKET} --force --region ${DEPLOY_REGION}"
  echo ""
  exit 0
fi

# ============================================================================
# Options 2-4: CLI-based deploys — need to clone repo
# ============================================================================

# Clone location
echo ""
CURRENT_DIR=$(pwd)
echo "  Clone destination:"
echo "    1) Current directory -- ${CURRENT_DIR}/loki-agent"
echo "    2) ~/.loki-agent     -- persistent home directory"
echo "    3) Temp directory    -- auto-deleted when done (not for Terraform local state)"
echo ""
prompt "Clone to" CLONE_CHOICE "1"

case "$CLONE_CHOICE" in
  2) CLONE_DIR="$HOME/.loki-agent" ;;
  3) CLONE_DIR="$(mktemp -d)/loki-agent" ;;
  *) CLONE_DIR="${CURRENT_DIR}/loki-agent" ;;
esac

# Clone repo
echo ""
info "Cloning loki-agent into ${CLONE_DIR}..."

if [[ -d "$CLONE_DIR/.git" ]]; then
  info "Directory exists, pulling latest..."
  git -C "$CLONE_DIR" pull --ff-only 2>&1 | tail -1
else
  rm -rf "$CLONE_DIR" 2>/dev/null || true
  git clone --depth 1 https://github.com/inceptionstack/loki-agent.git "$CLONE_DIR" 2>&1 | tail -1
fi
cd "$CLONE_DIR"
ok "Repository ready: ${CLONE_DIR}"

# Deploy
echo ""
case "$DEPLOY_METHOD" in
  2)
    info "Deploying with CloudFormation..."
    deploy_cfn_stack "deploy/cloudformation/template.yaml" "CAPABILITY_NAMED_IAM"
    ;;
  3)
    info "Deploying with SAM..."
    deploy_cfn_stack "deploy/sam/template.yaml" "CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND"
    ;;
  4)
    info "Deploying with Terraform..."
    require_cmd terraform "Terraform not found. Install: https://developer.hashicorp.com/terraform/install"
    cd deploy/terraform

    # State backend
    echo ""
    echo "  Terraform state storage:"
    echo "    1) Local  -- simple, for testing"
    echo "    2) S3     -- remote with locking (recommended)"
    echo ""
    prompt "State storage" TF_STATE "1"

    if [[ "$TF_STATE" == "2" ]]; then
      BUCKET_NAME="${ENV_NAME}-tfstate-${ACCOUNT_ID}"
      prompt "S3 bucket name" BUCKET_NAME "$BUCKET_NAME"
      LOCK_TABLE="${ENV_NAME}-tflock"

      # Create bucket
      if ! aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" 2>/dev/null; then
        info "Creating state bucket: ${BUCKET_NAME}"
        if [[ "$DEPLOY_REGION" == "us-east-1" ]]; then
          aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" >/dev/null
        else
          aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" \
            --create-bucket-configuration LocationConstraint="$DEPLOY_REGION" >/dev/null
        fi
        aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
          --versioning-configuration Status=Enabled --region "$DEPLOY_REGION"
        aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" \
          --server-side-encryption-configuration \
          '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
      fi
      ok "State bucket ready"

      # Create lock table
      if ! aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$DEPLOY_REGION" &>/dev/null; then
        aws dynamodb create-table --table-name "$LOCK_TABLE" --region "$DEPLOY_REGION" \
          --attribute-definitions AttributeName=LockID,AttributeType=S \
          --key-schema AttributeName=LockID,KeyType=HASH \
          --billing-mode PAY_PER_REQUEST >/dev/null
      fi
      ok "Lock table ready"

      cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "loki-agent/terraform.tfstate"
    region         = "${DEPLOY_REGION}"
    dynamodb_table = "${LOCK_TABLE}"
    encrypt        = true
  }
}
EOF
    fi

    info "Initializing Terraform (downloading providers, may take a minute)..."
    TF_INIT_LOG=$(mktemp)
    set +e
    terraform init -input=false -reconfigure > "$TF_INIT_LOG" 2>&1
    TF_INIT_RC=$?
    set -e
    if [[ $TF_INIT_RC -ne 0 ]]; then
      echo ""
      warn "Terraform init failed:"
      cat "$TF_INIT_LOG"
      rm -f "$TF_INIT_LOG"
      fail "terraform init exited with code $TF_INIT_RC"
    fi
    # Show key progress lines
    grep -E 'Initializing|Installing|Installed' "$TF_INIT_LOG" | while IFS= read -r line; do
      echo -e "  ${BLUE}…${NC} ${line}"
    done
    rm -f "$TF_INIT_LOG"
    ok "Terraform initialized"

    info "Deploying (~2-3 minutes)..."
    TF_APPLY_LOG=$(mktemp)
    set +e
    terraform apply -auto-approve \
      -var="environment_name=${ENV_NAME}" \
      -var="instance_type=${INSTANCE_TYPE}" \
      -var="model_mode=bedrock" \
      -var="bedrock_region=${DEPLOY_REGION}" \
      -var="enable_security_hub=${SECURITY_HUB}" \
      -var="enable_guardduty=${GUARDDUTY}" \
      -var="enable_inspector=${INSPECTOR}" \
      -var="enable_access_analyzer=${ACCESS_ANALYZER}" \
      -var="enable_config_recorder=${CONFIG_RECORDER}" \
      -var="loki_watermark=${LOKI_WATERMARK}" \
      > "$TF_APPLY_LOG" 2>&1
    TF_APPLY_RC=$?
    set -e
    # Show progress lines
    grep -E 'Creating\.\.\.|Creation complete|Apply complete|Outputs:|= ' "$TF_APPLY_LOG" | while IFS= read -r line; do
      if [[ "$line" == *": Creating..."* ]]; then
        echo -e "  ${BLUE}+${NC} ${line##*] }"
      elif [[ "$line" == *": Creation complete"* ]]; then
        echo -e "  ${GREEN}✓${NC} ${line##*] }"
      elif [[ "$line" == *"Apply complete"* ]]; then
        echo -e "\n  ${GREEN}${line}${NC}"
      elif [[ "$line" == *"Outputs:"* ]] || [[ "$line" == *" = "* ]]; then
        echo "  $line"
      fi
    done
    if [[ $TF_APPLY_RC -ne 0 ]]; then
      echo ""
      warn "Terraform apply failed. Full output:"
      cat "$TF_APPLY_LOG"
      rm -f "$TF_APPLY_LOG"
      fail "terraform apply exited with code $TF_APPLY_RC"
    fi
    rm -f "$TF_APPLY_LOG"

    INSTANCE_ID=$(terraform output -raw instance_id)
    PUBLIC_IP=$(terraform output -raw public_ip)
    ok "Terraform apply complete!"
    ;;
  *)
    fail "Invalid choice: $DEPLOY_METHOD"
    ;;
esac

# ============================================================================
# Wait for bootstrap
# ============================================================================
echo ""
info "Waiting for Loki to bootstrap (~5 minutes)..."
echo "  Instance: ${INSTANCE_ID} | IP: ${PUBLIC_IP}"

for i in $(seq 1 30); do
  CMD_ID=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["test -f /tmp/openclaw-setup-done && echo READY || echo WAITING"]' \
    --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")

  if [[ -n "$CMD_ID" ]]; then
    sleep 5
    OUTPUT=$(aws ssm get-command-invocation --command-id "$CMD_ID" \
      --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
      --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
    [[ "$OUTPUT" == *"READY"* ]] && { ok "Loki is ready!"; break; }
  fi
  echo -ne "\r  Bootstrapping... (${i}/30)    "
  sleep 10
done

# ============================================================================
# Done
# ============================================================================
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
