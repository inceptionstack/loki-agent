#!/usr/bin/env bash
# packs/kiro-cli/test.sh — offline tests for kiro-cli pack
# Validates manifest structure, install.sh syntax, v2 auth features.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"

passed=0
failed=0
pass() { printf "  \033[0;32m✓\033[0m %s\n" "$1"; passed=$((passed+1)); }
fail() { printf "  \033[0;31m✗\033[0m %s\n" "$1"; failed=$((failed+1)); }
header() { printf "\n\033[1;36m── %s ──\033[0m\n" "$1"; }

# ── manifest.yaml ────────────────────────────────────────────────────────────
header "manifest.yaml"
MANIFEST="${PACK_DIR}/manifest.yaml"

if [[ -f "${MANIFEST}" ]]; then
  pass "manifest.yaml exists"
else
  fail "manifest.yaml missing"
  exit 1
fi

if python3 -c "import yaml; yaml.safe_load(open('${MANIFEST}'))" 2>/dev/null; then
  pass "manifest.yaml is valid YAML"
else
  fail "manifest.yaml is invalid YAML"
fi

for key in name version type description deps requirements params health_check provides; do
  if python3 -c "import yaml; d=yaml.safe_load(open('${MANIFEST}')); exit(0 if '$key' in d else 1)" 2>/dev/null; then
    pass "manifest has '$key' key"
  else
    fail "manifest missing '$key' key"
  fi
done

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
assert d['name'] == 'kiro-cli', f\"name is {d['name']}\"
" 2>/dev/null; then
  pass "manifest name is kiro-cli"
else
  fail "manifest name != kiro-cli"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
assert d['version'].startswith('2.'), f\"version is {d['version']}, expected 2.x\"
" 2>/dev/null; then
  pass "manifest version is 2.x"
else
  fail "manifest version is not 2.x"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
names = [p['name'] for p in d.get('params', [])]
assert 'kiro-api-key' in names, f\"missing kiro-api-key param (got {names})\"
assert 'from-secret' in names, f\"missing from-secret param (got {names})\"
" 2>/dev/null; then
  pass "manifest has v2 auth params (kiro-api-key, from-secret)"
else
  fail "manifest missing v2 auth params"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
for p in d.get('params', []):
    assert 'default' in p, f\"param {p.get('name','?')} missing default\"
" 2>/dev/null; then
  pass "all params have default"
else
  fail "some params missing default"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
assert d.get('deps', []) == [], 'deps should be []'
" 2>/dev/null; then
  pass "manifest deps is empty (no bedrockify)"
else
  fail "manifest deps should be empty"
fi

# ── install.sh ───────────────────────────────────────────────────────────────
header "install.sh"
INSTALL="${PACK_DIR}/install.sh"

if [[ -f "${INSTALL}" ]]; then
  pass "install.sh exists"
else
  fail "install.sh missing"
  exit 1
fi

if [[ -x "${INSTALL}" ]]; then
  pass "install.sh is executable"
else
  fail "install.sh is NOT executable"
fi

if bash -n "${INSTALL}" 2>/dev/null; then
  pass "install.sh bash syntax OK"
else
  fail "install.sh has bash syntax errors"
fi

if grep -q "set -euo pipefail" "${INSTALL}"; then
  pass "install.sh uses set -euo pipefail"
else
  fail "install.sh missing set -euo pipefail"
fi

if grep -q 'source "${SCRIPT_DIR}/../common.sh"' "${INSTALL}"; then
  pass "install.sh sources common.sh"
else
  fail "install.sh does not source common.sh"
fi

if grep -q 'write_done_marker' "${INSTALL}"; then
  pass "install.sh calls write_done_marker"
else
  fail "install.sh does not call write_done_marker"
fi

if bash "${INSTALL}" --help >/dev/null 2>&1; then
  pass "install.sh --help exits 0"
else
  fail "install.sh --help does not exit 0"
fi

# ── arg parser (exit codes) ──────────────────────────────────────────────────
header "arg parser exit codes"

if ( bash "${INSTALL}" --bogus >/dev/null 2>&1 ); then
  fail "install.sh --bogus should exit non-zero"
else
  ec=$?
  [[ "$ec" == "2" ]] && pass "install.sh --bogus exits 2" || fail "install.sh --bogus exits $ec (want 2)"
fi

if ( bash "${INSTALL}" --kiro-api-key >/dev/null 2>&1 ); then
  fail "install.sh --kiro-api-key (no value) should exit non-zero"
else
  ec=$?
  [[ "$ec" == "2" ]] && pass "install.sh --kiro-api-key (no value) exits 2" || fail "--kiro-api-key (no value) exits $ec"
fi

if ( bash "${INSTALL}" some_positional >/dev/null 2>&1 ); then
  fail "install.sh positional should exit non-zero"
else
  ec=$?
  [[ "$ec" == "2" ]] && pass "install.sh positional exits 2" || fail "positional exits $ec"
fi

# ── v2 feature signals in install.sh ─────────────────────────────────────────
header "v2 feature signals"

if grep -q "KIRO_API_KEY" "${INSTALL}"; then
  pass "install.sh mentions KIRO_API_KEY (headless mode)"
else
  fail "install.sh does not reference KIRO_API_KEY"
fi

if grep -q '\-\-from\-secret' "${INSTALL}"; then
  pass "install.sh supports --from-secret (Secrets Manager resolve)"
else
  fail "install.sh missing --from-secret"
fi

if grep -q 'no-interactive' "${INSTALL}"; then
  pass "install.sh docs mention --no-interactive (v2 headless flag)"
else
  fail "install.sh docs miss --no-interactive"
fi

# ── shell-profile.sh ─────────────────────────────────────────────────────────
header "resources/shell-profile.sh"
PROFILE="${PACK_DIR}/resources/shell-profile.sh"

if [[ -f "${PROFILE}" ]]; then
  pass "shell-profile.sh exists"
else
  fail "shell-profile.sh missing"
fi

# ── Registry consistency ──────────────────────────────────────────────────────
header "registry consistency"
REPO_DIR="$(cd "${PACK_DIR}/../.." && pwd)"

if grep -q "^  kiro-cli:" "${REPO_DIR}/packs/registry.yaml" 2>/dev/null; then
  pass "kiro-cli listed in registry.yaml"
else
  fail "kiro-cli NOT in registry.yaml"
fi

if python3 -c "
import json
d = json.load(open('${REPO_DIR}/packs/registry.json'))
assert 'kiro-cli' in d.get('packs', {}), 'not in packs'
" 2>/dev/null; then
  pass "kiro-cli listed in registry.json"
else
  fail "kiro-cli NOT in registry.json"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n\033[1;36m────────────────────────────────────────\033[0m\n"
printf "  Passed: \033[0;32m%d\033[0m\n" "${passed}"
printf "  Failed: \033[0;31m%d\033[0m\n" "${failed}"
if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
