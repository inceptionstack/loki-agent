#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash. Run with: bash $0" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export AWS_PAGER=""
export PAGER=""

# shellcheck source=deploy/lib/wizard-ui.sh
source "${SCRIPT_DIR}/lib/wizard-ui.sh"
# shellcheck source=deploy/lib/wizard-data.sh
source "${SCRIPT_DIR}/lib/wizard-data.sh"
# shellcheck source=deploy/lib/wizard-state.sh
source "${SCRIPT_DIR}/lib/wizard-state.sh"
# shellcheck source=deploy/lib/wizard-validate.sh
source "${SCRIPT_DIR}/lib/wizard-validate.sh"
# shellcheck source=deploy/lib/wizard-command.sh
source "${SCRIPT_DIR}/lib/wizard-command.sh"

GUM_VERSION_REQUIRED="0.17.0"
GUM="${GUM:-}"
DRY_RUN=false
NON_INTERACTIVE=false
SCENARIO=""

cleanup_on_interrupt() {
  printf '\n'
  if [[ -n "${PARTIAL_COMMAND:-}" ]]; then
    echo "Interrupted. Partial command:"
    echo "${PARTIAL_COMMAND}"
  else
    echo "Interrupted."
  fi
  exit 130
}
trap cleanup_on_interrupt INT TERM

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

detect_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="Darwin" ;;
    Linux) os="Linux" ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  printf '%s %s\n' "${os}" "${arch}"
}

ensure_gum() {
  local version current os arch url tmpdir
  if command -v gum >/dev/null 2>&1; then
    current="$(gum --version 2>/dev/null | sed 's/^v//')"
    if [[ "${current}" == "${GUM_VERSION_REQUIRED}" ]]; then
      GUM="gum"
      return 0
    fi
  fi

  tmpdir="/tmp/loki-gum-${GUM_VERSION_REQUIRED}"
  if [[ -x "${tmpdir}/gum" ]]; then
    current="$("${tmpdir}/gum" --version 2>/dev/null | sed 's/^v//')"
    if [[ "${current}" == "${GUM_VERSION_REQUIRED}" ]]; then
      GUM="${tmpdir}/gum"
      return 0
    fi
  fi

  require_tool curl
  require_tool tar
  read -r os arch < <(detect_platform)
  url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION_REQUIRED}/gum_${GUM_VERSION_REQUIRED}_${os}_${arch}.tar.gz"
  mkdir -p "${tmpdir}"
  echo "Installing gum v${GUM_VERSION_REQUIRED}..."
  curl -fsSL "${url}" | tar -xz -C "${tmpdir}"
  chmod +x "${tmpdir}/gum"
  version="$("${tmpdir}/gum" --version 2>/dev/null | sed 's/^v//')"
  [[ "${version}" == "${GUM_VERSION_REQUIRED}" ]] || die "Failed to install gum v${GUM_VERSION_REQUIRED}"
  GUM="${tmpdir}/gum"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --non-interactive|-y) NON_INTERACTIVE=true; shift ;;
      --scenario)
        [[ $# -gt 1 ]] || die "--scenario requires a value"
        SCENARIO="$2"
        shift 2
        ;;
      --help|-h)
        cat <<EOF
Usage: deploy/wizard.sh [OPTIONS]

Options:
  --dry-run               Print final state and generated commands without deploying
  --non-interactive, -y   Accept default selections
  --scenario <name>       Apply a canned dry-run scenario
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

set_pack_defaults() {
  local pack="${WIZARD_STATE[pack]}"
  local previous_pack instance root data gw
  previous_pack="${WIZARD_STATE[lastPackSelection]}"
  instance="$(wizard_pack_default_field "${pack}" instance_type)"
  root="$(wizard_pack_default_field "${pack}" root_volume_gb)"
  data="$(wizard_pack_default_field "${pack}" data_volume_gb)"
  gw="$(jq -r --arg p "${pack}" '.[$p].ports.gateway // ""' <<<"${WIZARD_PACKS_JSON}")"
  [[ -z "${instance}" ]] && instance="$(wizard_global_default_field instance_type)"
  [[ -z "${root}" ]] && root="$(wizard_global_default_field root_volume_gb)"
  [[ -z "${data}" ]] && data="$(wizard_global_default_field data_volume_gb)"
  [[ -z "${gw}" ]] && gw="3001"
  [[ -z "${WIZARD_STATE[environmentName]}" || "${WIZARD_STATE[environmentName]}" == "${previous_pack}" ]] && \
    WIZARD_STATE[environmentName]="${pack}"
  WIZARD_STATE[lastPackSelection]="${pack}"
  WIZARD_STATE[lokiWatermark]="${WIZARD_STATE[environmentName]}"
  WIZARD_STATE[instanceType]="${instance}"
  WIZARD_STATE[rootVolumeGb]="${root}"
  WIZARD_STATE[dataVolumeGb]="${data}"
  WIZARD_STATE[gwPort]="${gw}"
}

set_provider_defaults() {
  local provider="${WIZARD_STATE[provider]}"
  [[ -z "${provider}" || "${provider}" == "own-cloud" ]] && return 0
  WIZARD_STATE[providerAuthType]="$(wizard_provider_default_mode "${provider}")"
  if [[ "$(wizard_provider_region_required "${provider}")" == "true" ]]; then
    WIZARD_STATE[providerRegion]="$(wizard_global_default_field bedrock_region)"
  else
    WIZARD_STATE[providerRegion]=""
  fi
  WIZARD_STATE[providerBaseUrl]=""
  case "${provider}" in
    litellm)
      WIZARD_STATE[providerBaseUrl]=""
      ;;
    openrouter|openai-api)
      WIZARD_STATE[providerBaseUrl]="$(jq -r --arg p "${provider}" '.[$p].connection.baseUrlTemplate // ""' <<<"${WIZARD_PROVIDERS_JSON}")"
      ;;
  esac
}

apply_profile_defaults() {
  case "${WIZARD_STATE[profile]}" in
    personal_assistant)
      WIZARD_STATE[enableSecurityHub]="false"
      WIZARD_STATE[enableGuardDuty]="false"
      WIZARD_STATE[enableInspector]="false"
      WIZARD_STATE[enableAccessAnalyzer]="false"
      WIZARD_STATE[enableConfigRecorder]="false"
      ;;
    *)
      WIZARD_STATE[enableSecurityHub]="true"
      WIZARD_STATE[enableGuardDuty]="true"
      WIZARD_STATE[enableInspector]="true"
      WIZARD_STATE[enableAccessAnalyzer]="true"
      WIZARD_STATE[enableConfigRecorder]="true"
      ;;
  esac
}

select_install_mode() {
  wizard_ui_set_step 0 7
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    WIZARD_STATE[installMode]="simple"
    return 0
  fi
  local choice
  choice="$(wizard_choose \
    "Install Mode" \
    "How much do you want to configure?" \
    "${WIZARD_STATE[installMode]}" \
    "simple" \
    "advanced")"
  WIZARD_STATE[installMode]="${choice}"
}

select_pack() {
  wizard_ui_set_step 1 7
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    WIZARD_STATE[pack]="openclaw"
    set_pack_defaults
    return 0
  fi
  local options=()
  local pack desc providers line
  while IFS= read -r pack; do
    desc="$(wizard_pack_default_field "${pack}" description)"
    providers="$(jq -r --arg p "${pack}" '.[$p].supported_providers // [] | join("  ")' <<<"${WIZARD_PACKS_JSON}")"
    line="${pack} — ${desc} [${providers}]"
    options+=("${line}")
  done < <(wizard_pack_ids)
  options+=("BACK")
  local choice
  choice="$(wizard_choose "Choose Agent Pack" "Select the AI agent to deploy." "" "${options[@]}")"
  [[ "${choice}" == "BACK" ]] && return 1
  WIZARD_STATE[pack]="${choice%% — *}"
  set_pack_defaults
}

select_environment_name() {
  local total_steps=7
  [[ "${WIZARD_STATE[installMode]}" == "advanced" ]] && total_steps=12
  wizard_ui_set_step 2 "${total_steps}"
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    [[ -n "${WIZARD_STATE[environmentName]}" ]] || WIZARD_STATE[environmentName]="${WIZARD_STATE[pack]}"
    return 0
  fi

  local value
  while true; do
    value="$(wizard_input \
      "Environment Name" \
      "Used as the AWS resource prefix." \
      "${WIZARD_STATE[environmentName]}" \
      "${WIZARD_STATE[pack]}" \
      false)" || return 1
    value="${value:-${WIZARD_STATE[pack]}}"
    if ! wizard_validate_environment_name "${value}" >/tmp/loki-wizard.err 2>&1; then
      wizard_error "$(cat /tmp/loki-wizard.err)"
      continue
    fi
    WIZARD_STATE[environmentName]="${value}"
    WIZARD_STATE[lokiWatermark]="${value}"
    return 0
  done
}

select_profile() {
  local total_steps=7
  [[ "${WIZARD_STATE[installMode]}" == "advanced" ]] && total_steps=12
  wizard_ui_set_step 3 "${total_steps}"
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    WIZARD_STATE[profile]="builder"
    apply_profile_defaults
    return 0
  fi
  local opts=(
    "builder — Full AWS admin access"
    "account_assistant — Read-only AWS access"
    "personal_assistant — Bedrock only"
    "BACK"
  )
  local choice profile
  while true; do
    choice="$(wizard_choose "Choose Permission Profile" "What level of AWS access should the agent have?" "" "${opts[@]}")"
    [[ "${choice}" == "BACK" ]] && return 1
    profile="${choice%% — *}"
    if ! wizard_validate_pack_profile "${WIZARD_STATE[pack]}" "${profile}" >/tmp/loki-wizard.err 2>&1; then
      wizard_error "$(cat /tmp/loki-wizard.err)"
      continue
    fi
    WIZARD_STATE[profile]="${profile}"
    apply_profile_defaults
    return 0
  done
}

enabled_provider_ids_for_pack() {
  local pack="$1"
  local provider
  for provider in bedrock anthropic-api openai-api openrouter litellm; do
    if wizard_pack_provider_supported "${pack}" "${provider}"; then
      printf '%s\n' "${provider}"
    fi
  done
}

select_provider() {
  local total_steps=7
  [[ "${WIZARD_STATE[installMode]}" == "advanced" ]] && total_steps=12
  wizard_ui_set_step 4 "${total_steps}"
  if [[ "${WIZARD_STATE[pack]}" == "kiro-cli" ]]; then
    WIZARD_STATE[provider]="own-cloud"
    WIZARD_STATE[providerAuthType]=""
    WIZARD_STATE[providerRegion]=""
    return 0
  fi

  local -a supported
  mapfile -t supported < <(enabled_provider_ids_for_pack "${WIZARD_STATE[pack]}")
  if [[ ${#supported[@]} -eq 1 ]]; then
    WIZARD_STATE[provider]="${supported[0]}"
    set_provider_defaults
    return 0
  fi

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    WIZARD_STATE[provider]="bedrock"
    set_provider_defaults
    return 0
  fi

  local options=() provider status reason display line choice
  for provider in bedrock anthropic-api openai-api openrouter litellm; do
    status="$(wizard_pack_provider_status_json "${WIZARD_STATE[pack]}" "${provider}")"
    display="$(wizard_provider_display_name "${provider}")"
    if jq -e '.supported == true' <<<"${status}" >/dev/null; then
      line="${provider} — ${display}"
    else
      reason="$(jq -r '.reason' <<<"${status}")"
      line="${provider} — ${display} [disabled: ${reason}]"
    fi
    options+=("${line}")
  done
  options+=("BACK")

  while true; do
    choice="$(wizard_choose "Choose LLM Provider" "How should the agent connect to AI models?" "" "${options[@]}")"
    [[ "${choice}" == "BACK" ]] && return 1
    provider="${choice%% — *}"
    if ! wizard_validate_pack_provider "${WIZARD_STATE[pack]}" "${provider}" >/tmp/loki-wizard.err 2>&1; then
      wizard_error "$(cat /tmp/loki-wizard.err)"
      continue
    fi
    WIZARD_STATE[provider]="${provider}"
    set_provider_defaults
    return 0
  done
}

configure_provider_screen() {
  local title="$1"
  local subtitle="$2"
  shift 2
  local choice
  choice="$(wizard_choose "${title}" "${subtitle}" "" "$@" "NEXT" "BACK")"
  case "${choice}" in
    BACK) return 1 ;;
    *)
      printf '%s\n' "${choice}"
      return 0
      ;;
  esac
}

configure_provider() {
  local total_steps=7
  [[ "${WIZARD_STATE[installMode]}" == "advanced" ]] && total_steps=12
  wizard_ui_set_step 5 "${total_steps}"
  local provider="${WIZARD_STATE[provider]}"
  [[ "${provider}" == "own-cloud" ]] && return 0

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    case "${provider}" in
      bedrock) WIZARD_STATE[providerAuthType]="iam" ;;
      anthropic-api) WIZARD_STATE[providerKey]="sk-ant-test-key" ;;
      openai-api) WIZARD_STATE[providerKey]="sk-test-key" ;;
      openrouter) WIZARD_STATE[providerKey]="or-test-key-12345" ;;
      litellm) WIZARD_STATE[providerBaseUrl]="https://litellm.example.com" ;;
    esac
    return 0
  fi

  local action value
  while true; do
    case "${provider}" in
      bedrock)
        action="$(configure_provider_screen \
          "Configure AWS Bedrock" \
          "Auth: ${WIZARD_STATE[providerAuthType]:-iam} • Region: ${WIZARD_STATE[providerRegion]:-unset} • Model: ${WIZARD_STATE[primaryModelOverride]:-(provider default)}" \
          "Authentication Mode" \
          "Region" \
          "Bearer Token" \
          "Primary Model Override")" || return 1
        ;;
      anthropic-api)
        action="$(configure_provider_screen \
          "Configure Anthropic API" \
          "Key: $(wizard_mask_secret "${WIZARD_STATE[providerKey]}" 7) • Model: ${WIZARD_STATE[primaryModelOverride]:-(provider default)}" \
          "API Key" \
          "Primary Model Override")" || return 1
        ;;
      openai-api)
        action="$(configure_provider_screen \
          "Configure OpenAI API" \
          "Key: $(wizard_mask_secret "${WIZARD_STATE[providerKey]}" 3) • Model: ${WIZARD_STATE[primaryModelOverride]:-(provider default)}" \
          "API Key" \
          "Primary Model Override")" || return 1
        ;;
      openrouter)
        action="$(configure_provider_screen \
          "Configure OpenRouter" \
          "Key: $(wizard_mask_secret "${WIZARD_STATE[providerKey]}" 3) • Model: ${WIZARD_STATE[primaryModelOverride]:-(provider default)}" \
          "API Key" \
          "Primary Model Override")" || return 1
        ;;
      litellm)
        action="$(configure_provider_screen \
          "Configure LiteLLM" \
          "Base URL: ${WIZARD_STATE[providerBaseUrl]:-unset} • Key: $(wizard_mask_secret "${WIZARD_STATE[providerKey]}" 3) • Model: ${WIZARD_STATE[primaryModelOverride]:-(provider default)}" \
          "Base URL" \
          "API Key" \
          "Primary Model Override")" || return 1
        ;;
    esac

    case "${action}" in
      NEXT)
        case "${provider}" in
          bedrock)
            wizard_validate_region "${provider}" "${WIZARD_STATE[providerRegion]}" >/tmp/loki-wizard.err 2>&1 || {
              wizard_error "$(cat /tmp/loki-wizard.err)"
              continue
            }
            if [[ "${WIZARD_STATE[providerAuthType]}" == "bearer" ]]; then
              wizard_validate_api_key bedrock "${WIZARD_STATE[providerKey]}" bearer >/tmp/loki-wizard.err 2>&1 || {
                wizard_error "$(cat /tmp/loki-wizard.err)"
                continue
              }
            fi
            ;;
          anthropic-api|openai-api|openrouter)
            wizard_validate_api_key "${provider}" "${WIZARD_STATE[providerKey]}" >/tmp/loki-wizard.err 2>&1 || {
              wizard_error "$(cat /tmp/loki-wizard.err)"
              continue
            }
            ;;
          litellm)
            wizard_validate_url "${WIZARD_STATE[providerBaseUrl]}" >/tmp/loki-wizard.err 2>&1 || {
              wizard_error "$(cat /tmp/loki-wizard.err)"
              continue
            }
            ;;
        esac
        return 0
        ;;
      "Authentication Mode")
        value="$(wizard_choose "Bedrock Authentication" "Choose how Bedrock will authenticate." "${WIZARD_STATE[providerAuthType]}" "iam" "bearer" "BACK")"
        [[ "${value}" == "BACK" ]] || WIZARD_STATE[providerAuthType]="${value}"
        ;;
      Region)
        value="$(wizard_choose "Bedrock Region" "Select the AWS region for model inference." "${WIZARD_STATE[providerRegion]}" $(wizard_bedrock_regions) "BACK")"
        [[ "${value}" == "BACK" ]] || WIZARD_STATE[providerRegion]="${value}"
        ;;
      "Bearer Token")
        if [[ "${provider}" == "bedrock" && "${WIZARD_STATE[providerAuthType]}" != "bearer" ]]; then
          wizard_warning "Switch authentication mode to bearer before entering a token."
        else
          value="$(wizard_input "Bearer Token" "ABS- token for Bedrock bearer auth." "${WIZARD_STATE[providerKey]}" "ABS-..." true)" || true
          WIZARD_STATE[providerKey]="${value:-${WIZARD_STATE[providerKey]}}"
        fi
        ;;
      "API Key")
        value="$(wizard_input "API Key" "Key is kept in memory only." "${WIZARD_STATE[providerKey]}" "Paste API key" true)" || true
        WIZARD_STATE[providerKey]="${value:-${WIZARD_STATE[providerKey]}}"
        ;;
      "Base URL")
        value="$(wizard_input "LiteLLM Base URL" "URL must start with http:// or https://." "${WIZARD_STATE[providerBaseUrl]}" "https://litellm.example.com" false)" || true
        WIZARD_STATE[providerBaseUrl]="${value:-${WIZARD_STATE[providerBaseUrl]}}"
        ;;
      "Primary Model Override")
        value="$(wizard_input "Primary Model Override" "Leave empty to use the provider default." "${WIZARD_STATE[primaryModelOverride]}" "$(wizard_provider_default "${provider}" primaryModel)" false)" || true
        WIZARD_STATE[primaryModelOverride]="${value:-}"
        ;;
    esac
  done
}

advanced_model() {
  wizard_ui_set_step 6 12
  local provider="${WIZARD_STATE[provider]}"
  local action value rc
  local -a options=(
    "Primary Model"
    "Fallback Model"
    "Context Window"
    "Max Output Tokens"
  )
  if [[ "${WIZARD_STATE[pack]}" == "hermes" ]]; then
    options+=("Hermes Model")
  fi
  while true; do
    action="$(configure_provider_screen \
      "Advanced — Model Configuration" \
      "Primary: ${WIZARD_STATE[primaryModelOverride]:-$(wizard_provider_default "${provider}" primaryModel)} • Fallback: ${WIZARD_STATE[fallbackModelOverride]:-$(wizard_provider_default "${provider}" fallbackModel)} • Context: ${WIZARD_STATE[contextWindowOverride]:-auto} • Max tokens: ${WIZARD_STATE[maxTokensOverride]:-auto}$([[ "${WIZARD_STATE[pack]}" == "hermes" ]] && printf ' • Hermes: %s' "${WIZARD_STATE[hermesModel]:-(provider primary)}")" \
      "${options[@]}")" || return 1
    case "${action}" in
      NEXT)
        wizard_validate_positive_int "${WIZARD_STATE[contextWindowOverride]}" "Context window" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        wizard_validate_positive_int "${WIZARD_STATE[maxTokensOverride]}" "Max output tokens" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        wizard_validate_model_override "${provider}" "${WIZARD_STATE[primaryModelOverride]}" >/tmp/loki-wizard.err 2>&1
        rc=$?
        if [[ ${rc} -eq 2 ]]; then
          wizard_warning "Primary override is not in the provider manifest. Continuing with explicit override."
        elif [[ ${rc} -ne 0 ]]; then
          wizard_error "Primary model validation failed"
          continue
        fi
        wizard_validate_model_override "${provider}" "${WIZARD_STATE[hermesModel]}" >/tmp/loki-wizard.err 2>&1
        rc=$?
        if [[ ${rc} -eq 2 ]]; then
          wizard_warning "Hermes override is not in the provider manifest. Continuing with explicit override."
        elif [[ ${rc} -ne 0 ]]; then
          wizard_error "Hermes model validation failed"
          continue
        fi
        return 0
        ;;
      "Primary Model")
        value="$(wizard_input "Primary Model Override" "Leave empty to use the provider default." "${WIZARD_STATE[primaryModelOverride]}" "$(wizard_provider_default "${provider}" primaryModel)" false)" || true
        WIZARD_STATE[primaryModelOverride]="${value:-}"
        ;;
      "Fallback Model")
        value="$(wizard_input "Fallback Model Override" "Leave empty to use the provider default." "${WIZARD_STATE[fallbackModelOverride]}" "$(wizard_provider_default "${provider}" fallbackModel)" false)" || true
        WIZARD_STATE[fallbackModelOverride]="${value:-}"
        ;;
      "Context Window")
        value="$(wizard_input "Context Window" "Positive integer only." "${WIZARD_STATE[contextWindowOverride]}" "200000" false)" || true
        WIZARD_STATE[contextWindowOverride]="${value:-}"
        ;;
      "Max Output Tokens")
        value="$(wizard_input "Max Output Tokens" "Positive integer only." "${WIZARD_STATE[maxTokensOverride]}" "16384" false)" || true
        WIZARD_STATE[maxTokensOverride]="${value:-}"
        ;;
      "Hermes Model")
        value="$(wizard_input "Hermes Model" "Leave empty to use the provider primary model." "${WIZARD_STATE[hermesModel]}" "${WIZARD_STATE[primaryModelOverride]:-$(wizard_provider_default "${provider}" primaryModel)}" false)" || true
        WIZARD_STATE[hermesModel]="${value:-}"
        ;;
    esac
  done
}

advanced_instance() {
  wizard_ui_set_step 7 12
  local action value
  local choices=(t4g.medium t4g.large t4g.xlarge t4g.2xlarge m7g.xlarge c7g.xlarge BACK)
  while true; do
    action="$(configure_provider_screen \
      "Advanced — Instance Configuration" \
      "Instance: ${WIZARD_STATE[instanceType]} • Root: ${WIZARD_STATE[rootVolumeGb]} GB • Data: ${WIZARD_STATE[dataVolumeGb]} GB" \
      "Instance Type" \
      "Root Volume" \
      "Data Volume")" || return 1
    case "${action}" in
      NEXT)
        wizard_validate_instance_type "${WIZARD_STATE[pack]}" "${WIZARD_STATE[instanceType]}" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        wizard_validate_volume_size "${WIZARD_STATE[rootVolumeGb]}" 20 200 false "Root volume" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        wizard_validate_volume_size "${WIZARD_STATE[dataVolumeGb]}" 20 500 true "Data volume" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        return 0
        ;;
      "Instance Type")
        value="$(wizard_choose "Instance Type" "Choose the compute size." "${WIZARD_STATE[instanceType]}" "${choices[@]}")"
        [[ "${value}" == "BACK" ]] || WIZARD_STATE[instanceType]="${value}"
        ;;
      "Root Volume")
        value="$(wizard_input "Root Volume" "Allowed range: 20-200 GB." "${WIZARD_STATE[rootVolumeGb]}" "40" false)" || true
        WIZARD_STATE[rootVolumeGb]="${value:-${WIZARD_STATE[rootVolumeGb]}}"
        ;;
      "Data Volume")
        value="$(wizard_input "Data Volume" "Use 0 to skip, or 20-500 GB." "${WIZARD_STATE[dataVolumeGb]}" "80" false)" || true
        WIZARD_STATE[dataVolumeGb]="${value:-${WIZARD_STATE[dataVolumeGb]}}"
        ;;
    esac
  done
}

advanced_networking() {
  wizard_ui_set_step 8 12
  local action value
  while true; do
    action="$(configure_provider_screen \
      "Advanced — Networking" \
      "VPC: ${WIZARD_STATE[vpcMode]} • SSH: ${WIZARD_STATE[sshAccessMode]} • Branch: ${WIZARD_STATE[repoBranch]} • Gateway: ${WIZARD_STATE[gwPort]} • Existing VPC: ${WIZARD_STATE[existingVpcId]:-none}" \
      "VPC Mode" \
      "Existing VPC ID" \
      "Existing Subnet ID" \
      "SSH Access" \
      "Key Pair Name" \
      "Repo Branch" \
      "Gateway Port" \
      "Telegram Token" \
      "Allowed Chat IDs")" || return 1
    case "${action}" in
      NEXT)
        if [[ "${WIZARD_STATE[vpcMode]}" == "existing" ]]; then
          [[ -n "${WIZARD_STATE[existingVpcId]}" && -n "${WIZARD_STATE[existingSubnetId]}" ]] || {
            wizard_error "Existing VPC mode requires both VPC ID and subnet ID."
            continue
          }
        fi
        wizard_validate_positive_int "${WIZARD_STATE[gwPort]}" "Gateway port" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        if [[ "${WIZARD_STATE[sshAccessMode]}" == "ssm-only" ]]; then
          WIZARD_STATE[keyPairName]=""
          WIZARD_STATE[sshAllowedCidr]="127.0.0.1/32"
        fi
        wizard_validate_telegram_token "${WIZARD_STATE[telegramToken]}" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        wizard_validate_chat_ids "${WIZARD_STATE[allowedChatIds]}" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        return 0
        ;;
      "VPC Mode")
        value="$(wizard_choose "VPC Mode" "Create new VPC or reuse an existing one." "${WIZARD_STATE[vpcMode]}" new existing BACK)"
        [[ "${value}" == "BACK" ]] || WIZARD_STATE[vpcMode]="${value}"
        ;;
      "Existing VPC ID")
        value="$(wizard_input "Existing VPC ID" "Only used when VPC mode is existing." "${WIZARD_STATE[existingVpcId]}" "vpc-..." false)" || true
        WIZARD_STATE[existingVpcId]="${value:-${WIZARD_STATE[existingVpcId]}}"
        ;;
      "Existing Subnet ID")
        value="$(wizard_input "Existing Subnet ID" "Only used when VPC mode is existing." "${WIZARD_STATE[existingSubnetId]}" "subnet-..." false)" || true
        WIZARD_STATE[existingSubnetId]="${value:-${WIZARD_STATE[existingSubnetId]}}"
        ;;
      "SSH Access")
        value="$(wizard_choose "SSH Access" "SSM only is recommended." "${WIZARD_STATE[sshAccessMode]}" ssm-only keypair BACK)"
        if [[ "${value}" != "BACK" ]]; then
          WIZARD_STATE[sshAccessMode]="${value}"
          if [[ "${value}" == "ssm-only" ]]; then
            WIZARD_STATE[sshAllowedCidr]="127.0.0.1/32"
          fi
        fi
        ;;
      "Key Pair Name")
        value="$(wizard_input "Key Pair Name" "Required only when SSH access is keypair." "${WIZARD_STATE[keyPairName]}" "my-keypair" false)" || true
        WIZARD_STATE[keyPairName]="${value:-${WIZARD_STATE[keyPairName]}}"
        ;;
      "Repo Branch")
        value="$(wizard_input "Repo Branch" "Git branch to deploy from." "${WIZARD_STATE[repoBranch]}" "main" false)" || true
        WIZARD_STATE[repoBranch]="${value:-${WIZARD_STATE[repoBranch]}}"
        ;;
      "Gateway Port")
        value="$(wizard_input "Gateway Port" "Positive integer only." "${WIZARD_STATE[gwPort]}" "3001" false)" || true
        WIZARD_STATE[gwPort]="${value:-${WIZARD_STATE[gwPort]}}"
        ;;
      "Telegram Token")
        value="$(wizard_input "Telegram Token" "Optional unless bot features are needed." "${WIZARD_STATE[telegramToken]}" "123456789:AA..." true)" || true
        WIZARD_STATE[telegramToken]="${value:-${WIZARD_STATE[telegramToken]}}"
        ;;
      "Allowed Chat IDs")
        value="$(wizard_input "Allowed Chat IDs" "Comma-separated integers." "${WIZARD_STATE[allowedChatIds]}" "1775159795" false)" || true
        WIZARD_STATE[allowedChatIds]="${value:-${WIZARD_STATE[allowedChatIds]}}"
        ;;
    esac
  done
}

advanced_deploy_method() {
  wizard_ui_set_step 9 12
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    WIZARD_STATE[deployMethod]="cfn-cli"
    return 0
  fi
  local choice
  choice="$(wizard_choose \
    "Advanced — Deployment Method" \
    "Choose how the stack should be deployed." \
    "${WIZARD_STATE[deployMethod]}" \
    cfn-cli cfn-console terraform BACK)"
  [[ "${choice}" == "BACK" ]] && return 1
  WIZARD_STATE[deployMethod]="${choice}"
}

advanced_security_services() {
  wizard_ui_set_step 10 12
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    return 0
  fi
  local selected
  selected="$(wizard_choose_multi \
    "Advanced — Security Services" \
    "Space toggles services. All are enabled by default." \
    "AWS Security Hub,Amazon GuardDuty,Amazon Inspector,IAM Access Analyzer,AWS Config Recorder" \
    "AWS Security Hub" \
    "Amazon GuardDuty" \
    "Amazon Inspector" \
    "IAM Access Analyzer" \
    "AWS Config Recorder" \
    "Bedrock Model Access Form" \
    "Request Quota Increases")" || return 1

  WIZARD_STATE[enableSecurityHub]="false"
  WIZARD_STATE[enableGuardDuty]="false"
  WIZARD_STATE[enableInspector]="false"
  WIZARD_STATE[enableAccessAnalyzer]="false"
  WIZARD_STATE[enableConfigRecorder]="false"
  WIZARD_STATE[enableBedrockForm]="false"
  WIZARD_STATE[requestQuotaIncreases]="false"
  while IFS= read -r service; do
    case "${service}" in
      "AWS Security Hub") WIZARD_STATE[enableSecurityHub]="true" ;;
      "Amazon GuardDuty") WIZARD_STATE[enableGuardDuty]="true" ;;
      "Amazon Inspector") WIZARD_STATE[enableInspector]="true" ;;
      "IAM Access Analyzer") WIZARD_STATE[enableAccessAnalyzer]="true" ;;
      "AWS Config Recorder") WIZARD_STATE[enableConfigRecorder]="true" ;;
      "Bedrock Model Access Form") WIZARD_STATE[enableBedrockForm]="true" ;;
      "Request Quota Increases") WIZARD_STATE[requestQuotaIncreases]="true" ;;
    esac
  done <<<"${selected}"
}

review_summary_text() {
  local provider_display primary fallback lines
  provider_display="$(wizard_provider_display_name "${WIZARD_STATE[provider]}")"
  [[ "${WIZARD_STATE[provider]}" == "own-cloud" ]] && provider_display="own-cloud"
  primary="${WIZARD_STATE[primaryModelOverride]:-$(wizard_provider_default "${WIZARD_STATE[provider]}" primaryModel)}"
  fallback="${WIZARD_STATE[fallbackModelOverride]:-$(wizard_provider_default "${WIZARD_STATE[provider]}" fallbackModel)}"
  lines="Environment     ${WIZARD_STATE[environmentName]}\n"
  lines+="Agent Pack      $(wizard_pack_display_name "${WIZARD_STATE[pack]}")\n"
  lines+="Profile         ${WIZARD_STATE[profile]}\n"
  lines+="Provider        ${provider_display}\n"
  [[ -n "${WIZARD_STATE[providerRegion]}" ]] && lines+="Region          ${WIZARD_STATE[providerRegion]}\n"
  [[ -n "${primary}" ]] && lines+="Primary Model   ${primary}\n"
  [[ -n "${fallback}" ]] && lines+="Fallback Model  ${fallback}\n"
  lines+="Instance        ${WIZARD_STATE[instanceType]}\n"
  lines+="Storage         root ${WIZARD_STATE[rootVolumeGb]} GB / data ${WIZARD_STATE[dataVolumeGb]} GB\n"
  lines+="Networking      ${WIZARD_STATE[vpcMode]} VPC • ${WIZARD_STATE[sshAccessMode]}\n"
  lines+="Deploy Method   ${WIZARD_STATE[deployMethod]}\n"
  [[ "${WIZARD_STATE[pack]}" == "kiro-cli" ]] && lines+="Post-install    kiro-cli login --use-device-flow\n"
  printf '%b' "${lines}"
}

review_screen() {
  wizard_ui_set_step 6 7
  [[ "${WIZARD_STATE[installMode]}" == "advanced" ]] && wizard_ui_set_step 11 12

  while true; do
    WIZARD_STATE[lokiWatermark]="${WIZARD_STATE[environmentName]}"
    PARTIAL_COMMAND="$(build_bootstrap_command WIZARD_STATE | tr -d '\n')"
    WIZARD_STATE[generatedBootstrapCommand]="${PARTIAL_COMMAND}"
    WIZARD_STATE[generatedCfnParams]="$(build_cfn_params WIZARD_STATE | jq -c .)"
    WIZARD_STATE[generatedTerraformVars]="$(build_terraform_vars WIZARD_STATE | jq -c .)"

    wizard_header "Review & Deploy" "Validate the final configuration before running deploy/bootstrap.sh."
    wizard_summary "$(review_summary_text)"
    echo
    if wizard_validate_review_state "$(wizard_state_json)" >/tmp/loki-wizard.err 2>&1; then
      wizard_success "All validations passed"
    else
      wizard_error "$(cat /tmp/loki-wizard.err)"
    fi
    echo
    local choice
    choice="$("${GUM}" choose \
      "Deploy" \
      "Edit Environment Name" \
      "Edit Pack" \
      "Edit Profile" \
      "Edit Provider" \
      "Edit Provider Config" \
      "Edit Advanced Model" \
      "Edit Instance & Storage" \
      "Edit Networking" \
      "Edit Deploy Method" \
      "Edit Security Services" \
      "Back" < /dev/tty)"
    case "${choice}" in
      Deploy)
        wizard_validate_review_state "$(wizard_state_json)" >/tmp/loki-wizard.err 2>&1 || {
          wizard_error "$(cat /tmp/loki-wizard.err)"
          continue
        }
        return 0
        ;;
      "Edit Environment Name") return 10 ;;
      "Edit Pack") return 11 ;;
      "Edit Profile") return 12 ;;
      "Edit Provider") return 13 ;;
      "Edit Provider Config") return 14 ;;
      "Edit Advanced Model") return 15 ;;
      "Edit Instance & Storage") return 16 ;;
      "Edit Networking") return 17 ;;
      "Edit Deploy Method") return 18 ;;
      "Edit Security Services") return 19 ;;
      Back) return 1 ;;
    esac
  done
}

deploy_screen() {
  wizard_ui_set_step 7 7
  [[ "${WIZARD_STATE[installMode]}" == "advanced" ]] && wizard_ui_set_step 12 12
  PARTIAL_COMMAND="$(build_bootstrap_command WIZARD_STATE | tr -d '\n')"
  WIZARD_STATE[generatedBootstrapCommand]="${PARTIAL_COMMAND}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "STATE_JSON:"
    wizard_state_json
    echo
    echo "BOOTSTRAP_COMMAND:"
    echo "${WIZARD_STATE[generatedBootstrapCommand]}"
    echo
    echo "CFN_PARAMS:"
    jq . <<<"${WIZARD_STATE[generatedCfnParams]}"
    echo
    echo "TERRAFORM_VARS:"
    jq . <<<"${WIZARD_STATE[generatedTerraformVars]}"
    return 0
  fi

  wizard_header "Deploy" "Executing the generated bootstrap command."
  echo "${WIZARD_STATE[generatedBootstrapCommand]}"
  echo
  if [[ "${WIZARD_STATE[deployMethod]}" == "cfn-console" ]]; then
    echo "CloudFormation console parameter set:"
    jq . <<<"${WIZARD_STATE[generatedCfnParams]}"
    return 0
  fi
  if [[ "${WIZARD_STATE[deployMethod]}" == "terraform" ]]; then
    echo "Terraform variables:"
    jq . <<<"${WIZARD_STATE[generatedTerraformVars]}"
    return 0
  fi

  (cd "${REPO_ROOT}" && eval "${WIZARD_STATE[generatedBootstrapCommand]}")
}

apply_scenario() {
  local name="$1"
  wizard_state_init
  wizard_data_load
  set_pack_defaults
  set_provider_defaults
  apply_profile_defaults

  case "${name}" in
    1|simple-bedrock-iam)
      ;;
    2|simple-anthropic)
      WIZARD_STATE[provider]="anthropic-api"
      WIZARD_STATE[providerKey]="sk-ant-test-key"
      ;;
    3|simple-openai)
      WIZARD_STATE[provider]="openai-api"
      WIZARD_STATE[providerKey]="sk-test-key"
      ;;
    4|simple-openrouter)
      WIZARD_STATE[provider]="openrouter"
      WIZARD_STATE[providerKey]="openrouter-test-key-12345"
      ;;
    5|simple-litellm)
      WIZARD_STATE[provider]="litellm"
      WIZARD_STATE[providerBaseUrl]="https://litellm.example.com"
      ;;
    6|hermes-anthropic)
      WIZARD_STATE[pack]="hermes"; set_pack_defaults
      WIZARD_STATE[provider]="anthropic-api"; WIZARD_STATE[providerKey]="sk-ant-test-key"
      ;;
    7|hermes-openrouter)
      WIZARD_STATE[pack]="hermes"; set_pack_defaults
      WIZARD_STATE[provider]="openrouter"; WIZARD_STATE[providerKey]="openrouter-test-key-12345"
      ;;
    8|claude-code-bedrock)
      WIZARD_STATE[pack]="claude-code"; set_pack_defaults
      ;;
    9|claude-code-anthropic)
      WIZARD_STATE[pack]="claude-code"; set_pack_defaults
      WIZARD_STATE[provider]="anthropic-api"; WIZARD_STATE[providerKey]="sk-ant-test-key"
      ;;
    10|pi-openrouter)
      WIZARD_STATE[pack]="pi"; set_pack_defaults
      WIZARD_STATE[provider]="openrouter"; WIZARD_STATE[providerKey]="openrouter-test-key-12345"
      ;;
    11|hermes-bedrock)
      WIZARD_STATE[pack]="hermes"; set_pack_defaults
      ;;
    12|hermes-openai)
      WIZARD_STATE[pack]="hermes"; set_pack_defaults
      WIZARD_STATE[provider]="openai-api"; WIZARD_STATE[providerKey]="sk-test-key"
      ;;
    13|pi-bedrock)
      WIZARD_STATE[pack]="pi"; set_pack_defaults
      ;;
    14|pi-litellm)
      WIZARD_STATE[pack]="pi"; set_pack_defaults
      WIZARD_STATE[provider]="litellm"; WIZARD_STATE[providerBaseUrl]="https://litellm.example.com"
      ;;
    15|ironclaw-bedrock)
      WIZARD_STATE[pack]="ironclaw"; set_pack_defaults
      ;;
    16|nemoclaw-bedrock)
      WIZARD_STATE[pack]="nemoclaw"; set_pack_defaults
      WIZARD_STATE[profile]="personal_assistant"; apply_profile_defaults
      ;;
    17|kiro-cli)
      WIZARD_STATE[pack]="kiro-cli"; set_pack_defaults
      WIZARD_STATE[provider]="own-cloud"; WIZARD_STATE[providerAuthType]=""; WIZARD_STATE[providerRegion]=""
      ;;
    18|advanced-model-override)
      WIZARD_STATE[installMode]="advanced"
      WIZARD_STATE[primaryModelOverride]="global.anthropic.claude-opus-4-6-v1"
      ;;
    19|minimal)
      ;;
    *)
      die "Unknown scenario: ${name}"
      ;;
  esac

  if [[ "${WIZARD_STATE[provider]}" != "own-cloud" ]]; then
    set_provider_defaults
  fi
  case "${WIZARD_STATE[provider]}" in
    anthropic-api) [[ -n "${WIZARD_STATE[providerKey]}" ]] || WIZARD_STATE[providerKey]="sk-ant-test-key" ;;
    openai-api) [[ -n "${WIZARD_STATE[providerKey]}" ]] || WIZARD_STATE[providerKey]="sk-test-key" ;;
    openrouter) [[ -n "${WIZARD_STATE[providerKey]}" ]] || WIZARD_STATE[providerKey]="openrouter-test-key-12345" ;;
    litellm) [[ -n "${WIZARD_STATE[providerBaseUrl]}" ]] || WIZARD_STATE[providerBaseUrl]="https://litellm.example.com" ;;
  esac
  WIZARD_STATE[environmentName]="${WIZARD_STATE[pack]}"
  WIZARD_STATE[lokiWatermark]="${WIZARD_STATE[environmentName]}"
  WIZARD_STATE[deployMethod]="cfn-cli"
  WIZARD_STATE[generatedCfnParams]="$(build_cfn_params WIZARD_STATE | jq -c .)"
  WIZARD_STATE[generatedTerraformVars]="$(build_terraform_vars WIZARD_STATE | jq -c .)"
  WIZARD_STATE[generatedBootstrapCommand]="$(build_bootstrap_command WIZARD_STATE | tr -d '\n')"
}

main_flow() {
  local step="install_mode" rc
  while true; do
    case "${step}" in
      install_mode)
        select_install_mode
        step="pack"
        ;;
      pack)
        select_pack || { step="install_mode"; continue; }
        step="environment_name"
        ;;
      environment_name)
        select_environment_name || { step="pack"; continue; }
        step="profile"
        ;;
      profile)
        select_profile || { step="environment_name"; continue; }
        step="provider"
        ;;
      provider)
        select_provider || { step="profile"; continue; }
        step="provider_config"
        ;;
      provider_config)
        configure_provider || { step="provider"; continue; }
        if [[ "${WIZARD_STATE[installMode]}" == "advanced" ]]; then
          step="advanced_model"
        else
          step="review"
        fi
        ;;
      advanced_model)
        advanced_model || { step="provider_config"; continue; }
        step="advanced_instance"
        ;;
      advanced_instance)
        advanced_instance || { step="advanced_model"; continue; }
        step="advanced_networking"
        ;;
      advanced_networking)
        advanced_networking || { step="advanced_instance"; continue; }
        step="advanced_deploy"
        ;;
      advanced_deploy)
        advanced_deploy_method || { step="advanced_networking"; continue; }
        step="advanced_security"
        ;;
      advanced_security)
        advanced_security_services || { step="advanced_deploy"; continue; }
        step="review"
        ;;
      review)
        rc=0
        review_screen || rc=$?
        case "${rc}" in
          0) step="deploy" ;;
          1)
            if [[ "${WIZARD_STATE[installMode]}" == "advanced" ]]; then
              step="advanced_security"
            else
              step="provider_config"
            fi
            ;;
          10) step="environment_name" ;;
          11) step="pack" ;;
          12) step="profile" ;;
          13) step="provider" ;;
          14) step="provider_config" ;;
          15) step="advanced_model" ;;
          16) step="advanced_instance" ;;
          17) step="advanced_networking" ;;
          18) step="advanced_deploy" ;;
          19) step="advanced_security" ;;
          *) step="review" ;;
        esac
        ;;
      deploy)
        deploy_screen
        return 0
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_tool jq
  require_tool python3
  wizard_state_init
  wizard_data_load
  set_pack_defaults
  set_provider_defaults
  apply_profile_defaults

  if [[ -n "${SCENARIO}" ]]; then
    DRY_RUN=true
    apply_scenario "${SCENARIO}"
    deploy_screen
    return 0
  fi

  ensure_gum
  main_flow
}

main "$@"
