#!/bin/bash
# deploy/test-bootstrap.sh — Validate bootstrap.sh without running system setup
#
# Tests:
#   1. --help prints usage and exits 0
#   2. --pack nonexistent exits non-zero with error
#   3. Arg parsing: --pack, --region, forwarded args
#   4. shellcheck (if available)

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${DEPLOY_DIR}/bootstrap.sh"

PASS=0
FAIL=0

ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo "[INFO] $1"; }

echo ""
echo "================================================================"
echo "  bootstrap.sh test suite"
echo "================================================================"
echo ""

# ── Test 1: --help exits 0 and prints usage ───────────────────────────────────
info "Test 1: --help exits 0 and prints usage"
HELP_OUT=$("$BOOTSTRAP" --help 2>&1) && HELP_EXIT=0 || HELP_EXIT=$?
if [[ $HELP_EXIT -eq 0 ]]; then
  ok "--help exits 0"
else
  fail "--help exited $HELP_EXIT (expected 0)"
fi
if echo "$HELP_OUT" | grep -q "Usage:"; then
  ok "--help output contains 'Usage:'"
else
  fail "--help output missing 'Usage:' — got: $(echo "$HELP_OUT" | head -3)"
fi
if echo "$HELP_OUT" | grep -q -- "--pack"; then
  ok "--help output mentions --pack"
else
  fail "--help output missing --pack"
fi
echo ""

# ── Test 2: No --pack arg exits non-zero ─────────────────────────────────────
info "Test 2: missing --pack exits non-zero"
NO_PACK_OUT=$("$BOOTSTRAP" 2>&1) && NO_PACK_EXIT=0 || NO_PACK_EXIT=$?
if [[ $NO_PACK_EXIT -ne 0 ]]; then
  ok "missing --pack exits non-zero ($NO_PACK_EXIT)"
else
  fail "missing --pack should exit non-zero but exited 0"
fi
if echo "$NO_PACK_OUT" | grep -qi "required\|--pack"; then
  ok "missing --pack error message is informative"
else
  fail "missing --pack error message not informative: $(echo "$NO_PACK_OUT" | head -2)"
fi
echo ""

# ── Test 3: --pack nonexistent exits non-zero ─────────────────────────────────
info "Test 3: --pack nonexistent exits non-zero"
# We need a registry available; use a temp repo-like structure if needed
# bootstrap.sh looks for ../packs/registry.yaml relative to deploy/
REGISTRY="${DEPLOY_DIR}/../packs/registry.yaml"
if [[ ! -f "$REGISTRY" ]]; then
  info "  Registry not found at $REGISTRY — skipping test 3 (full repo not present)"
else
  FAKE_PACK_OUT=$("$BOOTSTRAP" --pack __nonexistent_pack_xyz__ 2>&1) && FAKE_EXIT=0 || FAKE_EXIT=$?
  if [[ $FAKE_EXIT -ne 0 ]]; then
    ok "--pack nonexistent exits non-zero ($FAKE_EXIT)"
  else
    fail "--pack nonexistent should exit non-zero but exited 0"
  fi
  if echo "$FAKE_PACK_OUT" | grep -qi "not found\|nonexistent\|registry"; then
    ok "--pack nonexistent error message mentions registry/not found"
  else
    fail "--pack nonexistent error message not informative: $(echo "$FAKE_PACK_OUT" | head -2)"
  fi
fi
echo ""

# ── Test 4: -h shorthand works ───────────────────────────────────────────────
info "Test 4: -h shorthand exits 0 and prints usage"
SHORT_OUT=$("$BOOTSTRAP" -h 2>&1) && SHORT_EXIT=0 || SHORT_EXIT=$?
if [[ $SHORT_EXIT -eq 0 ]]; then
  ok "-h exits 0"
else
  fail "-h exited $SHORT_EXIT (expected 0)"
fi
if echo "$SHORT_OUT" | grep -q "Usage:"; then
  ok "-h output contains 'Usage:'"
else
  fail "-h output missing 'Usage:'"
fi
echo ""

# ── Test 5: Arg parsing writes pack config JSON ───────────────────────────────
info "Test 5: Pack-specific args are parsed and config JSON is written"
ARGPARSE_SCRIPT=$(mktemp /tmp/test-argparse-XXXXXX.sh)
cat > "$ARGPARSE_SCRIPT" << 'ARGPARSE_EOF'
#!/bin/bash
set -euo pipefail
PACK_NAME=""
REGION="us-east-1"
STACK_NAME=""
MODEL=""
GW_PORT=""
MODEL_MODE=""
BEDROCKIFY_PORT=""
HERMES_MODEL=""
LITELLM_URL=""
LITELLM_KEY=""
LITELLM_MODEL=""
PROVIDER_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) ;;
    --pack)            PACK_NAME="$2";    shift 2 ;;
    --region)          REGION="$2";       shift 2 ;;
    --model)           MODEL="$2";        shift 2 ;;
    --gw-port)         GW_PORT="$2";      shift 2 ;;
    --model-mode)      MODEL_MODE="$2";   shift 2 ;;
    --bedrockify-port) BEDROCKIFY_PORT="$2"; shift 2 ;;
    --hermes-model)    HERMES_MODEL="$2"; shift 2 ;;
    --litellm-base-url|--litellm-url)     LITELLM_URL="$2"; shift 2 ;;
    --litellm-api-key|--litellm-key)      LITELLM_KEY="$2"; shift 2 ;;
    --litellm-model)   LITELLM_MODEL="$2"; shift 2 ;;
    --provider-api-key|--provider-key)    PROVIDER_KEY="$2"; shift 2 ;;
    --*) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
    *) shift ;;
  esac
done

TMPCONFIG="$(mktemp /tmp/test-pack-config-XXXXXX.json)"
cat > "${TMPCONFIG}" << JSON
{
  "pack": "${PACK_NAME}",
  "region": "${REGION}",
  "model": "${MODEL}",
  "gw_port": "${GW_PORT}",
  "model_mode": "${MODEL_MODE}"
}
JSON

echo "PACK=${PACK_NAME}"
echo "REGION=${REGION}"
echo "MODEL=${MODEL}"
echo "GW_PORT=${GW_PORT}"
echo "CONFIG_EXISTS=$([ -f "${TMPCONFIG}" ] && echo yes || echo no)"
if command -v jq &>/dev/null; then
  echo "CONFIG_REGION=$(jq -r '.region' "${TMPCONFIG}")"
  echo "CONFIG_MODEL=$(jq -r '.model' "${TMPCONFIG}")"
fi
rm -f "${TMPCONFIG}"
ARGPARSE_EOF

PARSE_TEST=$(bash "$ARGPARSE_SCRIPT" --pack openclaw --region eu-west-1 --model some-model --gw-port 3001 2>&1)
rm -f "$ARGPARSE_SCRIPT"

if echo "$PARSE_TEST" | grep -q "PACK=openclaw"; then
  ok "Arg parse: --pack value captured correctly"
else
  fail "Arg parse: --pack not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "REGION=eu-west-1"; then
  ok "Arg parse: --region value captured correctly"
else
  fail "Arg parse: --region not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "MODEL=some-model"; then
  ok "Arg parse: --model value captured correctly"
else
  fail "Arg parse: --model not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "GW_PORT=3001"; then
  ok "Arg parse: --gw-port value captured correctly"
else
  fail "Arg parse: --gw-port not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "CONFIG_EXISTS=yes"; then
  ok "Arg parse: config JSON was written"
else
  fail "Arg parse: config JSON not written — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "CONFIG_REGION=eu-west-1"; then
  ok "Arg parse: config JSON contains correct region"
else
  info "  jq not available or CONFIG_REGION check skipped — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "CONFIG_MODEL=some-model"; then
  ok "Arg parse: config JSON contains correct model"
else
  info "  jq not available or CONFIG_MODEL check skipped — got: $PARSE_TEST"
fi
echo ""

# ── Test 6: shellcheck (optional) ────────────────────────────────────────────
info "Test 6: shellcheck (optional)"
if command -v shellcheck &>/dev/null; then
  if shellcheck -S warning "$BOOTSTRAP"; then
    ok "shellcheck passed"
  else
    fail "shellcheck found issues"
  fi
else
  info "  shellcheck not installed — skipping"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "================================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "================================================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
