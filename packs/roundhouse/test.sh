#!/usr/bin/env bash
# packs/roundhouse/test.sh — Offline validation for roundhouse pack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf "  ✓ %s\n" "$1"; }
fail_test() { FAIL=$((FAIL + 1)); printf "  ✗ %s\n" "$1" >&2; }

echo "=== roundhouse pack tests ==="

# Check install.sh exists and is executable
if [[ -x "${SCRIPT_DIR}/install.sh" ]]; then
  pass "install.sh exists and is executable"
else
  fail_test "install.sh missing or not executable"
fi

# Check manifest.yaml exists
if [[ -f "${SCRIPT_DIR}/manifest.yaml" ]]; then
  pass "manifest.yaml exists"
else
  fail_test "manifest.yaml missing"
fi

# Check shell-profile exists
if [[ -f "${SCRIPT_DIR}/resources/shell-profile.sh" ]]; then
  pass "resources/shell-profile.sh exists"
else
  fail_test "resources/shell-profile.sh missing"
fi

# Check install.sh uses common.sh
if grep -q "source.*common.sh" "${SCRIPT_DIR}/install.sh"; then
  pass "install.sh sources common.sh"
else
  fail_test "install.sh does not source common.sh"
fi

# Check required config keys are read
if grep -q "pack_config_get telegram_bot_token_secret" "${SCRIPT_DIR}/install.sh"; then
  pass "install.sh reads telegram_bot_token_secret from config"
else
  fail_test "install.sh does not read telegram_bot_token_secret"
fi

if grep -q "pack_config_get telegram_user" "${SCRIPT_DIR}/install.sh"; then
  pass "install.sh reads telegram_user from config"
else
  fail_test "install.sh does not read telegram_user"
fi

# Check headless setup is used
if grep -q "\-\-headless" "${SCRIPT_DIR}/install.sh"; then
  pass "install.sh uses --headless setup"
else
  fail_test "install.sh does not use --headless"
fi

# Check token validation
if grep -q "Invalid Telegram bot token format" "${SCRIPT_DIR}/install.sh"; then
  pass "install.sh validates token format"
else
  fail_test "install.sh does not validate token format"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]] || exit 1
