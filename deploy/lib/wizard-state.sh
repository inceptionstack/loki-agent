#!/usr/bin/env bash

if [[ -n "${_LOKI_WIZARD_STATE_SH:-}" ]]; then
  return 0
fi
_LOKI_WIZARD_STATE_SH=1

declare -gA WIZARD_STATE=()

wizard_state_init() {
  WIZARD_STATE=(
    [installMode]="simple"
    [environmentName]=""
    [lastPackSelection]="openclaw"
    [pack]="openclaw"
    [profile]="builder"
    [provider]="bedrock"
    [providerAuthType]="iam"
    [providerRegion]="us-east-1"
    [providerKey]=""
    [providerKeySecretId]=""
    [providerBaseUrl]=""
    [primaryModelOverride]=""
    [fallbackModelOverride]=""
    [contextWindowOverride]=""
    [maxTokensOverride]=""
    [instanceType]=""
    [rootVolumeGb]=""
    [dataVolumeGb]=""
    [vpcMode]="new"
    [existingVpcId]=""
    [existingSubnetId]=""
    [sshAccessMode]="ssm-only"
    [keyPairName]=""
    [sshAllowedCidr]="127.0.0.1/32"
    [telegramToken]=""
    [allowedChatIds]=""
    [deployMethod]="cfn-cli"
    [repoBranch]="main"
    [gwPort]="3001"
    [bedrockifyPort]=""
    [hermesModel]=""
    [lokiWatermark]=""
    [enableBedrockForm]="false"
    [requestQuotaIncreases]="false"
    [enableSecurityHub]="true"
    [enableGuardDuty]="true"
    [enableInspector]="true"
    [enableAccessAnalyzer]="true"
    [enableConfigRecorder]="true"
    [generatedBootstrapCommand]=""
    [generatedCfnParams]=""
    [generatedTerraformVars]=""
    [deployResult]=""
  )
}

wizard_state_get() {
  local key="$1"
  printf '%s' "${WIZARD_STATE[$key]-}"
}

wizard_state_set() {
  local key="$1"
  local value="${2-}"
  WIZARD_STATE["$key"]="$value"
}

wizard_state_set_many() {
  local key
  while [[ $# -gt 1 ]]; do
    key="$1"
    shift
    WIZARD_STATE["$key"]="$1"
    shift
  done
}

wizard_state_json() {
  local json='{}'
  local key
  for key in "${!WIZARD_STATE[@]}"; do
    json="$(jq -c --arg k "${key}" --arg v "${WIZARD_STATE[$key]}" '. + {($k): $v}' <<<"${json}")"
  done
  jq -S . <<<"${json}"
}

wizard_state_apply_json() {
  local json="$1"
  local keys key value
  mapfile -t keys < <(jq -r 'keys[]' <<<"${json}")
  for key in "${keys[@]}"; do
    value="$(jq -r --arg k "${key}" '.[$k] // ""' <<<"${json}")"
    WIZARD_STATE["$key"]="${value}"
  done
}

wizard_state_export_json_file() {
  local path="$1"
  wizard_state_json >"${path}"
}
