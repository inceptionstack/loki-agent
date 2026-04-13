#!/usr/bin/env bash

if [[ -n "${_LOKI_WIZARD_VALIDATE_SH:-}" ]]; then
  return 0
fi
_LOKI_WIZARD_VALIDATE_SH=1

wizard_validate_api_key() {
  local provider="$1"
  local key="$2"
  case "${provider}" in
    anthropic-api)
      [[ -n "${key}" ]] || { echo "Anthropic API key is required"; return 1; }
      [[ "${key}" == sk-ant-* || "${key}" == sk-ant-api* ]] || {
        echo "Anthropic API key must start with sk-ant-"
        return 1
      }
      ;;
    openai-api)
      [[ -n "${key}" ]] || { echo "OpenAI API key is required"; return 1; }
      [[ "${key}" == sk-* ]] || {
        echo "OpenAI API key must start with sk-"
        return 1
      }
      ;;
    openrouter)
      [[ -n "${key}" ]] || { echo "OpenRouter API key is required"; return 1; }
      [[ ${#key} -gt 10 ]] || {
        echo "OpenRouter API key looks too short"
        return 1
      }
      ;;
    bedrock)
      local auth_type="${3:-}"
      if [[ "${auth_type}" == "bearer" ]]; then
        [[ -n "${key}" ]] || { echo "Bedrock bearer token is required"; return 1; }
        [[ "${key}" == ABS-* ]] || {
          echo "Bedrock bearer token should start with ABS-"
          return 1
        }
      fi
      ;;
  esac
}

wizard_validate_url() {
  local url="$1"
  [[ -n "${url}" ]] || { echo "Base URL is required"; return 1; }
  [[ "${url}" =~ ^https?://[^[:space:]]+$ ]] || {
    echo "Base URL must start with http:// or https://"
    return 1
  }
}

wizard_validate_pack_provider() {
  local pack="$1"
  local provider="$2"
  wizard_pack_provider_supported "${pack}" "${provider}" || {
    jq -r '.reason' <<<"$(wizard_pack_provider_status_json "${pack}" "${provider}")"
    return 1
  }
}

wizard_validate_pack_profile() {
  local pack="$1"
  local profile="$2"
  if [[ "${pack}" == "nemoclaw" && "${profile}" != "personal_assistant" ]]; then
    echo "NemoClaw only supports the personal_assistant profile"
    return 1
  fi
  local compatible
  compatible="$(jq -r --arg p "${pack}" '.[$p].compatible_profiles // empty | .[]?' <<<"${WIZARD_PACKS_JSON}")"
  if [[ -n "${compatible}" ]] && ! grep -qx "${profile}" <<<"${compatible}"; then
    echo "Selected profile is not supported by ${pack}"
    return 1
  fi
}

wizard_validate_region() {
  local provider="$1"
  local region="$2"
  if [[ "$(wizard_provider_region_required "${provider}")" != "true" ]]; then
    return 0
  fi
  [[ -n "${region}" ]] || { echo "Region is required"; return 1; }
  grep -qx "${region}" < <(wizard_bedrock_regions) || {
    echo "Region must be one of the supported Bedrock regions"
    return 1
  }
}

wizard_validate_model_override() {
  local provider="$1"
  local model_id="$2"
  [[ -z "${model_id}" ]] && return 0
  grep -qx "${model_id}" < <(wizard_provider_model_ids "${provider}") || return 2
}

wizard_validate_positive_int() {
  local value="$1"
  local label="$2"
  [[ -z "${value}" ]] && return 0
  [[ "${value}" =~ ^[0-9]+$ ]] || {
    echo "${label} must be a positive integer"
    return 1
  }
  (( value > 0 )) || {
    echo "${label} must be a positive integer"
    return 1
  }
}

wizard_validate_instance_type() {
  local pack="$1"
  local instance_type="$2"
  [[ "${instance_type}" =~ ^(t4g|m7g|c7g)\. ]] || {
    echo "Instance type must be an ARM64 Graviton family"
    return 1
  }
  if [[ "${pack}" == "nemoclaw" ]]; then
    case "${instance_type}" in
      t4g.xlarge|t4g.2xlarge|m7g.xlarge|c7g.xlarge) ;;
      *)
        echo "NemoClaw requires at least t4g.xlarge"
        return 1
        ;;
    esac
  fi
}

wizard_validate_volume_size() {
  local value="$1"
  local min="$2"
  local max="$3"
  local allow_zero="$4"
  local label="$5"
  [[ "${value}" =~ ^[0-9]+$ ]] || {
    echo "${label} must be an integer"
    return 1
  }
  if [[ "${allow_zero}" == "true" && "${value}" == "0" ]]; then
    return 0
  fi
  (( value >= min && value <= max )) || {
    echo "${label} must be between ${min} and ${max}"
    return 1
  }
}

wizard_validate_chat_ids() {
  local value="$1"
  [[ -z "${value}" ]] && return 0
  [[ "${value}" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || {
    echo "Allowed chat IDs must be comma-separated integers"
    return 1
  }
}

wizard_validate_telegram_token() {
  local value="$1"
  [[ -z "${value}" ]] && return 0
  [[ "${value}" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{20,}$ ]] || {
    echo "Telegram token format is invalid"
    return 1
  }
}

wizard_validate_environment_name() {
  local value="$1"
  [[ -n "${value}" ]] || { echo "Environment name is required"; return 1; }
  [[ "${value}" =~ ^[a-z0-9-]+$ ]] || {
    echo "Environment name must use lowercase letters, numbers, and hyphens"
    return 1
  }
}

wizard_validate_review_state() {
  local state_json="$1"
  local pack profile provider auth region key base_url env_name gw_port vpc_mode existing_vpc_id existing_subnet_id
  pack="$(jq -r '.pack // ""' <<<"${state_json}")"
  profile="$(jq -r '.profile // ""' <<<"${state_json}")"
  provider="$(jq -r '.provider // ""' <<<"${state_json}")"
  auth="$(jq -r '.providerAuthType // ""' <<<"${state_json}")"
  region="$(jq -r '.providerRegion // ""' <<<"${state_json}")"
  key="$(jq -r '.providerKey // ""' <<<"${state_json}")"
  base_url="$(jq -r '.providerBaseUrl // ""' <<<"${state_json}")"
  env_name="$(jq -r '.environmentName // ""' <<<"${state_json}")"
  gw_port="$(jq -r '.gwPort // ""' <<<"${state_json}")"
  vpc_mode="$(jq -r '.vpcMode // ""' <<<"${state_json}")"
  existing_vpc_id="$(jq -r '.existingVpcId // ""' <<<"${state_json}")"
  existing_subnet_id="$(jq -r '.existingSubnetId // ""' <<<"${state_json}")"

  wizard_validate_environment_name "${env_name}" || return 1
  wizard_validate_positive_int "${gw_port}" "Gateway port" || return 1
  if [[ "${vpc_mode}" == "existing" ]]; then
    [[ -n "${existing_vpc_id}" && -n "${existing_subnet_id}" ]] || {
      printf 'Existing VPC mode requires both Existing VPC ID and Existing Subnet ID.\n' >&2
      return 1
    }
  fi
  wizard_validate_pack_profile "${pack}" "${profile}" || return 1
  if [[ "${provider}" != "own-cloud" ]]; then
    wizard_validate_pack_provider "${pack}" "${provider}" || return 1
    wizard_validate_region "${provider}" "${region}" || return 1
  fi
  case "${provider}" in
    anthropic-api|openai-api|openrouter)
      wizard_validate_api_key "${provider}" "${key}" "${auth}" || return 1
      ;;
    bedrock)
      wizard_validate_api_key "${provider}" "${key}" "${auth}" || return 1
      ;;
    litellm)
      wizard_validate_url "${base_url}" || return 1
      ;;
  esac
}
