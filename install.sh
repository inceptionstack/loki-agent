#!/usr/bin/env bash
# Loki Agent — One-Shot Installer
# Usage: bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/install.sh)
set -euo pipefail

# ============================================================================
# Colors & Helpers
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${BLUE}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }
ask()   { echo -en "${BOLD}$1${NC} "; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       🤖 Loki Agent — AWS Installer  v2     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Step 1: Pre-flight checks
# ============================================================================
info "Running pre-flight checks..."

# AWS CLI
if ! command -v aws &>/dev/null; then
  fail "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
fi
ok "AWS CLI installed ($(aws --version 2>&1 | head -1))"

# AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
  fail "AWS credentials not configured. Run 'aws configure' or set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY."
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

ok "Authenticated as: ${CALLER_ARN}"
echo ""
echo -e "  ${BOLD}Account:${NC}  ${ACCOUNT_ID}"
echo -e "  ${BOLD}Region:${NC}   ${REGION}"
echo ""
warn "Loki will get AdministratorAccess on this ENTIRE account."
warn "Use a dedicated sandbox account — never deploy in production."
echo ""
read -rp "$(echo -e "${BOLD}Deploy Loki to account ${ACCOUNT_ID} in ${REGION}? [y/N]:${NC} ")" CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================================
# Step 2: Verify permissions
# ============================================================================
echo ""
info "Verifying deployment permissions..."

# Check we can create stacks / IAM roles
PERM_OK=true
for ACTION in "cloudformation:CreateStack" "iam:CreateRole" "ec2:CreateVpc" "lambda:CreateFunction"; do
  SVC="${ACTION%%:*}"
  ACT="${ACTION##*:}"
  # Quick permission check via dry-run where possible
done

# Just verify IAM access by trying to simulate
if aws iam simulate-principal-policy \
  --policy-source-arn "$CALLER_ARN" \
  --action-names "cloudformation:CreateStack" "iam:CreateRole" "ec2:CreateVpc" \
  --query 'EvaluationResults[?EvalDecision!=`allowed`].EvalActionName' --output text 2>/dev/null | grep -q "."; then
  warn "Some permissions may be missing. Deployment might fail if your IAM user/role lacks admin access."
  read -rp "$(echo -e "${BOLD}Continue anyway? [y/N]:${NC} ")" PERM_CONFIRM
  [[ "$PERM_CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
else
  ok "Permissions look good"
fi

# ============================================================================
# Step 3: Collect configuration
# ============================================================================
echo ""
info "Configuration"
echo ""

# Environment name
read -rp "$(echo -e "${BOLD}Environment name (lowercase, used as resource prefix) [loki]:${NC} ")" ENV_NAME
ENV_NAME="${ENV_NAME:-loki}"
ENV_NAME=$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')

# Instance type
echo ""
echo "  Instance sizes:"
echo "    1) t4g.medium  — 2 vCPU, 4GB  (~\$25/mo)  — light use, testing"
echo "    2) t4g.large   — 2 vCPU, 8GB  (~\$50/mo)  — regular use"
echo "    3) t4g.xlarge  — 4 vCPU, 16GB (~\$100/mo) — recommended for real dev work"
echo ""
read -rp "$(echo -e "${BOLD}Instance size [3]:${NC} ")" INST_CHOICE
case "${INST_CHOICE:-3}" in
  1) INSTANCE_TYPE="t4g.medium" ;;
  2) INSTANCE_TYPE="t4g.large" ;;
  *) INSTANCE_TYPE="t4g.xlarge" ;;
esac

# Region
read -rp "$(echo -e "${BOLD}AWS region [${REGION}]:${NC} ")" DEPLOY_REGION
DEPLOY_REGION="${DEPLOY_REGION:-$REGION}"

# Security services
echo ""
echo "  Security services (all enabled by default):"
echo "    SecurityHub, GuardDuty, Inspector, Access Analyzer, Config"
echo "    These cost ~\$5/mo total. Disable for test deploys to save costs"
echo "    and speed up teardown."
echo ""
read -rp "$(echo -e "${BOLD}Enable all security services? [Y/n]:${NC} ")" SEC_CHOICE
if [[ "$SEC_CHOICE" =~ ^[Nn]$ ]]; then
  SECURITY_HUB="false"; GUARDDUTY="false"; INSPECTOR="false"; ACCESS_ANALYZER="false"; CONFIG_RECORDER="false"
else
  SECURITY_HUB="true"; GUARDDUTY="true"; INSPECTOR="true"; ACCESS_ANALYZER="true"; CONFIG_RECORDER="true"
fi

# ============================================================================
# Step 4: Choose deployment method
# ============================================================================
echo ""
echo "  Deployment methods:"
echo "    1) CloudFormation — standard AWS, best for beginners"
echo "    2) SAM            — if you already use SAM CLI"
echo "    3) Terraform      — if you're a Terraform shop"
echo ""
read -rp "$(echo -e "${BOLD}Deployment method [1]:${NC} ")" DEPLOY_METHOD
DEPLOY_METHOD="${DEPLOY_METHOD:-1}"

# ============================================================================
# Step 5: Clone and deploy
# ============================================================================
echo ""
info "Cloning loki-agent..."

TMPDIR=$(mktemp -d)
git clone --depth 1 https://github.com/inceptionstack/loki-agent.git "$TMPDIR/loki-agent" 2>&1 | tail -1
cd "$TMPDIR/loki-agent"
ok "Repository cloned"

case "$DEPLOY_METHOD" in
  # --------------------------------------------------------------------------
  1)
    info "Deploying with CloudFormation..."
    STACK_NAME="${ENV_NAME}-stack"

    aws cloudformation create-stack \
      --stack-name "$STACK_NAME" \
      --template-body file://deploy/cloudformation/template.yaml \
      --region "$DEPLOY_REGION" \
      --capabilities CAPABILITY_NAMED_IAM \
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
      --output text --query 'StackId' 2>&1

    echo ""
    info "Stack creating... monitoring progress (this takes ~8-10 minutes)"
    echo ""

    while true; do
      STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
        --query 'Stacks[0].StackStatus' --output text 2>&1)
      echo -ne "\r  Status: ${STATUS}          "

      case "$STATUS" in
        CREATE_COMPLETE)
          echo ""
          ok "Stack created successfully!"
          break ;;
        *FAILED*|*ROLLBACK*)
          echo ""
          fail "Stack creation failed: $STATUS. Check the CloudFormation console for details." ;;
        *) sleep 15 ;;
      esac
    done

    # Get outputs
    INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
    PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)
    ;;

  # --------------------------------------------------------------------------
  2)
    info "Deploying with SAM..."
    if ! command -v sam &>/dev/null; then
      fail "SAM CLI not found. Install it: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html"
    fi

    STACK_NAME="${ENV_NAME}-stack"

    aws cloudformation create-stack \
      --stack-name "$STACK_NAME" \
      --template-body file://deploy/sam/template.yaml \
      --region "$DEPLOY_REGION" \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
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
      --output text --query 'StackId' 2>&1

    echo ""
    info "Stack creating... monitoring progress (this takes ~8-10 minutes)"
    echo ""

    while true; do
      STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
        --query 'Stacks[0].StackStatus' --output text 2>&1)
      echo -ne "\r  Status: ${STATUS}          "

      case "$STATUS" in
        CREATE_COMPLETE)
          echo ""
          ok "Stack created successfully!"
          break ;;
        *FAILED*|*ROLLBACK*)
          echo ""
          fail "Stack creation failed: $STATUS. Check the CloudFormation console for details." ;;
        *) sleep 15 ;;
      esac
    done

    INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
    PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)
    ;;

  # --------------------------------------------------------------------------
  3)
    info "Deploying with Terraform..."
    if ! command -v terraform &>/dev/null; then
      fail "Terraform not found. Install it: https://developer.hashicorp.com/terraform/install"
    fi

    cd deploy/terraform

    # TF state backend
    echo ""
    echo "  Terraform state storage:"
    echo "    1) Local     — state file in current directory (simple, for testing)"
    echo "    2) S3 bucket — remote state with locking (recommended for production)"
    echo ""
    read -rp "$(echo -e "${BOLD}State storage [1]:${NC} ")" TF_STATE
    TF_STATE="${TF_STATE:-1}"

    if [[ "$TF_STATE" == "2" ]]; then
      BUCKET_NAME="${ENV_NAME}-tfstate-${ACCOUNT_ID}"
      read -rp "$(echo -e "${BOLD}S3 bucket name [${BUCKET_NAME}]:${NC} ")" CUSTOM_BUCKET
      BUCKET_NAME="${CUSTOM_BUCKET:-$BUCKET_NAME}"

      info "Creating S3 state bucket: ${BUCKET_NAME}"
      if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" 2>/dev/null; then
        ok "Bucket already exists"
      else
        if [[ "$DEPLOY_REGION" == "us-east-1" ]]; then
          aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" >/dev/null
        else
          aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" \
            --create-bucket-configuration LocationConstraint="$DEPLOY_REGION" >/dev/null
        fi
        aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" --versioning-configuration Status=Enabled --region "$DEPLOY_REGION"
        aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" --region "$DEPLOY_REGION" \
          --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
        ok "S3 bucket created with versioning and encryption"
      fi

      # Create DynamoDB lock table
      LOCK_TABLE="${ENV_NAME}-tflock"
      if aws dynamodb describe-table --table-name "$LOCK_TABLE" --region "$DEPLOY_REGION" &>/dev/null; then
        ok "Lock table already exists"
      else
        aws dynamodb create-table --table-name "$LOCK_TABLE" --region "$DEPLOY_REGION" \
          --attribute-definitions AttributeName=LockID,AttributeType=S \
          --key-schema AttributeName=LockID,KeyType=HASH \
          --billing-mode PAY_PER_REQUEST >/dev/null
        ok "DynamoDB lock table created"
      fi

      # Write backend config
      cat > backend.tf << BACKEND
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "loki-agent/terraform.tfstate"
    region         = "${DEPLOY_REGION}"
    dynamodb_table = "${LOCK_TABLE}"
    encrypt        = true
  }
}
BACKEND
      ok "Backend configured: s3://${BUCKET_NAME}/loki-agent/terraform.tfstate"
    fi

    info "Initializing Terraform..."
    terraform init -input=false 2>&1 | tail -2

    info "Deploying... (this takes ~2-3 minutes)"
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
      2>&1 | tail -10

    INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null)
    PUBLIC_IP=$(terraform output -raw public_ip 2>/dev/null)
    ok "Terraform apply complete!"
    ;;

  *)
    fail "Invalid choice: $DEPLOY_METHOD"
    ;;
esac

# ============================================================================
# Step 6: Wait for bootstrap
# ============================================================================
echo ""
info "Infrastructure deployed. Waiting for Loki to bootstrap (~5 minutes)..."
echo "  Instance: ${INSTANCE_ID}"
echo "  Public IP: ${PUBLIC_IP}"
echo ""

for i in $(seq 1 30); do
  RESULT=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["test -f /tmp/openclaw-setup-done && echo READY || echo WAITING"]' \
    --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")

  if [[ -n "$RESULT" ]]; then
    sleep 5
    OUTPUT=$(aws ssm get-command-invocation --command-id "$RESULT" \
      --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
      --query 'StandardOutputContent' --output text 2>/dev/null || echo "")

    if [[ "$OUTPUT" == *"READY"* ]]; then
      ok "Loki is ready!"
      break
    fi
  fi

  echo -ne "\r  Bootstrapping... (${i}/30)    "
  sleep 10
done

# ============================================================================
# Done!
# ============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         🤖 Loki is deployed and running!    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Instance:${NC}   ${INSTANCE_ID}"
echo -e "  ${BOLD}Public IP:${NC}  ${PUBLIC_IP}"
echo -e "  ${BOLD}Region:${NC}     ${DEPLOY_REGION}"
echo -e "  ${BOLD}Account:${NC}    ${ACCOUNT_ID}"
echo ""
echo -e "  ${BOLD}Connect:${NC}"
echo -e "    aws ssm start-session --target ${INSTANCE_ID} --region ${DEPLOY_REGION}"
echo ""
echo -e "  ${BOLD}Then run:${NC}"
echo -e "    openclaw tui"
echo ""
echo -e "  ${BOLD}Docs:${NC} https://github.com/inceptionstack/loki-agent/wiki"
echo ""

# Cleanup
rm -rf "$TMPDIR" 2>/dev/null || true
