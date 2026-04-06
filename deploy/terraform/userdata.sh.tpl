#!/bin/bash
set -euo pipefail
export ACCT_ID="${acct_id}"
export REGION="${region}"
export DEFAULT_MODEL="${default_model}"
export BEDROCK_REGION="${bedrock_region}"
export GW_PORT="${gw_port}"
export MODEL_MODE="${model_mode}"
export LITELLM_BASE_URL="${litellm_base_url}"
export LITELLM_API_KEY="${litellm_api_key}"
export LITELLM_MODEL="${litellm_model}"
export PROVIDER_API_KEY="${provider_api_key}"
export PACK_NAME="${pack_name}"
export PROFILE_NAME="${profile_name}"

# Publish failure to SSM on any error so the installer can detect it
trap '
  aws ssm put-parameter --name "/loki/setup-status" \
    --value "FAILED" --type String --overwrite --region "$REGION" 2>/dev/null || true
  aws ssm put-parameter --name "/loki/setup-step" \
    --value "FAILED: userdata error at line $LINENO" \
    --type String --overwrite --region "$REGION" 2>/dev/null || true
  touch /tmp/loki-bootstrap-done
' ERR

# Ensure git is available (not present on all AMIs)
command -v git &>/dev/null || dnf install -y git 2>/dev/null || yum install -y git
# Clone repo with retry (GitHub blips shouldn't kill bootstrap)
_cloned=false
for _attempt in 1 2 3; do
  git clone --depth 1 -b "${repo_branch}" https://github.com/inceptionstack/loki-agent.git /tmp/loki-agent && _cloned=true && break
  echo "git clone failed (attempt $_attempt), retrying in 10s..." && sleep 10
done
if [[ "$_cloned" != "true" ]]; then
  echo "FATAL: git clone failed after 3 attempts" >&2
  exit 1
fi
bash /tmp/loki-agent/deploy/bootstrap.sh \
  --pack "$PACK_NAME" \
  --profile "$PROFILE_NAME" \
  --region "$BEDROCK_REGION" \
  --model "$DEFAULT_MODEL" \
  --gw-port "$GW_PORT" \
  --model-mode "$MODEL_MODE" \
  --litellm-base-url "$LITELLM_BASE_URL" \
  --litellm-api-key "$LITELLM_API_KEY" \
  --litellm-model "$LITELLM_MODEL" \
  --provider-api-key "$PROVIDER_API_KEY"
