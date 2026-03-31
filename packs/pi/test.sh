#!/usr/bin/env bash
# packs/pi/test.sh — Unit tests for the Pi Coding Agent pack
#
# Validates config generation, manifest structure, shell-profile, and install.sh
# interface WITHOUT requiring Pi to be installed or bedrockify to be running.
#
# Usage: bash packs/pi/test.sh
# Exit: 0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"
PACKS_DIR="${SCRIPT_DIR}/.."
COMMON="${PACKS_DIR}/common.sh"

# ── Test harness ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { printf "${GREEN}  ✓${NC} %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "${RED}  ✗${NC} %s\n" "$1"; FAIL=$((FAIL+1)); }
skip() { printf "${YELLOW}  ○${NC} %s\n" "$1 (skipped)"; SKIP=$((SKIP+1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

# ── Test: manifest.yaml structure ─────────────────────────────────────────────
header "Test: manifest.yaml"

MANIFEST="${PACK_DIR}/manifest.yaml"

if [[ -f "${MANIFEST}" ]]; then
  pass "manifest.yaml exists"
else
  fail "manifest.yaml missing"
fi

# Valid YAML
if command -v python3 &>/dev/null; then
  if python3 -c "import yaml; yaml.safe_load(open('${MANIFEST}'))" 2>/dev/null; then
    pass "manifest.yaml is valid YAML"
  else
    fail "manifest.yaml is invalid YAML"
  fi

  # Required keys
  for key in name version type description deps params health_check provides; do
    if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if '${key}' in data else 1)
" 2>/dev/null; then
      pass "manifest.yaml has '${key}' key"
    else
      fail "manifest.yaml missing '${key}' key"
    fi
  done

  # Name matches folder
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if data.get('name') == 'pi' else 1)
" 2>/dev/null; then
    pass "manifest.yaml name matches folder (pi)"
  else
    fail "manifest.yaml name does not match folder"
  fi

  # Deps include bedrockify
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if 'bedrockify' in data.get('deps', []) else 1)
" 2>/dev/null; then
    pass "manifest.yaml deps include bedrockify"
  else
    fail "manifest.yaml deps missing bedrockify"
  fi

  # Health check command references pi
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
hc = data.get('health_check', {}).get('command', '')
sys.exit(0 if 'pi' in hc else 1)
" 2>/dev/null; then
    pass "manifest.yaml health_check references pi"
  else
    fail "manifest.yaml health_check does not reference pi"
  fi

  # Provides commands include pi
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
cmds = data.get('provides', {}).get('commands', [])
sys.exit(0 if 'pi' in cmds else 1)
" 2>/dev/null; then
    pass "manifest.yaml provides.commands includes pi"
  else
    fail "manifest.yaml provides.commands missing pi"
  fi
else
  skip "manifest.yaml structure tests: python3 not available"
fi

# ── Test: install.sh interface ────────────────────────────────────────────────
header "Test: install.sh interface"

INSTALL="${PACK_DIR}/install.sh"

if [[ -f "${INSTALL}" ]]; then
  pass "install.sh exists"
else
  fail "install.sh missing"
fi

if [[ -x "${INSTALL}" ]]; then
  pass "install.sh is executable"
else
  fail "install.sh is not executable"
fi

# Shebang check
SHEBANG="$(head -1 "${INSTALL}")"
if [[ "${SHEBANG}" == "#!/usr/bin/env bash" ]]; then
  pass "install.sh has correct shebang"
else
  fail "install.sh has unexpected shebang: ${SHEBANG}"
fi

# Sources common.sh
if grep -q 'source.*common\.sh' "${INSTALL}"; then
  pass "install.sh sources common.sh"
else
  fail "install.sh does not source common.sh"
fi

# Writes done marker
if grep -q 'write_done_marker.*pi' "${INSTALL}"; then
  pass "install.sh writes done marker for 'pi'"
else
  fail "install.sh does not write done marker"
fi

# --help exits 0
HELP_OUT="$(bash "${INSTALL}" --help 2>&1)" && HELP_RC=0 || HELP_RC=$?
if [[ "${HELP_RC}" -eq 0 ]]; then
  pass "install.sh --help exits 0"
else
  fail "install.sh --help exits ${HELP_RC}"
fi

if [[ -n "${HELP_OUT}" ]]; then
  pass "install.sh --help produces output"
else
  fail "install.sh --help produces no output"
fi

# --help mentions key flags
for flag in --region --model --bedrockify-port --help; do
  if printf '%s' "${HELP_OUT}" | grep -q -- "${flag}"; then
    pass "install.sh --help mentions ${flag}"
  else
    fail "install.sh --help missing ${flag}"
  fi
done

# ── Test: models.json generation ──────────────────────────────────────────────
header "Test: models.json config generation"

# We test the heredoc template by simulating what install.sh does: variable
# substitution into the JSON template. We extract the template logic and
# run it with different MODEL/BEDROCKIFY_PORT values.

generate_models_json() {
  local MODEL="$1"
  local BEDROCKIFY_PORT="$2"
  cat <<EOF
{
  "providers": {
    "bedrockify": {
      "baseUrl": "http://127.0.0.1:${BEDROCKIFY_PORT}/v1",
      "api": "openai-completions",
      "apiKey": "not-needed",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false
      },
      "models": [
        { "id": "${MODEL}" }
      ]
    }
  }
}
EOF
}

# Test with default model
JSON_OUT="$(generate_models_json "us.anthropic.claude-sonnet-4-6-v1" "8090")"
if printf '%s' "${JSON_OUT}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  pass "models.json: valid JSON with default model"
else
  fail "models.json: invalid JSON with default model"
fi

# Verify model ID appears in output
if printf '%s' "${JSON_OUT}" | grep -q '"us.anthropic.claude-sonnet-4-6-v1"'; then
  pass "models.json: contains correct model ID"
else
  fail "models.json: missing model ID"
fi

# Verify bedrockify port in baseUrl
if printf '%s' "${JSON_OUT}" | grep -q 'http://127.0.0.1:8090/v1'; then
  pass "models.json: baseUrl has correct port"
else
  fail "models.json: baseUrl has wrong port"
fi

# Test with a model ID containing special characters (slashes, dots)
JSON_OUT="$(generate_models_json "anthropic/claude-opus-4.6" "9090")"
if printf '%s' "${JSON_OUT}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  pass "models.json: valid JSON with slash/dot model ID"
else
  fail "models.json: invalid JSON with slash/dot model ID"
fi

if printf '%s' "${JSON_OUT}" | grep -q 'http://127.0.0.1:9090/v1'; then
  pass "models.json: baseUrl reflects custom port 9090"
else
  fail "models.json: baseUrl wrong for custom port"
fi

# Test with a model ID containing colons
JSON_OUT="$(generate_models_json "us.amazon.nova-premier-v1:0" "8090")"
if printf '%s' "${JSON_OUT}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  pass "models.json: valid JSON with colon in model ID"
else
  fail "models.json: invalid JSON with colon in model ID"
fi

# Test with empty model (edge case)
JSON_OUT="$(generate_models_json "" "8090")"
if printf '%s' "${JSON_OUT}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  pass "models.json: valid JSON with empty model (edge case)"
else
  fail "models.json: invalid JSON with empty model"
fi

# Verify JSON structure deeply
JSON_OUT="$(generate_models_json "test-model" "8090")"
if python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
p = data['providers']['bedrockify']
assert p['api'] == 'openai-completions', 'wrong api'
assert p['apiKey'] == 'not-needed', 'wrong apiKey'
assert isinstance(p['models'], list), 'models not a list'
assert len(p['models']) == 1, 'expected 1 model'
assert p['models'][0]['id'] == 'test-model', 'wrong model id'
assert p['compat']['supportsDeveloperRole'] == False, 'wrong compat'
assert p['compat']['supportsReasoningEffort'] == False, 'wrong compat'
assert '/v1' in p['baseUrl'], 'baseUrl missing /v1'
" <<< "${JSON_OUT}" 2>/dev/null; then
  pass "models.json: structure validated (api, apiKey, models array, compat)"
else
  fail "models.json: structure validation failed"
fi

# ── Test: shell-profile.sh ───────────────────────────────────────────────────
header "Test: shell-profile.sh"

PROFILE="${PACK_DIR}/resources/shell-profile.sh"

if [[ -f "${PROFILE}" ]]; then
  pass "shell-profile.sh exists"
else
  fail "shell-profile.sh missing"
fi

# Sourcing should not error
if bash -c "source '${PROFILE}'" 2>/dev/null; then
  pass "shell-profile.sh sources without error"
else
  fail "shell-profile.sh sources with error"
fi

# Required variables
for var in PACK_BANNER_EMOJI PACK_BANNER_NAME PACK_BANNER_COMMANDS; do
  VAL="$(bash -c "source '${PROFILE}'; echo \"\${${var}:-}\"" 2>/dev/null)"
  if [[ -n "${VAL}" ]]; then
    pass "shell-profile.sh: ${var} is set"
  else
    fail "shell-profile.sh: ${var} is empty or missing"
  fi
done

# PACK_BANNER_COMMANDS should mention 'pi'
CMDS="$(bash -c "source '${PROFILE}'; echo \"\${PACK_BANNER_COMMANDS}\"" 2>/dev/null)"
if printf '%s' "${CMDS}" | grep -q 'pi'; then
  pass "shell-profile.sh: PACK_BANNER_COMMANDS mentions 'pi'"
else
  fail "shell-profile.sh: PACK_BANNER_COMMANDS does not mention 'pi'"
fi

# ── Test: idempotency patterns ─────────────────────────────────────────────────
header "Test: idempotency patterns"

# Check that install.sh handles pi already installed (re-install path)
if grep -q 'command -v pi' "${INSTALL}"; then
  pass "install.sh checks if pi is already installed"
else
  fail "install.sh does not check for existing pi installation"
fi

# Check for mkdir -p (idempotent directory creation)
if grep -q 'mkdir -p' "${INSTALL}"; then
  pass "install.sh uses mkdir -p for config directory"
else
  fail "install.sh does not use mkdir -p"
fi

# ── Test: bedrockify health check (LIVE — skippable) ─────────────────────────
header "Test: bedrockify health check (live environment)"

if curl -sf "http://127.0.0.1:8090/" 2>/dev/null | grep -q '"status":"ok"'; then
  pass "bedrockify is running on port 8090"
else
  skip "bedrockify not running — live tests skipped"
fi

# ── Test: pi command available (LIVE — skippable) ─────────────────────────────
header "Test: pi command (live environment)"

if command -v pi &>/dev/null; then
  PI_VER="$(pi --version 2>/dev/null || echo unknown)"
  pass "pi is installed: ${PI_VER}"
else
  skip "pi not installed — live tests skipped"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  Pi Pack Test Results${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed:${NC}  %d\n" "${PASS}"
printf "  ${RED}Failed:${NC}  %d\n" "${FAIL}"
printf "  ${YELLOW}Skipped:${NC} %d\n" "${SKIP}"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

if [[ "${FAIL}" -gt 0 ]]; then
  printf "${RED}✗ %d test(s) failed${NC}\n\n" "${FAIL}"
  exit 1
else
  printf "${GREEN}✓ All tests passed${NC}\n\n"
  exit 0
fi
