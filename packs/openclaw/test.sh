#!/usr/bin/env bash
# packs/openclaw/test.sh — Unit tests for the OpenClaw pack
#
# Validates manifest, install.sh --help/arg-parsing interface, and the
# telemetron sidecar block's observable contract. The sidecar tests
# exercise the block by sourcing it under an isolated PATH with stubbed
# binaries (curl, systemctl, uname, timeout) — not by grep'ing source
# text. No network, no sudo, no systemd, no OpenClaw required.
#
# Usage: bash packs/openclaw/test.sh
# Exit:  0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"

# ── Test harness ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0; FAIL=0; SKIP=0
pass()   { printf "${GREEN}  ✓${NC} %s\n" "$1"; PASS=$((PASS+1)); }
fail()   { printf "${RED}  ✗${NC} %s\n" "$1"; FAIL=$((FAIL+1)); }
skip()   { printf "${YELLOW}  ○${NC} %s (skipped)\n" "$1"; SKIP=$((SKIP+1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

INSTALL="${PACK_DIR}/install.sh"
MANIFEST="${PACK_DIR}/manifest.yaml"

# ── Test: manifest.yaml structure ─────────────────────────────────────────────
header "Test: manifest.yaml"

[[ -f "${MANIFEST}" ]] && pass "manifest.yaml exists" || fail "manifest.yaml missing"

if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  python3 - "${MANIFEST}" <<'PY' && pass "manifest.yaml is valid YAML and has required keys + skip-telemetron" || fail "manifest.yaml structure invalid"
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
required = ["name","version","type","description","deps","params","health_check","provides"]
missing = [k for k in required if k not in data]
if missing: sys.exit(f"missing keys: {missing}")
if data.get("name") != "openclaw": sys.exit("name mismatch")
names = [p.get("name") for p in data.get("params", [])]
if "skip-telemetron" not in names: sys.exit("skip-telemetron param missing")
PY
else
  skip "manifest.yaml YAML tests: python3 or pyyaml not available"
fi

# ── Test: install.sh interface ────────────────────────────────────────────────
header "Test: install.sh interface"

[[ -f "${INSTALL}" ]] && pass "install.sh exists" || fail "install.sh missing"
[[ "$(head -1 "${INSTALL}")" = "#!/usr/bin/env bash" ]] && pass "install.sh has correct shebang" || fail "install.sh has wrong shebang"
bash -n "${INSTALL}" 2>/dev/null && pass "install.sh passes bash -n" || fail "install.sh has syntax errors"

# --help exits 0 and mentions every user-facing flag
HELP_OUT="$(bash "${INSTALL}" --help 2>&1)" && HELP_RC=0 || HELP_RC=$?
[[ "${HELP_RC}" -eq 0 ]] && pass "install.sh --help exits 0" || fail "install.sh --help exits ${HELP_RC}"

for flag in --region --model --port --model-mode --skip-telemetron --help; do
  printf '%s' "${HELP_OUT}" | grep -q -- "${flag}" \
    && pass "install.sh --help mentions ${flag}" \
    || fail "install.sh --help missing ${flag}"
done

# --skip-telemetron actually sets PACK_ARG_SKIP_TELEMETRON when parsed.
# We prove this by invoking install.sh with --help AFTER --skip-telemetron —
# arg parsing runs first, then help short-circuits. This catches the case
# where --skip-telemetron is in help text but not actually wired to the
# arg loop. (If arg parsing rejected --skip-telemetron, we'd get rc != 0.)
bash "${INSTALL}" --skip-telemetron --help >/dev/null 2>&1 \
  && pass "install.sh accepts --skip-telemetron in arg stream" \
  || fail "install.sh rejects --skip-telemetron"

# ── Test: telemetron sidecar contract (behavior, not text) ────────────────────
# Invariants we prove by running the block with stubbed binaries:
#
#   I1. Silent:   zero bytes on stdout AND stderr, regardless of outcome.
#   I2. Logged:   every outcome writes a tagged line to $INSTALL_LOG.
#   I3. Bounded:  a real curl failure surfaces as non-zero rc in the log
#                 (proves pipefail: without it, rc would always be 0).
#   I4. Capped:   a hanging inner step is killed via the outer timeout.
#   I5. Safe:     the block never trips the caller's `set -euo pipefail`.
#   I6. Opt-outs: every documented opt-out skips cleanly (4 paths).
header "Test: telemetron sidecar contract (behavior)"

TEL_TMP="$(mktemp -d)"
trap 'rm -rf "$TEL_TMP"' EXIT

# Extract the telemetron function into a standalone sourceable file.
# Anchors: `# ── Telemetron sidecar` header → `install_telemetron` invocation.
TEL_FN="${TEL_TMP}/telemetron.fn.sh"
sed -n '/^# ── Telemetron sidecar/,/^install_telemetron$/p' "${INSTALL}" > "${TEL_FN}"
if grep -q '^install_telemetron() {' "${TEL_FN}" && grep -q '^install_telemetron$' "${TEL_FN}"; then
  pass "telemetron block is extractable"
else
  fail "telemetron block extraction failed — anchors moved?"
  exit 1
fi

# mk_fakes: populate a directory with passthrough symlinks to real coreutils
# + a stub systemctl (present + exit 0). Callers override individual bins.
mk_fakes() {
  local dir="$1"
  mkdir -p "${dir}"
  # Comprehensive coreutils list — PATH is strict (only this dir).
  local needed=(date printf uname timeout bash sh grep sed cat rm mkdir touch
                env awk sleep chmod tr head tail sort uniq wc cut mktemp dirname
                basename id whoami tee xargs)
  for b in "${needed[@]}"; do
    local src; src="$(command -v "$b" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "${dir}/$b"
  done
  # systemctl stub: present + no-op. The block only uses `command -v systemctl`.
  printf '#!/bin/sh\nexit 0\n' > "${dir}/systemctl"; chmod +x "${dir}/systemctl"
}

# tel_run: execute the block under an isolated env. Captures stdout/stderr
# separately so we can assert I1 (silent) and I2 (logged).
#
# Usage: tel_run <ENV_KV...> -- <PATH_dir_with_fakes>
# Result: $TEL_STDOUT (file), $TEL_STDERR (file), $TEL_RC (int), $TEL_LOG (file).
tel_run() {
  local envs=() fake_path=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" = "--" ]]; then shift; fake_path="$1"; shift; break
    else envs+=("$1"); shift; fi
  done
  TEL_LOG="${TEL_TMP}/log.$$.$RANDOM"
  TEL_STDOUT="${TEL_TMP}/out.$$.$RANDOM"
  TEL_STDERR="${TEL_TMP}/err.$$.$RANDOM"
  : > "${TEL_LOG}"; : > "${TEL_STDOUT}"; : > "${TEL_STDERR}"
  mkdir -p "${TEL_TMP}/home"
  # Run under strict mode to prove the block cannot leak non-zero exit.
  # Print AFTER_OK on a successful fall-through to prove I5.
  set +e
  env -i HOME="${TEL_TMP}/home" PATH="${fake_path}" \
    INSTALL_LOG="${TEL_LOG}" "${envs[@]}" \
    bash -c "set -euo pipefail; source '${TEL_FN}'; echo AFTER_OK" \
    >"${TEL_STDOUT}" 2>"${TEL_STDERR}"
  TEL_RC=$?
  set -e
  return 0
}

assert_silent() { # $1 = scenario label
  # Only allowed stdout line is the post-source sentinel `AFTER_OK`.
  local leak
  leak="$(grep -v '^AFTER_OK$' "${TEL_STDOUT}" || true)"
  if [[ -z "${leak}" ]]; then
    pass "$1: zero user-visible stdout (AFTER_OK sentinel only)"
  else
    fail "$1: stdout leaked: $(printf %q "${leak}")"
  fi
  if [[ ! -s "${TEL_STDERR}" ]]; then
    pass "$1: zero user-visible stderr"
  else
    fail "$1: stderr leaked: $(printf %q "$(cat "${TEL_STDERR}")")"
  fi
}
assert_sentinel() { # $1 = scenario label
  if grep -q '^AFTER_OK$' "${TEL_STDOUT}"; then
    pass "$1: caller continues (set -euo pipefail not tripped)"
  else
    fail "$1: caller aborted (rc=${TEL_RC}, stderr=$(cat "${TEL_STDERR}"))"
  fi
}
assert_log_has() { # $1 = scenario, $2 = substring
  if grep -qF -- "$2" "${TEL_LOG}"; then
    pass "$1: log contains \"$2\""
  else
    fail "$1: log missing \"$2\" (log=$(tr '\n' '|' < "${TEL_LOG}"))"
  fi
}

# ── I6a. --skip-telemetron ────────────────────────────────────────────────────
D="${TEL_TMP}/fakes.skip"; mk_fakes "$D"
tel_run PACK_ARG_SKIP_TELEMETRON=true -- "$D"
assert_silent   "skip-telemetron=true"
assert_sentinel "skip-telemetron=true"
assert_log_has  "skip-telemetron=true" "skip: --skip-telemetron"

# ── I6b. LOWKEY_TELEMETRY=0 ───────────────────────────────────────────────────
D="${TEL_TMP}/fakes.lowkey"; mk_fakes "$D"
tel_run LOWKEY_TELEMETRY=0 PACK_ARG_SKIP_TELEMETRON=false -- "$D"
assert_silent   "LOWKEY_TELEMETRY=0"
assert_sentinel "LOWKEY_TELEMETRY=0"
assert_log_has  "LOWKEY_TELEMETRY=0" "lowkey telemetry opt-out"

# ── I6c. DO_NOT_TRACK=1 ───────────────────────────────────────────────────────
D="${TEL_TMP}/fakes.dnt"; mk_fakes "$D"
tel_run DO_NOT_TRACK=1 PACK_ARG_SKIP_TELEMETRON=false -- "$D"
assert_silent   "DO_NOT_TRACK=1"
assert_sentinel "DO_NOT_TRACK=1"
assert_log_has  "DO_NOT_TRACK=1" "lowkey telemetry opt-out"

# ── I6d. ~/.lowkey/telemetry-off file ─────────────────────────────────────────
D="${TEL_TMP}/fakes.file"; mk_fakes "$D"
mkdir -p "${TEL_TMP}/home/.lowkey"; touch "${TEL_TMP}/home/.lowkey/telemetry-off"
tel_run PACK_ARG_SKIP_TELEMETRON=false -- "$D"
assert_silent   "telemetry-off file"
assert_sentinel "telemetry-off file"
assert_log_has  "telemetry-off file" "lowkey telemetry opt-out"
rm -f "${TEL_TMP}/home/.lowkey/telemetry-off"

# ── I6e. Non-Linux short-circuit ──────────────────────────────────────────────
D="${TEL_TMP}/fakes.mac"; mk_fakes "$D"
rm -f "${D}/uname"
printf '#!/bin/sh\necho Darwin\n' > "${D}/uname"; chmod +x "${D}/uname"
tel_run PACK_ARG_SKIP_TELEMETRON=false -- "$D"
assert_silent   "non-Linux"
assert_sentinel "non-Linux"
assert_log_has  "non-Linux" "skip: non-Linux"

# ── I6f. Missing systemctl ────────────────────────────────────────────────────
D="${TEL_TMP}/fakes.nosysd"; mk_fakes "$D"
rm -f "${D}/systemctl"
tel_run PACK_ARG_SKIP_TELEMETRON=false -- "$D"
assert_silent   "no systemctl"
assert_sentinel "no systemctl"
assert_log_has  "no systemctl" "skip: systemctl not found"

# ── I3. Real curl failure — proves pipefail ───────────────────────────────────
# Without `bash -o pipefail`, the right-hand `bash` exits 0 on empty stdin and
# the block would log "installed and enrolled" despite curl failing. This is
# the regression that motivated v3 of the plan review.
D="${TEL_TMP}/fakes.curlfail"; mk_fakes "$D"
rm -f "${D}/curl"
cat > "${D}/curl" <<'CURL'
#!/bin/sh
echo "MOCK_CURL_STDOUT_NOT_A_SCRIPT"
echo "MOCK_CURL_STDERR_ERROR" >&2
exit 7
CURL
chmod +x "${D}/curl"
tel_run PACK_ARG_SKIP_TELEMETRON=false -- "$D"
assert_silent   "curl fails (rc=7)"
assert_sentinel "curl fails (rc=7)"
# The log must record a non-zero rc. If pipefail is broken, the log would say
# "installed and enrolled" — that's the exact regression we're guarding.
if grep -qE '\[telemetron\] install failed \(rc=[1-9]' "${TEL_LOG}"; then
  pass "curl fails (rc=7): pipefail surfaces non-zero rc"
elif grep -q '\[telemetron\] installed and enrolled' "${TEL_LOG}"; then
  fail "curl fails (rc=7): PIPEFAIL HOLE — log claims success despite curl rc=7"
else
  fail "curl fails (rc=7): unexpected log state ($(tr '\n' '|' < "${TEL_LOG}"))"
fi
# Inner pipeline's stderr must land in log, not caller stderr.
assert_log_has "curl fails (rc=7)" "MOCK_CURL_STDERR_ERROR"

# ── I4. Outer timeout actually fires within budget ────────────────────────────
# Fake a hanging curl and shim `timeout` to clamp to 3s so we don't add 30s
# of real-time wait to CI. This proves the block actually invokes `timeout`
# around the pipeline and honors its exit code (rc 124 for SIGTERM).
D="${TEL_TMP}/fakes.hang"; mk_fakes "$D"
rm -f "${D}/curl" "${D}/timeout"
cat > "${D}/curl" <<'CURL'
#!/bin/sh
sleep 60
CURL
chmod +x "${D}/curl"
cat > "${D}/timeout" <<'TO'
#!/bin/sh
# Ignore the caller's duration; clamp to 3s for CI speed. Re-exec real timeout.
shift
exec /usr/bin/timeout 3 "$@"
TO
chmod +x "${D}/timeout"
SECONDS=0
tel_run PACK_ARG_SKIP_TELEMETRON=false -- "$D"
ELAPSED=$SECONDS
assert_silent   "hanging curl (timeout fires)"
assert_sentinel "hanging curl (timeout fires)"
if [[ $ELAPSED -lt 10 ]]; then
  pass "hanging curl: block returned in ${ELAPSED}s (<10s CI budget)"
else
  fail "hanging curl: block took ${ELAPSED}s — timeout not firing?"
fi
if grep -qE '\[telemetron\] install (aborted|failed \(rc=(124|143))' "${TEL_LOG}"; then
  pass "hanging curl: log records timeout-class outcome"
else
  fail "hanging curl: log missing timeout outcome ($(tr '\n' '|' < "${TEL_LOG}"))"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "Summary"
printf "  ${GREEN}Passed:${NC}  %d\n" "$PASS"
printf "  ${RED}Failed:${NC}  %d\n" "$FAIL"
printf "  ${YELLOW}Skipped:${NC} %d\n" "$SKIP"

[[ $FAIL -eq 0 ]] || exit 1
exit 0
