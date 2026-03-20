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
# Download and run bootstrap
curl -sfL ${bootstrap_url} -o /tmp/openclaw-bootstrap.sh
chmod +x /tmp/openclaw-bootstrap.sh
bash /tmp/openclaw-bootstrap.sh
