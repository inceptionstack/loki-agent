#!/usr/bin/env bash

if [[ -n "${_LOKI_WIZARD_COMMAND_SH:-}" ]]; then
  return 0
fi
_LOKI_WIZARD_COMMAND_SH=1

wizard_shell_quote() {
  printf '%q' "$1"
}

wizard_bool_to_cfn() {
  [[ "$1" == "true" ]] && printf 'true' || printf 'false'
}

build_bootstrap_command() {
  local -n state_ref="$1"
  local cmd=()
  cmd+=(bash deploy/bootstrap.sh)
  cmd+=(--pack "$(wizard_shell_quote "${state_ref[pack]}")")
  [[ -n "${state_ref[profile]}" ]] && cmd+=(--profile "$(wizard_shell_quote "${state_ref[profile]}")")
  [[ -n "${state_ref[provider]}" && "${state_ref[provider]}" != "own-cloud" ]] && \
    cmd+=(--provider "$(wizard_shell_quote "${state_ref[provider]}")")
  [[ "${state_ref[provider]}" == "bedrock" && -n "${state_ref[providerAuthType]}" ]] && \
    cmd+=(--provider-auth-type "$(wizard_shell_quote "${state_ref[providerAuthType]}")")
  [[ -n "${state_ref[providerRegion]}" ]] && cmd+=(--region "$(wizard_shell_quote "${state_ref[providerRegion]}")")
  [[ -n "${state_ref[primaryModelOverride]}" ]] && cmd+=(--model "$(wizard_shell_quote "${state_ref[primaryModelOverride]}")")
  [[ -n "${state_ref[providerKey]}" ]] && cmd+=(--provider-key "$(wizard_shell_quote "${state_ref[providerKey]}")")
  [[ -n "${state_ref[providerKeySecretId]}" ]] && cmd+=(--provider-key-secret-id "$(wizard_shell_quote "${state_ref[providerKeySecretId]}")")
  [[ -n "${state_ref[providerBaseUrl]}" ]] && cmd+=(--provider-base-url "$(wizard_shell_quote "${state_ref[providerBaseUrl]}")")
  if [[ "${state_ref[provider]}" == "litellm" && -n "${state_ref[providerBaseUrl]}" ]]; then
    cmd+=(--litellm-base-url "$(wizard_shell_quote "${state_ref[providerBaseUrl]}")")
  fi
  [[ -n "${state_ref[repoBranch]}" ]] && cmd+=(--repo-branch "$(wizard_shell_quote "${state_ref[repoBranch]}")")
  [[ -n "${state_ref[gwPort]}" ]] && cmd+=(--gw-port "$(wizard_shell_quote "${state_ref[gwPort]}")")
  [[ -n "${state_ref[bedrockifyPort]}" ]] && cmd+=(--bedrockify-port "$(wizard_shell_quote "${state_ref[bedrockifyPort]}")")
  [[ -n "${state_ref[hermesModel]}" ]] && cmd+=(--hermes-model "$(wizard_shell_quote "${state_ref[hermesModel]}")")
  [[ -n "${state_ref[existingVpcId]}" ]] && cmd+=(--existing-vpc-id "$(wizard_shell_quote "${state_ref[existingVpcId]}")")
  [[ -n "${state_ref[existingSubnetId]}" ]] && cmd+=(--existing-subnet-id "$(wizard_shell_quote "${state_ref[existingSubnetId]}")")
  local out=""
  local part
  for part in "${cmd[@]}"; do
    [[ -n "${out}" ]] && out+=" "
    out+="${part}"
  done
  printf '%s\n' "${out}"
}

build_cfn_params() {
  local -n state_ref="$1"
  jq -n \
    --arg EnvironmentName "${state_ref[environmentName]}" \
    --arg PackName "${state_ref[pack]}" \
    --arg ProfileName "${state_ref[profile]}" \
    --arg InstanceType "${state_ref[instanceType]}" \
    --arg RootVolumeSize "${state_ref[rootVolumeGb]}" \
    --arg DataVolumeSize "${state_ref[dataVolumeGb]}" \
    --arg KeyPairName "${state_ref[keyPairName]}" \
    --arg BedrockRegion "${state_ref[providerRegion]}" \
    --arg DefaultModel "${state_ref[primaryModelOverride]}" \
    --arg ProviderName "${state_ref[provider]}" \
    --arg ProviderAuthType "${state_ref[providerAuthType]}" \
    --arg ProviderApiKey "${state_ref[providerKey]}" \
    --arg ProviderApiKeySecretArn "${state_ref[providerKeySecretId]}" \
    --arg LiteLLMBaseUrl "${state_ref[providerBaseUrl]}" \
    --arg ExistingVpcId "${state_ref[existingVpcId]}" \
    --arg ExistingSubnetId "${state_ref[existingSubnetId]}" \
    --arg SSHAllowedCidr "${state_ref[sshAllowedCidr]}" \
    --arg RepoBranch "${state_ref[repoBranch]}" \
    --arg OpenClawGatewayPort "${state_ref[gwPort]}" \
    --arg LokiWatermark "${state_ref[lokiWatermark]}" \
    --arg EnableBedrockForm "$(wizard_bool_to_cfn "${state_ref[enableBedrockForm]}")" \
    --arg RequestQuotaIncreases "$(wizard_bool_to_cfn "${state_ref[requestQuotaIncreases]}")" \
    --arg EnableSecurityHub "$(wizard_bool_to_cfn "${state_ref[enableSecurityHub]}")" \
    --arg EnableGuardDuty "$(wizard_bool_to_cfn "${state_ref[enableGuardDuty]}")" \
    --arg EnableInspector "$(wizard_bool_to_cfn "${state_ref[enableInspector]}")" \
    --arg EnableAccessAnalyzer "$(wizard_bool_to_cfn "${state_ref[enableAccessAnalyzer]}")" \
    --arg EnableConfigRecorder "$(wizard_bool_to_cfn "${state_ref[enableConfigRecorder]}")" \
    '{
      EnvironmentName: $EnvironmentName,
      PackName: $PackName,
      ProfileName: $ProfileName,
      InstanceType: $InstanceType,
      RootVolumeSize: $RootVolumeSize,
      DataVolumeSize: $DataVolumeSize,
      KeyPairName: $KeyPairName,
      BedrockRegion: $BedrockRegion,
      DefaultModel: $DefaultModel,
      ProviderName: $ProviderName,
      ProviderAuthType: $ProviderAuthType,
      ProviderApiKey: $ProviderApiKey,
      ProviderApiKeySecretArn: $ProviderApiKeySecretArn,
      LiteLLMBaseUrl: $LiteLLMBaseUrl,
      ExistingVpcId: $ExistingVpcId,
      ExistingSubnetId: $ExistingSubnetId,
      SSHAllowedCidr: $SSHAllowedCidr,
      RepoBranch: $RepoBranch,
      OpenClawGatewayPort: $OpenClawGatewayPort,
      LokiWatermark: $LokiWatermark,
      EnableBedrockForm: $EnableBedrockForm,
      RequestQuotaIncreases: $RequestQuotaIncreases,
      EnableSecurityHub: $EnableSecurityHub,
      EnableGuardDuty: $EnableGuardDuty,
      EnableInspector: $EnableInspector,
      EnableAccessAnalyzer: $EnableAccessAnalyzer,
      EnableConfigRecorder: $EnableConfigRecorder
    }'
}

build_terraform_vars() {
  local -n state_ref="$1"
  jq -n \
    --arg environment_name "${state_ref[environmentName]}" \
    --arg pack_name "${state_ref[pack]}" \
    --arg profile_name "${state_ref[profile]}" \
    --arg instance_type "${state_ref[instanceType]}" \
    --arg root_volume_size "${state_ref[rootVolumeGb]}" \
    --arg data_volume_size "${state_ref[dataVolumeGb]}" \
    --arg key_pair_name "${state_ref[keyPairName]}" \
    --arg bedrock_region "${state_ref[providerRegion]}" \
    --arg default_model "${state_ref[primaryModelOverride]}" \
    --arg provider_name "${state_ref[provider]}" \
    --arg provider_auth_type "${state_ref[providerAuthType]}" \
    --arg provider_api_key "${state_ref[providerKey]}" \
    --arg provider_api_key_secret_arn "${state_ref[providerKeySecretId]}" \
    --arg provider_base_url "${state_ref[providerBaseUrl]}" \
    --arg litellm_base_url "${state_ref[providerBaseUrl]}" \
    --arg existing_vpc_id "${state_ref[existingVpcId]}" \
    --arg existing_subnet_id "${state_ref[existingSubnetId]}" \
    --arg ssh_allowed_cidr "${state_ref[sshAllowedCidr]}" \
    --arg repo_branch "${state_ref[repoBranch]}" \
    --arg openclaw_gateway_port "${state_ref[gwPort]}" \
    --arg loki_watermark "${state_ref[lokiWatermark]}" \
    --arg enable_bedrock_form "$(wizard_bool_to_cfn "${state_ref[enableBedrockForm]}")" \
    --arg request_quota_increases "$(wizard_bool_to_cfn "${state_ref[requestQuotaIncreases]}")" \
    --argjson enable_security_hub "$( [[ "${state_ref[enableSecurityHub]}" == "true" ]] && echo true || echo false )" \
    --argjson enable_guardduty "$( [[ "${state_ref[enableGuardDuty]}" == "true" ]] && echo true || echo false )" \
    --argjson enable_inspector "$( [[ "${state_ref[enableInspector]}" == "true" ]] && echo true || echo false )" \
    --argjson enable_access_analyzer "$( [[ "${state_ref[enableAccessAnalyzer]}" == "true" ]] && echo true || echo false )" \
    --argjson enable_config_recorder "$( [[ "${state_ref[enableConfigRecorder]}" == "true" ]] && echo true || echo false )" \
    '{
      environment_name: $environment_name,
      pack_name: $pack_name,
      profile_name: $profile_name,
      instance_type: $instance_type,
      root_volume_size: $root_volume_size,
      data_volume_size: $data_volume_size,
      key_pair_name: $key_pair_name,
      bedrock_region: $bedrock_region,
      default_model: $default_model,
      provider_name: $provider_name,
      provider_auth_type: $provider_auth_type,
      provider_api_key: $provider_api_key,
      provider_api_key_secret_arn: $provider_api_key_secret_arn,
      provider_base_url: $provider_base_url,
      litellm_base_url: $litellm_base_url,
      existing_vpc_id: $existing_vpc_id,
      existing_subnet_id: $existing_subnet_id,
      ssh_allowed_cidr: $ssh_allowed_cidr,
      repo_branch: $repo_branch,
      openclaw_gateway_port: $openclaw_gateway_port,
      loki_watermark: $loki_watermark,
      enable_bedrock_form: $enable_bedrock_form,
      request_quota_increases: $request_quota_increases,
      enable_security_hub: $enable_security_hub,
      enable_guardduty: $enable_guardduty,
      enable_inspector: $enable_inspector,
      enable_access_analyzer: $enable_access_analyzer,
      enable_config_recorder: $enable_config_recorder
    }'
}
