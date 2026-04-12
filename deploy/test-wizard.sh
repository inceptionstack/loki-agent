#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=deploy/lib/wizard-data.sh
source "${SCRIPT_DIR}/lib/wizard-data.sh"
# shellcheck source=deploy/lib/wizard-state.sh
source "${SCRIPT_DIR}/lib/wizard-state.sh"
# shellcheck source=deploy/lib/wizard-validate.sh
source "${SCRIPT_DIR}/lib/wizard-validate.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "${haystack}" == *"${needle}"* ]] || fail "${label}: expected to find '${needle}'"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  [[ "${haystack}" != *"${needle}"* ]] || fail "${label}: did not expect '${needle}'"
}

run_scenario_command() {
  local scenario="$1"
  local output
  output="$(bash "${SCRIPT_DIR}/wizard.sh" --dry-run --scenario "${scenario}")"
  awk '/^BOOTSTRAP_COMMAND:/{getline; print; exit}' <<<"${output}"
}

run_scenario_state_json() {
  local scenario="$1"
  local output
  output="$(bash "${SCRIPT_DIR}/wizard.sh" --dry-run --scenario "${scenario}")"
  awk '
    /^STATE_JSON:/ {capture=1; next}
    /^BOOTSTRAP_COMMAND:/ {capture=0}
    capture {print}
  ' <<<"${output}"
}

scenario_tests() {
  local cmd state_json expected_pack

  for scenario in $(seq 1 19); do
    state_json="$(run_scenario_state_json "${scenario}")"
    expected_pack="$(jq -r '.pack' <<<"${state_json}")"
    assert_contains "$(jq -r '.environmentName' <<<"${state_json}")" "${expected_pack}" "scenario ${scenario} environment name defaults to pack"
  done

  cmd="$(run_scenario_command 1)"
  assert_contains "${cmd}" "--provider bedrock" "scenario 1 provider"
  assert_contains "${cmd}" "--provider-auth-type iam" "scenario 1 auth"

  cmd="$(run_scenario_command 2)"
  assert_contains "${cmd}" "--provider anthropic-api" "scenario 2 provider"
  assert_contains "${cmd}" "--provider-key sk-ant-test-key" "scenario 2 key"

  cmd="$(run_scenario_command 3)"
  assert_contains "${cmd}" "--provider openai-api" "scenario 3 provider"
  assert_contains "${cmd}" "--provider-key sk-test-key" "scenario 3 key"

  cmd="$(run_scenario_command 4)"
  assert_contains "${cmd}" "--provider openrouter" "scenario 4 provider"

  cmd="$(run_scenario_command 5)"
  assert_contains "${cmd}" "--provider litellm" "scenario 5 provider"
  assert_contains "${cmd}" "--provider-base-url https://litellm.example.com" "scenario 5 base url"

  cmd="$(run_scenario_command 6)"
  assert_contains "${cmd}" "--pack hermes" "scenario 6 pack"
  assert_contains "${cmd}" "--provider anthropic-api" "scenario 6 provider"

  cmd="$(run_scenario_command 7)"
  assert_contains "${cmd}" "--pack hermes" "scenario 7 pack"
  assert_contains "${cmd}" "--provider openrouter" "scenario 7 provider"

  cmd="$(run_scenario_command 8)"
  assert_contains "${cmd}" "--pack claude-code" "scenario 8 pack"
  assert_contains "${cmd}" "--provider bedrock" "scenario 8 provider"

  cmd="$(run_scenario_command 9)"
  assert_contains "${cmd}" "--pack claude-code" "scenario 9 pack"
  assert_contains "${cmd}" "--provider anthropic-api" "scenario 9 provider"

  cmd="$(run_scenario_command 10)"
  assert_contains "${cmd}" "--pack pi" "scenario 10 pack"
  assert_contains "${cmd}" "--provider openrouter" "scenario 10 provider"

  cmd="$(run_scenario_command 11)"
  assert_contains "${cmd}" "--pack hermes" "scenario 11 pack"
  assert_contains "${cmd}" "--provider bedrock" "scenario 11 provider"

  cmd="$(run_scenario_command 12)"
  assert_contains "${cmd}" "--pack hermes" "scenario 12 pack"
  assert_contains "${cmd}" "--provider openai-api" "scenario 12 provider"

  cmd="$(run_scenario_command 13)"
  assert_contains "${cmd}" "--pack pi" "scenario 13 pack"
  assert_contains "${cmd}" "--provider bedrock" "scenario 13 provider"

  cmd="$(run_scenario_command 14)"
  assert_contains "${cmd}" "--pack pi" "scenario 14 pack"
  assert_contains "${cmd}" "--provider litellm" "scenario 14 provider"

  cmd="$(run_scenario_command 15)"
  assert_contains "${cmd}" "--pack ironclaw" "scenario 15 pack"
  assert_contains "${cmd}" "--provider bedrock" "scenario 15 provider"

  cmd="$(run_scenario_command 16)"
  assert_contains "${cmd}" "--pack nemoclaw" "scenario 16 pack"
  assert_contains "${cmd}" "--profile personal_assistant" "scenario 16 profile"

  cmd="$(run_scenario_command 17)"
  assert_contains "${cmd}" "--pack kiro-cli" "scenario 17 pack"
  assert_not_contains "${cmd}" "--provider" "scenario 17 skips provider"

  cmd="$(run_scenario_command 18)"
  assert_contains "${cmd}" "--provider bedrock" "scenario 18 provider"
  assert_contains "${cmd}" "--model global.anthropic.claude-opus-4-6-v1" "scenario 18 model"

  cmd="$(run_scenario_command 19)"
  assert_contains "${cmd}" "--pack openclaw" "scenario 19 pack"
  assert_contains "${cmd}" "--provider bedrock" "scenario 19 provider"

  pass "all 19 scenario commands"
}

compatibility_tests() {
  wizard_data_load

  wizard_pack_provider_supported openclaw litellm || fail "openclaw should support litellm"
  wizard_pack_provider_supported hermes openrouter || fail "hermes should support openrouter"
  wizard_pack_provider_supported pi litellm || fail "pi should support litellm"
  wizard_pack_provider_supported claude-code anthropic-api || fail "claude-code should support anthropic-api"
  ! wizard_pack_provider_supported hermes litellm || fail "hermes should not support litellm"
  ! wizard_pack_provider_supported nemoclaw openrouter || fail "nemoclaw should not support openrouter"

  pass "compatibility matrix"
}

validation_tests() {
  wizard_data_load

  wizard_validate_api_key anthropic-api sk-ant-valid >/dev/null || fail "valid anthropic key should pass"
  ! wizard_validate_api_key anthropic-api sk-wrong >/dev/null 2>&1 || fail "invalid anthropic key should fail"

  wizard_validate_api_key openai-api sk-valid >/dev/null || fail "valid openai key should pass"
  ! wizard_validate_api_key openai-api bad >/dev/null 2>&1 || fail "invalid openai key should fail"

  wizard_validate_url https://litellm.example.com >/dev/null || fail "valid URL should pass"
  ! wizard_validate_url ftp://example.com >/dev/null 2>&1 || fail "invalid URL should fail"

  wizard_validate_pack_provider hermes openrouter >/dev/null || fail "valid pack/provider should pass"
  ! wizard_validate_pack_provider hermes litellm >/dev/null 2>&1 || fail "invalid pack/provider should fail"

  wizard_validate_pack_profile nemoclaw personal_assistant >/dev/null || fail "nemoclaw personal_assistant should pass"
  ! wizard_validate_pack_profile nemoclaw builder >/dev/null 2>&1 || fail "nemoclaw builder should fail"

  ! wizard_validate_chat_ids "12,abc" >/dev/null 2>&1 || fail "invalid chat IDs should fail"
  ! wizard_validate_telegram_token "bad-token" >/dev/null 2>&1 || fail "invalid telegram token should fail"

  pass "validation helpers"
}

dry_run_shape_test() {
  local output
  output="$(bash "${SCRIPT_DIR}/wizard.sh" --dry-run --scenario 5)"
  assert_contains "${output}" "STATE_JSON:" "dry-run state section"
  assert_contains "${output}" "BOOTSTRAP_COMMAND:" "dry-run command section"
  assert_contains "${output}" "CFN_PARAMS:" "dry-run cfn section"
  assert_contains "${output}" "TERRAFORM_VARS:" "dry-run terraform section"
  pass "dry-run output shape"
}

main() {
  cd "${REPO_ROOT}"
  scenario_tests
  compatibility_tests
  validation_tests
  dry_run_shape_test
  pass "wizard test suite"
}

main "$@"
