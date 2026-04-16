#!/usr/bin/env bash
# packs/codex-cli/test.sh — offline tests for codex-cli pack
# Validates manifest structure, install.sh syntax, shell-profile completeness.

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
assert d['name'] == 'codex-cli', f\"name is {d['name']}\"
" 2>/dev/null; then
  pass "manifest name is codex-cli"
else
  fail "manifest name != codex-cli"
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

# ── shell-profile.sh ─────────────────────────────────────────────────────────
header "resources/shell-profile.sh"
PROFILE="${PACK_DIR}/resources/shell-profile.sh"

if [[ -f "${PROFILE}" ]]; then
  pass "shell-profile.sh exists"
else
  fail "shell-profile.sh missing"
fi

for var in PACK_ALIASES PACK_BANNER_NAME PACK_BANNER_EMOJI PACK_BANNER_COMMANDS; do
  if grep -q "^${var}=" "${PROFILE}" 2>/dev/null; then
    pass "shell-profile defines ${var}"
  else
    fail "shell-profile missing ${var}"
  fi
done

# ── Registry consistency ──────────────────────────────────────────────────────
header "registry consistency"
REPO_DIR="$(cd "${PACK_DIR}/../.." && pwd)"

if grep -q "^  codex-cli:" "${REPO_DIR}/packs/registry.yaml" 2>/dev/null; then
  pass "codex-cli listed in registry.yaml"
else
  fail "codex-cli NOT in registry.yaml"
fi

if python3 -c "
import json
d = json.load(open('${REPO_DIR}/packs/registry.json'))
assert 'codex-cli' in d.get('packs', {}), 'not in packs'
" 2>/dev/null; then
  pass "codex-cli listed in registry.json"
else
  fail "codex-cli NOT in registry.json"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n\033[1;36m────────────────────────────────────────\033[0m\n"
printf "  Passed: \033[0;32m%d\033[0m\n" "${passed}"
printf "  Failed: \033[0;31m%d\033[0m\n" "${failed}"
if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
