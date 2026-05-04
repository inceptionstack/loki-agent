#!/usr/bin/env bash
# packs/openclaw/test.sh — Unit tests for the OpenClaw pack
#
# Validates manifest structure, install.sh interface, and the
# telemetron sidecar block's silent-install contract WITHOUT requiring
# OpenClaw, systemd, Bedrock, or network access.
#
# Usage: bash packs/openclaw/test.sh
# Exit: 0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"
PACKS_DIR="${SCRIPT_DIR}/.."

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

pass()   { printf "${GREEN}  ✓${NC} %s\n" "$1"; PASS=$((PASS+1)); }
fail()   { printf "${RED}  ✗${NC} %s\n" "$1"; FAIL=$((FAIL+1)); }
skip()   { printf "${YELLOW}  ○${NC} %s (skipped)\n" "$1"; SKIP=$((SKIP+1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

# ── Test: manifest.yaml structure ─────────────────────────────────────────────
header "Test: manifest.yaml"

MANIFEST="${PACK_DIR}/manifest.yaml"

if [[ -f "${MANIFEST}" ]]; then
  pass "manifest.yaml exists"
else
  fail "manifest.yaml missing"
fi

if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  if python3 -c "import yaml; yaml.safe_load(open('${MANIFEST}'))" 2>/dev/null; then
    pass "manifest.yaml is valid YAML"
  else
    fail "manifest.yaml is invalid YAML"
  fi

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

  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if data.get('name') == 'openclaw' else 1)
" 2>/dev/null; then
    pass "manifest.yaml name matches folder (openclaw)"
  else
    fail "manifest.yaml name does not match folder"
  fi

  # skip-telemetron param must exist
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
names = [p.get('name') for p in data.get('params', [])]
sys.exit(0 if 'skip-telemetron' in names else 1)
" 2>/dev/null; then
    pass "manifest.yaml has skip-telemetron param"
  else
    fail "manifest.yaml missing skip-telemetron param"
  fi
else
  skip "manifest.yaml YAML tests: python3 or pyyaml not available"
fi

# ── Test: install.sh interface ────────────────────────────────────────────────
header "Test: install.sh interface"

INSTALL="${PACK_DIR}/install.sh"

if [[ -f "${INSTALL}" ]]; then
  pass "install.sh exists"
else
  fail "install.sh missing"
fi

SHEBANG="$(head -1 "${INSTALL}")"
if [[ "${SHEBANG}" == "#!/usr/bin/env bash" ]]; then
  pass "install.sh has correct shebang"
else
  fail "install.sh has unexpected shebang: ${SHEBANG}"
fi

if bash -n "${INSTALL}" 2>/dev/null; then
  pass "install.sh passes bash -n syntax check"
else
  fail "install.sh has bash syntax errors"
fi

if grep -q 'source.*common\.sh' "${INSTALL}"; then
  pass "install.sh sources common.sh"
else
  fail "install.sh does not source common.sh"
fi

if grep -q 'write_done_marker.*openclaw' "${INSTALL}"; then
  pass "install.sh writes done marker for 'openclaw'"
else
  fail "install.sh does not write done marker"
fi

# --help exits 0 and mentions key flags
HELP_OUT="$(bash "${INSTALL}" --help 2>&1)" && HELP_RC=0 || HELP_RC=$?
if [[ "${HELP_RC}" -eq 0 ]]; then
  pass "install.sh --help exits 0"
else
  fail "install.sh --help exits ${HELP_RC}"
fi

for flag in --region --model --port --model-mode --skip-telemetron --help; do
  if printf '%s' "${HELP_OUT}" | grep -q -- "${flag}"; then
    pass "install.sh --help mentions ${flag}"
  else
    fail "install.sh --help missing ${flag}"
  fi
done

# --skip-telemetron arg is parsed
if grep -q -- '--skip-telemetron' "${INSTALL}"; then
  pass "install.sh parses --skip-telemetron arg"
else
  fail "install.sh does not parse --skip-telemetron"
fi

# ── Test: telemetron sidecar contract ─────────────────────────────────────────
# The telemetron block must:
#   1. Be silent on stdout/stderr regardless of outcome (log-only)
#   2. Use pipefail so curl failures are not masked as success
#   3. Bound itself with a hard timeout so a hung network cannot wedge install
#   4. Never trip the outer `set -euo pipefail`
#   5. Honor skip flags (LOWKEY_TELEMETRY=0, DO_NOT_TRACK=1, --skip-telemetron)
header "Test: telemetron sidecar contract"

if grep -q 'install_telemetron' "${INSTALL}"; then
  pass "install.sh defines install_telemetron function"
else
  fail "install.sh missing install_telemetron function"
fi

if grep -q 'timeout 30 bash -o pipefail -c' "${INSTALL}"; then
  pass "install.sh wraps telemetron install in timeout 30 + pipefail"
else
  fail "install.sh missing timeout/pipefail guard on telemetron install"
fi

if grep -q 'INSTALL_LOG:-/tmp/loki-install.log' "${INSTALL}"; then
  pass "install.sh uses defaulted INSTALL_LOG (set -u safe)"
else
  fail "install.sh does not default INSTALL_LOG"
fi

if grep -q 'PACK_ARG_SKIP_TELEMETRON' "${INSTALL}"; then
  pass "install.sh honors --skip-telemetron via PACK_ARG_SKIP_TELEMETRON"
else
  fail "install.sh does not honor PACK_ARG_SKIP_TELEMETRON"
fi

if grep -q 'LOWKEY_TELEMETRY.*DO_NOT_TRACK\|DO_NOT_TRACK.*LOWKEY_TELEMETRY' "${INSTALL}" \
   || { grep -q 'LOWKEY_TELEMETRY' "${INSTALL}" && grep -q 'DO_NOT_TRACK' "${INSTALL}"; }; then
  pass "install.sh honors LOWKEY_TELEMETRY and DO_NOT_TRACK opt-outs"
else
  fail "install.sh missing lowkey telemetry opt-out honor"
fi

if grep -q '|| true' "${INSTALL}" && grep -q 'install_telemetron' "${INSTALL}"; then
  pass "install.sh subshell has outer || true safety net"
else
  fail "install.sh missing outer || true on install_telemetron"
fi

# ── Test: telemetron block actually stays silent and idempotent ──────────────
# Isolated smoke test: extract the function, source it with guard flags set,
# assert zero stdout/stderr to the caller.
header "Test: telemetron block runtime behavior (isolated)"

TMP_FN="$(mktemp)"
TMP_LOG="$(mktemp)"
trap 'rm -f "$TMP_FN" "$TMP_LOG"' EXIT

# Grab the function definition from install.sh
if sed -n '/^# ── Telemetron sidecar/,/^install_telemetron$/p' "${INSTALL}" > "${TMP_FN}" \
   && grep -q 'install_telemetron' "${TMP_FN}"; then
  pass "isolated telemetron block extracted for runtime tests"
else
  fail "could not extract telemetron block for runtime tests"
  # Can't continue runtime asserts if extraction fails
  TMP_FN=""
fi

if [[ -n "${TMP_FN}" ]]; then
  # Scenario A: PACK_ARG_SKIP_TELEMETRON=true — instant skip, no output
  OUT_A="$(
    INSTALL_LOG="${TMP_LOG}" PACK_ARG_SKIP_TELEMETRON=true bash -c "
      set -euo pipefail
      source '${TMP_FN}'
    " 2>&1
  )" || true
  if [[ -z "${OUT_A}" ]]; then
    pass "skip-telemetron=true: zero user-visible output"
  else
    fail "skip-telemetron=true: unexpected output: ${OUT_A}"
  fi
  if grep -q '\[telemetron\] skip: --skip-telemetron' "${TMP_LOG}"; then
    pass "skip-telemetron=true: log records skip reason"
  else
    fail "skip-telemetron=true: log missing skip reason"
  fi

  # Scenario B: LOWKEY_TELEMETRY=0 — env opt-out
  : > "${TMP_LOG}"
  OUT_B="$(
    INSTALL_LOG="${TMP_LOG}" LOWKEY_TELEMETRY=0 PACK_ARG_SKIP_TELEMETRON=false bash -c "
      set -euo pipefail
      source '${TMP_FN}'
    " 2>&1
  )" || true
  if [[ -z "${OUT_B}" ]]; then
    pass "LOWKEY_TELEMETRY=0: zero user-visible output"
  else
    fail "LOWKEY_TELEMETRY=0: unexpected output: ${OUT_B}"
  fi
  if grep -q '\[telemetron\] skip: lowkey telemetry opt-out' "${TMP_LOG}"; then
    pass "LOWKEY_TELEMETRY=0: log records opt-out reason"
  else
    fail "LOWKEY_TELEMETRY=0: log missing opt-out reason"
  fi

  # Scenario C: outer `set -euo pipefail` must NOT be tripped
  : > "${TMP_LOG}"
  if bash -c "
    set -euo pipefail
    INSTALL_LOG='${TMP_LOG}' PACK_ARG_SKIP_TELEMETRON=true
    export INSTALL_LOG PACK_ARG_SKIP_TELEMETRON
    source '${TMP_FN}'
    echo AFTER_OK
  " 2>/dev/null | grep -q AFTER_OK; then
    pass "telemetron block does not trip outer set -euo pipefail"
  else
    fail "telemetron block trips outer set -euo pipefail"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "Summary"
printf "  ${GREEN}Passed:${NC}  %d\n" "$PASS"
printf "  ${RED}Failed:${NC}  %d\n" "$FAIL"
printf "  ${YELLOW}Skipped:${NC} %d\n" "$SKIP"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
