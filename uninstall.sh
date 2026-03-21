#!/usr/bin/env bash
# Loki Agent — Uninstaller
# Usage: bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/loki-agent/main/uninstall.sh)
#
# Finds all Loki deployments in your account (by loki:managed tag),
# lets you pick which to remove, and cleans up all resources.
set -euo pipefail

UNINSTALLER_VERSION="0.1.0"

# ============================================================================
# UI helpers (shared with install.sh)
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

require_cmd() { command -v "$1" &>/dev/null || fail "$2"; }

# Verify AWS credentials with specific error messages
verify_aws_credentials() {
  local sts_output sts_rc
  sts_output=$(aws sts get-caller-identity 2>&1)
  sts_rc=$?
  if [[ $sts_rc -ne 0 ]]; then
    warn "aws sts get-caller-identity failed:"
    warn "$sts_output"
    if aws configure list 2>/dev/null | grep -q '<not set>'; then
      fail "AWS credentials not configured. Run 'aws configure' first."
    else
      fail "AWS credentials are configured (profile: ${AWS_PROFILE:-default}) but authentication failed. Refresh your session or check your credential process."
    fi
  fi
}

# ============================================================================
# Banner
# ============================================================================
show_banner() {
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║     🗑️  Loki Agent — Uninstaller             ║${NC}"
  echo -e "${RED}║     v${UNINSTALLER_VERSION}                                     ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  warn "This script ${BOLD}permanently destroys${NC}${YELLOW} Loki deployments and all their resources."
  warn "There is NO undo. Data on EC2 instances will be LOST."
  echo ""
}

# ============================================================================
# Pre-flight
# ============================================================================
preflight() {
  info "Running pre-flight checks..."

  require_cmd aws "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  ok "AWS CLI: $(aws --version 2>&1 | head -1)"

  verify_aws_credentials
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

  ok "Identity: ${CALLER_ARN}"
  echo -e "  ${BOLD}Account:${NC}  ${ACCOUNT_ID}"
  echo -e "  ${BOLD}Region:${NC}   ${REGION}"
  echo ""
}

# ============================================================================
# Discovery: find all Loki deployments
# ============================================================================
discover_deployments() {
  prompt "AWS region to scan" SCAN_REGION "$REGION"
  echo ""
  info "Scanning for Loki deployments in ${SCAN_REGION}..."

  # Find tagged VPCs (all deploy methods tag the VPC)
  VPCS_RAW=$(aws ec2 describe-vpcs \
    --filters "Name=tag:loki:managed,Values=true" \
    --region "$SCAN_REGION" \
    --query 'Vpcs[*].[VpcId, Tags[?Key==`loki:watermark`].Value|[0], Tags[?Key==`loki:deploy-method`].Value|[0], Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

  if [[ -z "$VPCS_RAW" ]]; then
    ok "No Loki deployments found in ${SCAN_REGION}"
    exit 0
  fi

  # Build arrays
  DEPLOY_COUNT=0
  VPC_IDS=()
  WATERMARKS=()
  METHODS=()
  NAMES=()
  TF_BUCKETS=()
  TF_KEYS=()
  TF_LOCKS=()

  while IFS=$'\t' read -r vpc_id watermark method name; do
    VPC_IDS+=("$vpc_id")
    WATERMARKS+=("${watermark:-unknown}")
    METHODS+=("${method:-unknown}")
    NAMES+=("${name:-unnamed}")

    # Fetch Terraform state tags if this was a terraform deploy
    local tf_bucket="" tf_key="" tf_lock=""
    if [[ "${method:-}" == "terraform" ]]; then
      tf_bucket=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${vpc_id}" "Name=key,Values=loki:tf-state-bucket" \
        --region "$SCAN_REGION" --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
      [[ "$tf_bucket" == "None" ]] && tf_bucket=""
      tf_key=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${vpc_id}" "Name=key,Values=loki:tf-state-key" \
        --region "$SCAN_REGION" --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
      [[ "$tf_key" == "None" ]] && tf_key=""
      tf_lock=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${vpc_id}" "Name=key,Values=loki:tf-lock-table" \
        --region "$SCAN_REGION" --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
      [[ "$tf_lock" == "None" ]] && tf_lock=""
    fi
    TF_BUCKETS+=("$tf_bucket")
    TF_KEYS+=("$tf_key")
    TF_LOCKS+=("$tf_lock")

    DEPLOY_COUNT=$((DEPLOY_COUNT + 1))
  done <<< "$VPCS_RAW"

  echo ""
  echo -e "  ${BOLD}Found ${DEPLOY_COUNT} Loki deployment(s):${NC}"
  echo ""
  for i in $(seq 0 $((DEPLOY_COUNT - 1))); do
    local idx=$((i + 1))
    echo -e "    ${BOLD}${idx})${NC} ${VPC_IDS[$i]}  watermark=${YELLOW}${WATERMARKS[$i]}${NC}  method=${METHODS[$i]}  name=${NAMES[$i]}"

    # Show associated resources summary
    local instance_count
    instance_count=$(aws ec2 describe-instances \
      --filters "Name=vpc-id,Values=${VPC_IDS[$i]}" "Name=instance-state-name,Values=running,stopped" \
      --region "$SCAN_REGION" --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "0")
    echo -e "       EC2 instances: ${instance_count}"

    # Show TF state info if available
    if [[ -n "${TF_BUCKETS[$i]}" ]]; then
      echo -e "       TF state: s3://${TF_BUCKETS[$i]}/${TF_KEYS[$i]}"
      [[ -n "${TF_LOCKS[$i]}" ]] && echo -e "       TF lock:  ${TF_LOCKS[$i]}"
    fi
  done
  echo ""
}

# ============================================================================
# Selection: which deployments to remove
# ============================================================================
select_targets() {
  if [[ "$DEPLOY_COUNT" -eq 1 ]]; then
    echo -e "  Only one deployment found."
    confirm "Remove it?" || { echo "Aborted."; exit 0; }
    TARGETS=(0)
    return
  fi

  echo "  Options:"
  echo "    a) Remove ALL deployments"
  echo "    Or enter numbers separated by spaces (e.g. '1 3')"
  echo ""
  local choice
  prompt "Which to remove" choice "a"

  if [[ "$choice" == "a" || "$choice" == "A" ]]; then
    TARGETS=()
    for i in $(seq 0 $((DEPLOY_COUNT - 1))); do
      TARGETS+=("$i")
    done
  else
    TARGETS=()
    for num in $choice; do
      local idx=$((num - 1))
      if [[ $idx -ge 0 && $idx -lt $DEPLOY_COUNT ]]; then
        TARGETS+=("$idx")
      else
        warn "Ignoring invalid selection: $num"
      fi
    done
  fi

  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    fail "No valid deployments selected"
  fi
}

# ============================================================================
# Confirmation gauntlet
# ============================================================================
confirm_destruction() {
  echo ""
  echo -e "  ${RED}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${RED}${BOLD}║  ⚠️  DESTRUCTIVE OPERATION — POINT OF NO RETURN     ║${NC}"
  echo -e "  ${RED}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  The following will be ${RED}${BOLD}PERMANENTLY DESTROYED${NC}:"
  echo ""
  for i in "${TARGETS[@]}"; do
    echo -e "    ${RED}✗${NC} ${VPC_IDS[$i]}  (${WATERMARKS[$i]}) — VPC, EC2, IAM, security services, all resources"
  done
  echo ""
  warn "EC2 instance data will be LOST. EBS volumes will be DELETED."
  warn "Security services (GuardDuty, SecurityHub, etc.) may be disabled."
  warn "CloudFormation stacks will be deleted if found."
  echo ""

  confirm "Are you SURE you want to destroy these deployments?" || { echo "Aborted."; exit 0; }
  echo ""
  echo -e "  ${RED}Type the word ${BOLD}DESTROY${NC}${RED} to confirm:${NC}"
  local answer
  read -rp "  > " answer
  [[ "$answer" == "DESTROY" ]] || { echo "Aborted."; exit 0; }
  echo ""
}

# ============================================================================
# Removal: delete a single deployment
# ============================================================================
remove_deployment() {
  local idx="$1"
  local vpc_id="${VPC_IDS[$idx]}"
  local watermark="${WATERMARKS[$idx]}"
  local method="${METHODS[$idx]}"

  echo ""
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  info "Removing deployment: ${watermark} (${vpc_id})"
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Try CloudFormation stack deletion first (cleanest path)
  if try_delete_cfn_stack "$watermark" "$vpc_id"; then
    ok "Deployment ${watermark} removed via CloudFormation"
    return
  fi

  # Manual cleanup for Terraform or orphaned resources
  info "No matching CloudFormation stack — cleaning up resources manually..."
  terminate_instances "$vpc_id"
  delete_security_groups "$vpc_id"
  delete_subnets "$vpc_id"
  delete_route_tables "$vpc_id"
  detach_and_delete_igw "$vpc_id"
  delete_vpc "$vpc_id"
  delete_iam_resources "$watermark"
  ok "Deployment ${watermark} removed"
}

# ============================================================================
# CloudFormation stack deletion
# ============================================================================
try_delete_cfn_stack() {
  local watermark="$1" vpc_id="$2"

  # Search for stacks that created this VPC
  local stacks
  stacks=$(aws cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
    --region "$SCAN_REGION" \
    --query 'StackSummaries[*].StackName' --output text 2>/dev/null || echo "")

  for stack_name in $stacks; do
    # Check if this stack owns the VPC
    local stack_vpc
    stack_vpc=$(aws cloudformation describe-stack-resources \
      --stack-name "$stack_name" --region "$SCAN_REGION" \
      --query "StackResources[?ResourceType=='AWS::EC2::VPC'].PhysicalResourceId" \
      --output text 2>/dev/null || echo "")

    if [[ "$stack_vpc" == *"$vpc_id"* ]]; then
      info "Found CloudFormation stack: ${stack_name}"
      info "Deleting stack (this takes 5-10 minutes)..."

      aws cloudformation delete-stack --stack-name "$stack_name" --region "$SCAN_REGION"

      while true; do
        local status
        status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$SCAN_REGION" \
          --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "DELETE_COMPLETE")
        echo -ne "\r  Status: ${status}              "
        case "$status" in
          DELETE_COMPLETE)       echo ""; return 0 ;;
          *DELETE_FAILED*)       echo ""; warn "Stack delete failed — falling back to manual cleanup"; return 1 ;;
          *does\ not\ exist*)   echo ""; return 0 ;;
          *)                    sleep 15 ;;
        esac
      done
    fi
  done

  return 1  # No matching stack found
}

# ============================================================================
# Manual resource cleanup (for Terraform deploys or orphans)
# ============================================================================
terminate_instances() {
  local vpc_id="$1"
  local instances
  instances=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=instance-state-name,Values=running,stopped,stopping" \
    --region "$SCAN_REGION" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")

  for iid in $instances; do
    info "Terminating instance: ${iid}"
    # Disable termination protection if set
    aws ec2 modify-instance-attribute --instance-id "$iid" --no-disable-api-termination \
      --region "$SCAN_REGION" 2>/dev/null || true
    aws ec2 terminate-instances --instance-ids "$iid" --region "$SCAN_REGION" >/dev/null
  done

  # Wait for termination
  if [[ -n "$instances" ]]; then
    info "Waiting for instances to terminate..."
    for iid in $instances; do
      aws ec2 wait instance-terminated --instance-ids "$iid" --region "$SCAN_REGION" 2>/dev/null || true
    done
    ok "Instances terminated"
  fi
}

delete_security_groups() {
  local vpc_id="$1"
  local sgs
  sgs=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --region "$SCAN_REGION" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || echo "")

  for sg in $sgs; do
    # Revoke all ingress/egress rules first
    aws ec2 revoke-security-group-ingress --group-id "$sg" --region "$SCAN_REGION" \
      --security-group-rule-ids $(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$sg" --region "$SCAN_REGION" \
        --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null) 2>/dev/null || true
    aws ec2 revoke-security-group-egress --group-id "$sg" --region "$SCAN_REGION" \
      --security-group-rule-ids $(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$sg" --region "$SCAN_REGION" \
        --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null) 2>/dev/null || true

    info "Deleting security group: ${sg}"
    aws ec2 delete-security-group --group-id "$sg" --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete SG ${sg} (may have dependencies)"
  done
}

delete_subnets() {
  local vpc_id="$1"
  local subnets
  subnets=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --region "$SCAN_REGION" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")

  for subnet in $subnets; do
    info "Deleting subnet: ${subnet}"
    aws ec2 delete-subnet --subnet-id "$subnet" --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete subnet ${subnet}"
  done
}

delete_route_tables() {
  local vpc_id="$1"
  local rts
  rts=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --region "$SCAN_REGION" \
    --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' --output text 2>/dev/null || echo "")

  for rt in $rts; do
    # Disassociate first
    local assocs
    assocs=$(aws ec2 describe-route-tables --route-table-ids "$rt" --region "$SCAN_REGION" \
      --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null || echo "")
    for assoc in $assocs; do
      aws ec2 disassociate-route-table --association-id "$assoc" --region "$SCAN_REGION" 2>/dev/null || true
    done
    info "Deleting route table: ${rt}"
    aws ec2 delete-route-table --route-table-id "$rt" --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete RT ${rt}"
  done
}

detach_and_delete_igw() {
  local vpc_id="$1"
  local igws
  igws=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --region "$SCAN_REGION" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || echo "")

  for igw in $igws; do
    info "Detaching internet gateway: ${igw}"
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" --region "$SCAN_REGION" 2>/dev/null || true
    info "Deleting internet gateway: ${igw}"
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete IGW ${igw}"
  done
}

delete_vpc() {
  local vpc_id="$1"
  info "Deleting VPC: ${vpc_id}"
  aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$SCAN_REGION" 2>/dev/null \
    || warn "Could not delete VPC ${vpc_id} — some resources may still depend on it"
}

delete_iam_resources() {
  local watermark="$1"

  # Find IAM roles tagged with this watermark
  local roles
  roles=$(aws iam list-roles --query "Roles[?contains(RoleName, '${watermark}')].RoleName" --output text 2>/dev/null || echo "")

  for role in $roles; do
    # Verify it's a loki-managed role
    local managed
    managed=$(aws iam list-role-tags --role-name "$role" \
      --query "Tags[?Key=='loki:managed'].Value" --output text 2>/dev/null || echo "")
    [[ "$managed" == "true" ]] || continue

    info "Cleaning up IAM role: ${role}"

    # Detach managed policies
    local policies
    policies=$(aws iam list-attached-role-policies --role-name "$role" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
    for policy in $policies; do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy" 2>/dev/null || true
    done

    # Delete inline policies
    local inline
    inline=$(aws iam list-role-policies --role-name "$role" \
      --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
    for p in $inline; do
      aws iam delete-role-policy --role-name "$role" --policy-name "$p" 2>/dev/null || true
    done

    # Remove from instance profiles
    local profiles
    profiles=$(aws iam list-instance-profiles-for-role --role-name "$role" \
      --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || echo "")
    for profile in $profiles; do
      aws iam remove-role-from-instance-profile --role-name "$role" --instance-profile-name "$profile" 2>/dev/null || true
      aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
    done

    aws iam delete-role --role-name "$role" 2>/dev/null || warn "Could not delete role ${role}"
  done

  # Find IAM users tagged with this watermark
  local users
  users=$(aws iam list-users --query "Users[?contains(UserName, '${watermark}')].UserName" --output text 2>/dev/null || echo "")

  for user in $users; do
    local managed_user
    managed_user=$(aws iam list-user-tags --user-name "$user" \
      --query "Tags[?Key=='loki:managed'].Value" --output text 2>/dev/null || echo "")
    [[ "$managed_user" == "true" ]] || continue

    info "Cleaning up IAM user: ${user}"

    # Delete access keys
    local keys
    keys=$(aws iam list-access-keys --user-name "$user" \
      --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || echo "")
    for key in $keys; do
      aws iam delete-access-key --user-name "$user" --access-key-id "$key" 2>/dev/null || true
    done

    # Detach policies
    local user_policies
    user_policies=$(aws iam list-attached-user-policies --user-name "$user" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
    for policy in $user_policies; do
      aws iam detach-user-policy --user-name "$user" --policy-arn "$policy" 2>/dev/null || true
    done

    aws iam delete-user --user-name "$user" 2>/dev/null || warn "Could not delete user ${user}"
  done
}

# ============================================================================
# Cleanup: optional S3/DynamoDB state resources
# ============================================================================
offer_state_cleanup() {
  echo ""
  info "Checking for leftover state resources..."

  local found_any=false
  # Collect unique resources to clean (avoid duplicates)
  local -a buckets_to_delete=()
  local -a tables_to_delete=()

  for i in "${TARGETS[@]}"; do
    local wm="${WATERMARKS[$i]}"

    # Use tagged TF state bucket if available, otherwise guess from watermark
    local tf_bucket="${TF_BUCKETS[$i]:-}"
    [[ -z "$tf_bucket" ]] && tf_bucket="${wm}-tfstate-${ACCOUNT_ID}"
    if aws s3api head-bucket --bucket "$tf_bucket" --region "$SCAN_REGION" 2>/dev/null; then
      found_any=true
      buckets_to_delete+=("$tf_bucket")
      echo -e "    Found Terraform state bucket: ${YELLOW}${tf_bucket}${NC}"
    fi

    # Use tagged lock table if available, otherwise guess
    local tf_lock="${TF_LOCKS[$i]:-}"
    [[ -z "$tf_lock" ]] && tf_lock="${wm}-tflock"
    if aws dynamodb describe-table --table-name "$tf_lock" --region "$SCAN_REGION" &>/dev/null; then
      found_any=true
      tables_to_delete+=("$tf_lock")
      echo -e "    Found Terraform lock table:   ${YELLOW}${tf_lock}${NC}"
    fi

    # CFN template bucket (from console deploy)
    local cfn_bucket="${wm}-cfn-templates-${ACCOUNT_ID}"
    if aws s3api head-bucket --bucket "$cfn_bucket" --region "$SCAN_REGION" 2>/dev/null; then
      found_any=true
      buckets_to_delete+=("$cfn_bucket")
      echo -e "    Found CFN template bucket:    ${YELLOW}${cfn_bucket}${NC}"
    fi
  done

  if ! $found_any; then
    ok "No leftover state resources found"
    return
  fi

  echo ""
  if confirm "Delete these state/template resources too?" ; then
    for bucket in "${buckets_to_delete[@]}"; do
      aws s3 rb "s3://${bucket}" --force --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete ${bucket}"
      ok "Deleted bucket: ${bucket}"
    done
    for table in "${tables_to_delete[@]}"; do
      aws dynamodb delete-table --table-name "$table" --region "$SCAN_REGION" >/dev/null 2>&1 || warn "Could not delete ${table}"
      ok "Deleted lock table: ${table}"
    done
  fi
}

# ============================================================================
# Done
# ============================================================================
show_done() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║     ✅ Loki deployment(s) removed            ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Removed ${#TARGETS[@]} deployment(s) from account ${ACCOUNT_ID} in ${SCAN_REGION}"
  echo ""
  echo -e "  ${BOLD}Note:${NC} Security services (GuardDuty, SecurityHub, Inspector, etc.)"
  echo "  were NOT disabled. Disable them manually if no longer needed:"
  echo "    AWS Console → each service → Settings → Disable"
  echo ""
}

# ============================================================================
# Main
# ============================================================================
main() {
  show_banner
  preflight
  discover_deployments
  select_targets
  confirm_destruction

  for i in "${TARGETS[@]}"; do
    remove_deployment "$i"
  done

  offer_state_cleanup
  show_done
}

main "$@"
