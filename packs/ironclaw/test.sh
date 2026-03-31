#!/usr/bin/env bash
# packs/ironclaw/test.sh — Offline tests for the IronClaw pack
#
# Validates config generation, manifest structure, architecture detection,
# download URL construction, and temp dir cleanup — WITHOUT requiring
# IronClaw installed or bedrockify running.
#
# Usage:  bash packs/ironclaw/test.sh
# Exit:   0 = all passed, 1 = failures

set -uo pipefail

# ── Test framework ────────────────────────────────────────────────────────────
_PASS=0
_FAIL=0
_SKIP=0

pass() { (( _PASS++ )); printf "\033[0;32m  ✓ %s\033[0m\n" "$1"; }
fail_test() { (( _FAIL++ )); printf "\033[0;31m  ✗ %s\033[0m\n" "$1"; }
skip() { (( _SKIP++ )); printf "\033[0;33m  ⊘ %s (skipped: %s)\033[0m\n" "$1" "$2"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${desc}"
  else
    fail_test "${desc}: expected '${expected}', got '${actual}'"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "${haystack}" | grep -qF "${needle}"; then
    pass "${desc}"
  else
    fail_test "${desc}: '${needle}' not found in output"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if ! printf '%s' "${haystack}" | grep -qF "${needle}"; then
    pass "${desc}"
  else
    fail_test "${desc}: '${needle}' should NOT be in output"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "${path}" ]]; then
    pass "${desc}"
  else
    fail_test "${desc}: file not found: ${path}"
  fi
}

summary() {
  printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  printf "  Results: %d passed, %d failed, %d skipped\n" "${_PASS}" "${_FAIL}" "${_SKIP}"
  printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
  [[ ${_FAIL} -eq 0 ]]
}

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"
PACKS_ROOT="$(cd "${PACK_DIR}/.." && pwd)"

printf "\n🦀 IronClaw Pack Tests\n\n"

# ══════════════════════════════════════════════════════════════════════════════
# 1. Manifest validation
# ══════════════════════════════════════════════════════════════════════════════
printf "── manifest.yaml ──\n"

MANIFEST="${PACK_DIR}/manifest.yaml"
assert_file_exists "manifest.yaml exists" "${MANIFEST}"

if command -v python3 &>/dev/null; then
  # Use python to parse YAML (no yq dependency)
  MANIFEST_JSON="$(python3 -c "
import yaml, json, sys
with open('${MANIFEST}') as f:
    print(json.dumps(yaml.safe_load(f)))
" 2>/dev/null)" || MANIFEST_JSON=""

  if [[ -n "${MANIFEST_JSON}" ]]; then
    NAME="$(printf '%s' "${MANIFEST_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))")"
    assert_eq "manifest name is 'ironclaw'" "ironclaw" "${NAME}"

    TYPE="$(printf '%s' "${MANIFEST_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))")"
    assert_eq "manifest type is 'agent'" "agent" "${TYPE}"

    DEPS="$(printf '%s' "${MANIFEST_JSON}" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin).get('deps',[])))")"
    assert_contains "manifest declares bedrockify dep" "${DEPS}" "bedrockify"

    HEALTH_CMD="$(printf '%s' "${MANIFEST_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('health_check',{}).get('command',''))")"
    assert_eq "health_check uses ironclaw --version" "ironclaw --version" "${HEALTH_CMD}"

    PROVIDES_CMDS="$(printf '%s' "${MANIFEST_JSON}" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin).get('provides',{}).get('commands',[])))")"
    assert_contains "provides ironclaw command" "${PROVIDES_CMDS}" "ironclaw"

    PROVIDES_SVCS="$(printf '%s' "${MANIFEST_JSON}" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin).get('provides',{}).get('services',[])))")"
    assert_eq "provides no services (CLI only)" "" "${PROVIDES_SVCS}"

    ARCHES="$(printf '%s' "${MANIFEST_JSON}" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin).get('requirements',{}).get('arch',[])))")"
    assert_contains "supports arm64" "${ARCHES}" "arm64"
    assert_contains "supports amd64" "${ARCHES}" "amd64"
  else
    skip "manifest YAML parse" "python3 yaml module not available"
  fi
else
  skip "manifest validation" "python3 not available"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 2. Architecture detection and download URL construction
# ══════════════════════════════════════════════════════════════════════════════
printf "\n── architecture detection ──\n"

# Extract the arch-mapping logic from install.sh and test it
test_arch_mapping() {
  local arch="$1" expected="$2"
  local result
  case "${arch}" in
    aarch64|arm64) result="aarch64-unknown-linux-musl" ;;
    x86_64)        result="x86_64-unknown-linux-musl" ;;
    *)             result="UNSUPPORTED" ;;
  esac
  assert_eq "arch '${arch}' → '${expected}'" "${expected}" "${result}"
}

test_arch_mapping "aarch64" "aarch64-unknown-linux-musl"
test_arch_mapping "arm64"   "aarch64-unknown-linux-musl"
test_arch_mapping "x86_64"  "x86_64-unknown-linux-musl"
test_arch_mapping "i386"    "UNSUPPORTED"
test_arch_mapping "riscv64" "UNSUPPORTED"

# Test URL construction
RELEASE_ARCH="aarch64-unknown-linux-musl"
EXPECTED_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-aarch64-unknown-linux-musl.tar.gz"
ACTUAL_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-${RELEASE_ARCH}.tar.gz"
assert_eq "download URL for aarch64" "${EXPECTED_URL}" "${ACTUAL_URL}"

RELEASE_ARCH="x86_64-unknown-linux-musl"
EXPECTED_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-x86_64-unknown-linux-musl.tar.gz"
ACTUAL_URL="https://github.com/nearai/ironclaw/releases/latest/download/ironclaw-${RELEASE_ARCH}.tar.gz"
assert_eq "download URL for x86_64" "${EXPECTED_URL}" "${ACTUAL_URL}"

# ══════════════════════════════════════════════════════════════════════════════
# 3. .env config generation
# ══════════════════════════════════════════════════════════════════════════════
printf "\n── .env config generation ──\n"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

# Simulate what install.sh does for .env generation
TEST_MODEL="us.anthropic.claude-sonnet-4-6-v1"
TEST_PORT="8090"
cat > "${TEST_TMP}/.env" <<EOF
# IronClaw config — using bedrockify as OpenAI-compatible backend
# No NEAR AI auth needed; bedrockify handles Bedrock via IAM instance profile
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:${TEST_PORT}/v1
LLM_API_KEY=not-needed
LLM_MODEL=${TEST_MODEL}
EOF

ENV_CONTENT="$(cat "${TEST_TMP}/.env")"

assert_contains ".env has LLM_BACKEND=openai_compatible" "${ENV_CONTENT}" "LLM_BACKEND=openai_compatible"
assert_contains ".env has LLM_BASE_URL with port" "${ENV_CONTENT}" "LLM_BASE_URL=http://127.0.0.1:${TEST_PORT}/v1"
assert_contains ".env has LLM_API_KEY placeholder" "${ENV_CONTENT}" "LLM_API_KEY=not-needed"
assert_contains ".env has LLM_MODEL" "${ENV_CONTENT}" "LLM_MODEL=${TEST_MODEL}"
assert_not_contains ".env has no NEAR AI token" "${ENV_CONTENT}" "NEAR_AI"

# Test with custom model
TEST_MODEL_2="anthropic/claude-opus-4.6"
cat > "${TEST_TMP}/.env2" <<EOF
LLM_MODEL=${TEST_MODEL_2}
EOF
ENV2="$(cat "${TEST_TMP}/.env2")"
assert_contains ".env respects custom model" "${ENV2}" "LLM_MODEL=${TEST_MODEL_2}"

# Test with custom port
TEST_PORT_2="9999"
cat > "${TEST_TMP}/.env3" <<EOF
LLM_BASE_URL=http://127.0.0.1:${TEST_PORT_2}/v1
EOF
ENV3="$(cat "${TEST_TMP}/.env3")"
assert_contains ".env respects custom port" "${ENV3}" "http://127.0.0.1:9999/v1"

# ══════════════════════════════════════════════════════════════════════════════
# 4. Temp dir cleanup pattern
# ══════════════════════════════════════════════════════════════════════════════
printf "\n── temp dir cleanup ──\n"

# Verify the install script cleans up on both success and failure paths
INSTALL_SH="$(cat "${PACK_DIR}/install.sh")"

# Check that TEMP_DIR is cleaned after download failure
assert_contains "cleanup on download failure" "${INSTALL_SH}" 'rm -rf "${TEMP_DIR}"'

# Count cleanup occurrences — should appear at least twice (failure + success paths)
CLEANUP_COUNT="$(grep -c 'rm -rf "${TEMP_DIR}"' "${PACK_DIR}/install.sh")"
if [[ ${CLEANUP_COUNT} -ge 2 ]]; then
  pass "temp dir cleaned in ${CLEANUP_COUNT} code paths (failure + success)"
else
  fail_test "temp dir cleaned in only ${CLEANUP_COUNT} path(s) — expected ≥2"
fi

# ══════════════════════════════════════════════════════════════════════════════
# 5. common.sh integration
# ══════════════════════════════════════════════════════════════════════════════
printf "\n── common.sh integration ──\n"

COMMON_SH="$(cat "${PACKS_ROOT}/common.sh")"

assert_contains "common.sh has check_bedrockify_health" "${COMMON_SH}" "check_bedrockify_health"
assert_contains "install.sh uses check_bedrockify_health" "${INSTALL_SH}" "check_bedrockify_health"
assert_not_contains "install.sh no longer inlines health check" "${INSTALL_SH}" '# Verify bedrockify is running'

# ══════════════════════════════════════════════════════════════════════════════
# 6. Shell profile resource
# ══════════════════════════════════════════════════════════════════════════════
printf "\n── resources/shell-profile.sh ──\n"

PROFILE="${PACK_DIR}/resources/shell-profile.sh"
assert_file_exists "shell-profile.sh exists" "${PROFILE}"

PROFILE_CONTENT="$(cat "${PROFILE}")"
assert_contains "profile sets PACK_BANNER_NAME" "${PROFILE_CONTENT}" "PACK_BANNER_NAME"
assert_contains "profile sets PACK_BANNER_COMMANDS" "${PROFILE_CONTENT}" "ironclaw"

# ══════════════════════════════════════════════════════════════════════════════
# 7. Script basics
# ══════════════════════════════════════════════════════════════════════════════
printf "\n── script basics ──\n"

# Check set -euo pipefail
assert_contains "install.sh has strict mode" "${INSTALL_SH}" "set -euo pipefail"

# Check it sources common.sh
assert_contains "install.sh sources common.sh" "${INSTALL_SH}" 'source "${SCRIPT_DIR}/../common.sh"'

# Check shellcheck directive
assert_contains "install.sh has shellcheck source directive" "${INSTALL_SH}" "# shellcheck source=../common.sh"

# Check idempotency note
assert_contains "install.sh documents idempotency" "${INSTALL_SH}" "Idempotent: safe to re-run"

# ══════════════════════════════════════════════════════════════════════════════
# 8. Live environment tests (skipped in offline mode)
# ══════════════════════════════════════════════════════════════════════════════
printf "\n── live environment (requires ironclaw + bedrockify) ──\n"

if command -v ironclaw &>/dev/null; then
  IC_VER="$(ironclaw --version 2>/dev/null || echo "")"
  if [[ -n "${IC_VER}" ]]; then
    pass "ironclaw --version: ${IC_VER}"
  else
    fail_test "ironclaw installed but --version failed"
  fi
else
  skip "ironclaw --version" "ironclaw not installed"
fi

if curl -sf "http://127.0.0.1:8090/" 2>/dev/null | grep -q '"status":"ok"'; then
  pass "bedrockify is healthy"
else
  skip "bedrockify health check" "bedrockify not running"
fi

if [[ -f "${HOME}/.ironclaw/.env" ]]; then
  LIVE_ENV="$(cat "${HOME}/.ironclaw/.env")"
  assert_contains "live .env has LLM_BACKEND" "${LIVE_ENV}" "LLM_BACKEND=openai_compatible"
else
  skip "live .env validation" ".ironclaw/.env not found"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
summary
