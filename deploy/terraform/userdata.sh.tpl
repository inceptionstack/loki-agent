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
# Clone repo with retry (GitHub blips shouldn't kill bootstrap)
for _attempt in 1 2 3; do
  git clone --depth 1 https://github.com/inceptionstack/loki-agent.git /tmp/loki-agent && break
  echo "git clone failed (attempt $_attempt), retrying in 10s..." && sleep 10
done
bash /tmp/loki-agent/deploy/bootstrap.sh \
  --pack "$PACK_NAME" \
  --region "$BEDROCK_REGION" \
  --model "$DEFAULT_MODEL" \
  --gw-port "$GW_PORT" \
  --model-mode "$MODEL_MODE" \
  --litellm-base-url "$LITELLM_BASE_URL" \
  --litellm-api-key "$LITELLM_API_KEY" \
  --litellm-model "$LITELLM_MODEL" \
  --provider-api-key "$PROVIDER_API_KEY"
