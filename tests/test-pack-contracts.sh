#!/usr/bin/env bash
# tests/test-pack-contracts.sh — CI contract validation for all agent packs
#
# Ensures every agent pack declares all variables and files expected by
# the bootstrap dispatcher (deploy/bootstrap.sh) and installer (install.sh).
#
# Checks:
#   1. shell-profile.sh defines PACK_ALIASES, PACK_BANNER_NAME, PACK_BANNER_EMOJI, PACK_BANNER_COMMANDS
#   2. manifest.yaml exists with required keys (name, version, type, description, params, provides)
#   3. manifest.yaml name matches directory name
#   4. install.sh exists, is executable, has bash shebang, references common.sh, writes done marker
#   5. resources/ directory exists
#   6. Pack is listed in registry.yaml AND registry.json
#
# Usage: bash tests/test-pack-contracts.sh
# Exit: 0 if all pass, 1 if any fail (breaks CI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKS_DIR="${SCRIPT_DIR}/packs"
REGISTRY_YAML="${PACKS_DIR}/registry.yaml"
REGISTRY_JSON="${PACKS_DIR}/registry.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0

pass() { printf "${GREEN}  ✓${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  ✗${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }
skip() { printf "${YELLOW}  ○${NC} %s\n" "$1"; SKIP=$((SKIP + 1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

# Discover ALL agent packs dynamically (not a hardcoded list)
discover_agent_packs() {
  local -a packs=()
  for dir in "${PACKS_DIR}"/*/; do
    local pack
    pack=$(basename "$dir")
    [[ "$pack" == "common.sh" ]] && continue  # not a pack dir

    # Check if it's an agent pack (has manifest with type: agent, or is in registry as agent)
    local manifest="${dir}/manifest.yaml"
    if [[ -f "$manifest" ]]; then
      local ptype
      ptype=$(python3 -c "import yaml; d=yaml.safe_load(open('${manifest}')); print(d.get('type',''))" 2>/dev/null || echo "")
      if [[ "$ptype" == "agent" ]]; then
        packs+=("$pack")
      fi
    fi
  done
  echo "${packs[@]}"
}

# Required variables that bootstrap.sh expects from shell-profile.sh
REQUIRED_SHELL_VARS=(PACK_ALIASES PACK_BANNER_NAME PACK_BANNER_EMOJI PACK_BANNER_COMMANDS)

# Required keys in manifest.yaml
REQUIRED_MANIFEST_KEYS=(name version type description params provides)

# ── Discover packs ────────────────────────────────────────────────────────────
PACKS=( $(discover_agent_packs) )

if [[ ${#PACKS[@]} -eq 0 ]]; then
  echo "No agent packs found in ${PACKS_DIR}"
  exit 1
fi

header "Discovered ${#PACKS[@]} agent pack(s): ${PACKS[*]}"

# ── Contract 1: shell-profile.sh variables ────────────────────────────────────
header "Contract: shell-profile.sh declares all required variables"

for pack in "${PACKS[@]}"; do
  local_profile="${PACKS_DIR}/${pack}/resources/shell-profile.sh"

  if [[ ! -f "$local_profile" ]]; then
    fail "${pack}: resources/shell-profile.sh does not exist"
    continue
  fi

  for var in "${REQUIRED_SHELL_VARS[@]}"; do
    # Check the variable is assigned (not just referenced)
    if grep -qE "^${var}=" "$local_profile" 2>/dev/null; then
      pass "${pack}: shell-profile.sh defines ${var}"
    else
      fail "${pack}: shell-profile.sh MISSING ${var} (bootstrap will crash with 'unbound variable')"
    fi
  done

  # Bonus: verify sourcing it doesn't error under set -u
  if bash -c "set -euo pipefail; source '$local_profile'" 2>/dev/null; then
    pass "${pack}: shell-profile.sh sources cleanly under set -euo pipefail"
  else
    fail "${pack}: shell-profile.sh errors when sourced with set -euo pipefail"
  fi
done

# ── Contract 2: manifest.yaml ────────────────────────────────────────────────
header "Contract: manifest.yaml has required keys"

for pack in "${PACKS[@]}"; do
  manifest="${PACKS_DIR}/${pack}/manifest.yaml"

  if [[ ! -f "$manifest" ]]; then
    fail "${pack}: manifest.yaml does not exist"
    continue
  fi

  # Valid YAML
  if python3 -c "import yaml; yaml.safe_load(open('${manifest}'))" 2>/dev/null; then
    pass "${pack}: manifest.yaml is valid YAML"
  else
    fail "${pack}: manifest.yaml is invalid YAML"
    continue
  fi

  # Required keys
  for key in "${REQUIRED_MANIFEST_KEYS[@]}"; do
    if python3 -c "import yaml,sys; d=yaml.safe_load(open('${manifest}')); sys.exit(0 if '${key}' in d else 1)" 2>/dev/null; then
      pass "${pack}: manifest.yaml has '${key}'"
    else
      fail "${pack}: manifest.yaml MISSING '${key}'"
    fi
  done

  # Name matches directory
  if python3 -c "import yaml,sys; d=yaml.safe_load(open('${manifest}')); sys.exit(0 if d.get('name')=='${pack}' else 1)" 2>/dev/null; then
    pass "${pack}: manifest name matches directory"
  else
    fail "${pack}: manifest name does NOT match directory '${pack}'"
  fi
done

# ── Contract 3: install.sh ───────────────────────────────────────────────────
header "Contract: install.sh exists and is well-formed"

for pack in "${PACKS[@]}"; do
  install="${PACKS_DIR}/${pack}/install.sh"

  if [[ ! -f "$install" ]]; then
    fail "${pack}: install.sh does not exist"
    continue
  fi

  pass "${pack}: install.sh exists"

  if [[ -x "$install" ]]; then
    pass "${pack}: install.sh is executable"
  else
    fail "${pack}: install.sh is NOT executable (chmod +x needed)"
  fi

  # Bash shebang
  _shebang=$(head -1 "$install")
  if [[ "$_shebang" == "#!/usr/bin/env bash" || "$_shebang" == "#!/bin/bash" ]]; then
    pass "${pack}: install.sh has bash shebang"
  else
    fail "${pack}: install.sh has unexpected shebang: ${_shebang}"
  fi

  # References common.sh
  if grep -q 'common\.sh' "$install" 2>/dev/null; then
    pass "${pack}: install.sh references common.sh"
  else
    fail "${pack}: install.sh does NOT reference common.sh"
  fi

  # Writes done marker
  if grep -q 'write_done_marker\|pack-.*-done' "$install" 2>/dev/null; then
    pass "${pack}: install.sh writes done marker"
  else
    fail "${pack}: install.sh does NOT write done marker"
  fi
done

# ── Contract 4: resources/ directory ─────────────────────────────────────────
header "Contract: resources/ directory exists"

for pack in "${PACKS[@]}"; do
  if [[ -d "${PACKS_DIR}/${pack}/resources" ]]; then
    pass "${pack}: resources/ directory exists"
  else
    fail "${pack}: resources/ directory MISSING"
  fi
done

# ── Contract 5: pack listed in registries ────────────────────────────────────
header "Contract: pack listed in registry.yaml and registry.json"

for pack in "${PACKS[@]}"; do
  # registry.yaml
  if python3 -c "import yaml,sys; d=yaml.safe_load(open('${REGISTRY_YAML}')); sys.exit(0 if '${pack}' in d.get('packs',{}) else 1)" 2>/dev/null; then
    pass "${pack}: listed in registry.yaml"
  else
    fail "${pack}: NOT listed in registry.yaml"
  fi

  # registry.json
  if [[ -f "$REGISTRY_JSON" ]]; then
    if jq -e --arg p "$pack" '.packs[$p]' "$REGISTRY_JSON" >/dev/null 2>&1; then
      pass "${pack}: listed in registry.json"
    else
      fail "${pack}: NOT listed in registry.json"
    fi
  else
    skip "${pack}: registry.json not found"
  fi
done

# ── Contract 5b: registry.json is in sync with registry.yaml ─────────────────
# The YAML is the source of truth; the JSON is generated. Run scripts/sync-registry
# to regenerate. This contract catches manual edits to registry.json that drift
# from the YAML (and catches missing per-pack fields).
header "Contract: registry.json is in sync with registry.yaml"

if [[ -x "${SCRIPT_DIR}/scripts/sync-registry" ]]; then
  if bash "${SCRIPT_DIR}/scripts/sync-registry" --check >/dev/null 2>&1; then
    pass "registry.json matches registry.yaml (run: bash scripts/sync-registry)"
  else
    fail "registry.json is OUT OF SYNC with registry.yaml — run: bash scripts/sync-registry"
  fi
else
  skip "scripts/sync-registry not found"
fi

# ── Contract 6: health_check in manifest (warning only) ─────────────────────
header "Contract: health_check defined (recommended)"

for pack in "${PACKS[@]}"; do
  manifest="${PACKS_DIR}/${pack}/manifest.yaml"
  [[ -f "$manifest" ]] || continue

  if python3 -c "import yaml,sys; d=yaml.safe_load(open('${manifest}')); sys.exit(0 if 'health_check' in d else 1)" 2>/dev/null; then
    pass "${pack}: manifest has health_check"
  else
    skip "${pack}: manifest missing health_check (recommended but not required)"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  Pack Contract Validation${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed:${NC}  %d\n" "${PASS}"
printf "  ${RED}Failed:${NC}  %d\n" "${FAIL}"
printf "  ${YELLOW}Skipped:${NC} %d\n" "${SKIP}"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

if [[ "${FAIL}" -gt 0 ]]; then
  printf "${RED}✗ %d contract violation(s) — fix before merging${NC}\n\n" "${FAIL}"
  exit 1
else
  printf "${GREEN}✓ All pack contracts satisfied${NC}\n\n"
  exit 0
fi
