#!/usr/bin/env bash
# packs/openclaw/test.sh — Unit tests for the OpenClaw pack
#
# Tests target three boundaries, in order of abstraction:
#
#   1. manifest.yaml structure + install.sh --help interface
#   2. should_run_telemetron() — the pack's policy decision function
#   3. run_optional_sidecar()  — common.sh's silent/bounded/pipefail
#      bootstrap engine, exercised via PATH-hijacked curl/timeout stubs
#
# No network, no sudo, no systemd, no OpenClaw required.
#
# Usage: bash packs/openclaw/test.sh
# Exit:  0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"
PACKS_DIR="${SCRIPT_DIR}/.."
INSTALL="${PACK_DIR}/install.sh"
MANIFEST="${PACK_DIR}/manifest.yaml"
COMMON="${PACKS_DIR}/common.sh"

# ── Test harness ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
pass()   { printf "${GREEN}  ✓${NC} %s\n" "$1"; PASS=$((PASS+1)); }
fail()   { printf "${RED}  ✗${NC} %s\n" "$1"; FAIL=$((FAIL+1)); }
skip()   { printf "${YELLOW}  ○${NC} %s (skipped)\n" "$1"; SKIP=$((SKIP+1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

# ── Test: manifest.yaml ───────────────────────────────────────────────────────
header "Test: manifest.yaml"

[[ -f "${MANIFEST}" ]] && pass "manifest.yaml exists" || fail "manifest.yaml missing"

if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  python3 - "${MANIFEST}" <<'PY' \
    && pass "manifest.yaml: valid YAML, required keys, skip-telemetron param" \
    || fail "manifest.yaml structure invalid"
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

# ── Test: install.sh --help ───────────────────────────────────────────────────
header "Test: install.sh --help"

[[ -f "${INSTALL}" ]] && pass "install.sh exists" || fail "install.sh missing"
[[ "$(head -1 "${INSTALL}")" = "#!/usr/bin/env bash" ]] && pass "shebang" || fail "wrong shebang"
bash -n "${INSTALL}" 2>/dev/null && pass "bash -n clean" || fail "syntax errors"

HELP_OUT="$(bash "${INSTALL}" --help 2>&1)" && pass "--help exits 0" || fail "--help exits nonzero"
for flag in --region --model --port --model-mode --skip-telemetron --help; do
  printf '%s' "${HELP_OUT}" | grep -q -- "${flag}" \
    && pass "--help mentions ${flag}" \
    || fail "--help missing ${flag}"
done
bash "${INSTALL}" --skip-telemetron --help >/dev/null 2>&1 \
  && pass "--skip-telemetron accepted as an arg (not rejected by parser)" \
  || fail "--skip-telemetron rejected by parser"

# ── Test: should_run_telemetron() decisions ───────────────────────────────────
# The pack's *policy* layer. Pure function — given env/PATH, returns one of:
#   yes | skip: --skip-telemetron | skip: non-Linux
#   skip: lowkey telemetry opt-out | skip: systemctl not found
# We source install.sh with the `_telemetron_sidecar` call short-circuited so
# sourcing doesn't actually run any network or install work.
header "Test: should_run_telemetron() — pack policy decisions"

DEC_TMP="$(mktemp -d)"
# Patched install.sh that defines functions but skips the final invocation
# and the rest of the pack install. We extract only up to the `_telemetron_sidecar`
# invocation, and stop there.
sed '/^_telemetron_sidecar$/,$d' "${INSTALL}" > "${DEC_TMP}/install-patched.sh"
# The patched file sources common.sh and then runs the entire pack install.
# That's fine for function definitions, but we also need to neutralize the
# install logic so tests don't try to `npm install` etc. Strategy: source only
# the common.sh + the last two function definitions (should_run_telemetron,
# _telemetron_sidecar) by extracting them explicitly.

# Extract should_run_telemetron from install.sh.
awk '
  /^should_run_telemetron\(\) \{/ { p=1 }
  p
  p && /^\}/ { p=0 }
' "${INSTALL}" > "${DEC_TMP}/should_run.sh"
if grep -q '^should_run_telemetron() {' "${DEC_TMP}/should_run.sh" \
   && grep -q '^}$' "${DEC_TMP}/should_run.sh"; then
  pass "extracted should_run_telemetron()"
else
  fail "could not extract should_run_telemetron"
  exit 1
fi

# Helper: run should_run_telemetron under an isolated PATH + env, compare output.
dec_run() { # args: ENV_KV... -- PATH_DIR — prints decision
  local envs=() path_dir=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" = "--" ]]; then shift; path_dir="$1"; shift; break
    else envs+=("$1"); shift; fi
  done
  env -i HOME="${DEC_TMP}/home" PATH="${path_dir}" BASH_ENV= ENV= "${envs[@]}" \
    bash --noprofile --norc -c "set -euo pipefail; source '${DEC_TMP}/should_run.sh'; should_run_telemetron"
}

mk_path() { # args: dir — pre-populate a PATH dir with common coreutils
  local dir="$1"; mkdir -p "$dir"
  local needed=(uname bash sh printf echo grep sed cat rm mkdir touch env date)
  for b in "${needed[@]}"; do
    local src; src="$(command -v "$b" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "${dir}/$b"
  done
  # systemctl present by default.
  printf '#!/bin/sh\nexit 0\n' > "${dir}/systemctl"; chmod +x "${dir}/systemctl"
}

assert_decision() { # args: scenario expected <env_and_path>
  local label="$1" expected="$2"; shift 2
  local actual; actual="$(dec_run "$@")"
  if [[ "$actual" = "$expected" ]]; then
    pass "${label}: \"${actual}\""
  else
    fail "${label}: expected \"${expected}\", got \"${actual}\""
  fi
}

P="${DEC_TMP}/path.default"; mk_path "$P"
mkdir -p "${DEC_TMP}/home"

assert_decision "no flags → yes"                 "yes"                             -- "$P"
assert_decision "--skip-telemetron → skip"       "skip: --skip-telemetron"         PACK_ARG_SKIP_TELEMETRON=true -- "$P"
assert_decision "LOWKEY_TELEMETRY=0 → opt-out"   "skip: lowkey telemetry opt-out"  LOWKEY_TELEMETRY=0 -- "$P"
assert_decision "DO_NOT_TRACK=1 → opt-out"       "skip: lowkey telemetry opt-out"  DO_NOT_TRACK=1 -- "$P"

mkdir -p "${DEC_TMP}/home/.lowkey"; touch "${DEC_TMP}/home/.lowkey/telemetry-off"
assert_decision "telemetry-off file → opt-out"   "skip: lowkey telemetry opt-out"  -- "$P"
rm -f "${DEC_TMP}/home/.lowkey/telemetry-off"

P_DARWIN="${DEC_TMP}/path.darwin"; mk_path "$P_DARWIN"
rm -f "${P_DARWIN}/uname"; printf '#!/bin/sh\necho Darwin\n' > "${P_DARWIN}/uname"; chmod +x "${P_DARWIN}/uname"
assert_decision "Darwin → non-Linux"             "skip: non-Linux"                 -- "$P_DARWIN"

P_NOSYSD="${DEC_TMP}/path.nosysd"; mk_path "$P_NOSYSD"; rm -f "${P_NOSYSD}/systemctl"
assert_decision "no systemctl → skip"            "skip: systemctl not found"       -- "$P_NOSYSD"

# Decision precedence: explicit --skip wins over everything.
assert_decision "--skip beats opt-out env"       "skip: --skip-telemetron" \
  PACK_ARG_SKIP_TELEMETRON=true LOWKEY_TELEMETRY=0 DO_NOT_TRACK=1 -- "$P"

# ── Test: run_optional_sidecar() — common.sh engine contract ──────────────────
# Invariants proven by running the helper with stubbed curl/timeout:
#   I1. Silent:   zero stdout/stderr to the caller.
#   I2. Logged:   every outcome writes a tagged `[NAME] ...` line.
#   I3. Pipefail: curl failure surfaces a non-zero rc (proves -o pipefail).
#   I4. Timeout:  a hanging inner step returns within bounds.
#   I5. Safe:     never trips the caller's `set -euo pipefail`.
header "Test: run_optional_sidecar() — common.sh engine"

SC_TMP="$(mktemp -d)"
trap 'rm -rf "$DEC_TMP" "$SC_TMP"' EXIT

# Helper: run a scenario. Writes $SC_STDOUT, $SC_STDERR, $SC_LOG, $SC_RC.
# All env passed to the sidecar is inside the bash -c command line as args.
sc_run() { # args: <PATH_DIR> <NAME> <URL> <TIMEOUT_SECS>
  local path_dir="$1" name="$2" url="$3" secs="$4"
  SC_LOG="${SC_TMP}/log.$$.$RANDOM"; : > "$SC_LOG"
  SC_STDOUT="${SC_TMP}/out.$$.$RANDOM"; : > "$SC_STDOUT"
  SC_STDERR="${SC_TMP}/err.$$.$RANDOM"; : > "$SC_STDERR"
  set +e
  # --noprofile --norc prevents bash from reading /etc/profile.d or ~/.bashrc,
  # which could silently prepend system paths and defeat the PATH hijack.
  env -i PATH="${path_dir}" HOME="${SC_TMP}/home" BASH_ENV= ENV= \
    bash --noprofile --norc -c "set -euo pipefail
             source '${COMMON}'
             run_optional_sidecar '$name' '$url' $secs '$SC_LOG' FOO=bar
             echo AFTER_OK" \
    >"$SC_STDOUT" 2>"$SC_STDERR"
  SC_RC=$?
  set -e
}

sc_assert_silent() { # $1 = label
  local leak
  leak="$(grep -v '^AFTER_OK$' "$SC_STDOUT" || true)"
  [[ -z "$leak" ]] && pass "$1: zero stdout" || fail "$1: stdout leaked: $(printf %q "$leak")"
  [[ ! -s "$SC_STDERR" ]] && pass "$1: zero stderr" || fail "$1: stderr leaked: $(printf %q "$(cat "$SC_STDERR")")"
}
sc_assert_sentinel() { # $1 = label
  grep -q '^AFTER_OK$' "$SC_STDOUT" \
    && pass "$1: set -euo pipefail not tripped" \
    || fail "$1: caller aborted (rc=$SC_RC, stderr=$(cat "$SC_STDERR"))"
}
sc_assert_log() { # $1 = label, $2 = substring
  grep -qF -- "$2" "$SC_LOG" \
    && pass "$1: log contains \"$2\"" \
    || fail "$1: log missing \"$2\" ($(tr '\n' '|' < "$SC_LOG"))"
}

mk_sc_path() { # $1 = dir
  local dir="$1"; mkdir -p "$dir"
  local needed=(bash sh env printf echo date timeout grep sed cat rm mkdir chmod sleep head tail)
  for b in "${needed[@]}"; do
    local src; src="$(command -v "$b" 2>/dev/null || true)"
    [[ -n "$src" ]] && ln -sf "$src" "${dir}/$b"
  done
}

# I3. curl fails — pipefail must surface the non-zero rc to the log.
D="${SC_TMP}/curlfail"; mk_sc_path "$D"
cat > "${D}/curl" <<'CURL'
#!/bin/sh
echo "MOCK_CURL_STDOUT_NOT_A_SCRIPT"
echo "MOCK_CURL_STDERR_ERROR" >&2
exit 7
CURL
chmod +x "${D}/curl"

sc_run "$D" telemetron https://example/install.sh 10
sc_assert_silent   "curl fails"
sc_assert_sentinel "curl fails"
if grep -qE '\[telemetron\] install failed \(rc=[1-9]' "$SC_LOG"; then
  pass "curl fails: pipefail surfaces non-zero rc (not masked)"
elif grep -q '\[telemetron\] installed and enrolled' "$SC_LOG"; then
  fail "curl fails: PIPEFAIL HOLE — log claims success despite curl exit 7"
else
  fail "curl fails: unexpected log state ($(tr '\n' '|' < "$SC_LOG"))"
fi
sc_assert_log "curl fails" "MOCK_CURL_STDERR_ERROR"
sc_assert_log "curl fails" "[telemetron] begin"
sc_assert_log "curl fails" "[telemetron] end"

# I4. Hanging curl — outer timeout must fire.
D="${SC_TMP}/hang"; mk_sc_path "$D"
rm -f "${D}/curl"; cat > "${D}/curl" <<'CURL'
#!/bin/sh
sleep 60
CURL
chmod +x "${D}/curl"
SECONDS=0
sc_run "$D" telemetron https://example/install.sh 3
ELAPSED=$SECONDS
sc_assert_silent   "hanging curl"
sc_assert_sentinel "hanging curl"
[[ $ELAPSED -lt 10 ]] \
  && pass "hanging curl: returned in ${ELAPSED}s (<10s)" \
  || fail "hanging curl: took ${ELAPSED}s — timeout not firing"
if grep -qE '\[telemetron\] install (aborted|failed \(rc=(124|137|143))' "$SC_LOG"; then
  pass "hanging curl: log records timeout-class outcome"
else
  fail "hanging curl: log missing timeout outcome ($(tr '\n' '|' < "$SC_LOG"))"
fi

# Happy path — stubbed curl that emits a tiny installer to bash.
D="${SC_TMP}/happy"; mk_sc_path "$D"
rm -f "${D}/curl"
cat > "${D}/curl" <<'CURL'
#!/bin/sh
# Emit a trivial installer that prints to stdout (should land in log only).
printf 'echo INNER_INSTALL_RAN; exit 0\n'
exit 0
CURL
chmod +x "${D}/curl"
sc_run "$D" telemetron https://example/install.sh 10
sc_assert_silent   "happy path"
sc_assert_sentinel "happy path"
sc_assert_log      "happy path" "INNER_INSTALL_RAN"
sc_assert_log      "happy path" "[telemetron] installed and enrolled"



# SIDECAR_USE_SUDO — when SIDECAR_USE_SUDO=1 is passed, the inner pipeline
# should run through sudo. We can't test actual privilege escalation in CI,
# but we can verify:
#   (a) SIDECAR_USE_SUDO=1 is stripped from env (not leaked to inner script)
#   (b) The pipeline still runs and logs correctly when sudo is unavailable
#       (falls back gracefully — no sudo in PATH)

# (b) SIDECAR_USE_SUDO=1 with no sudo in PATH → falls back to non-sudo
D="${SC_TMP}/nosudo"; mk_sc_path "$D"
rm -f "${D}/sudo"  # ensure no sudo
rm -f "${D}/curl"
cat > "${D}/curl" <<'CURL'
#!/bin/sh
# Print env to prove SIDECAR_USE_SUDO is not leaked
env | grep SIDECAR && echo "LEAKED_SIDECAR_ENV" || true
printf 'echo INNER_NOSUDO_RAN; exit 0\n'
exit 0
CURL
chmod +x "${D}/curl"
# Custom sc_run with SIDECAR_USE_SUDO=1
SC_LOG="${SC_TMP}/log.sudo.$$"; : > "$SC_LOG"
SC_STDOUT="${SC_TMP}/out.sudo.$$"; SC_STDERR="${SC_TMP}/err.sudo.$$"
: > "$SC_STDOUT"; : > "$SC_STDERR"
set +e
env -i PATH="${D}" HOME="${SC_TMP}/home" BASH_ENV= ENV= \
  bash --noprofile --norc -c "set -euo pipefail
           source '${COMMON}'
           run_optional_sidecar telemetron https://example/install.sh 10 '${SC_LOG}' FOO=bar SIDECAR_USE_SUDO=1
           echo AFTER_OK" \
  >"$SC_STDOUT" 2>"$SC_STDERR"
SC_RC=$?
set -e
sc_assert_silent   "SIDECAR_USE_SUDO no-sudo"
sc_assert_sentinel "SIDECAR_USE_SUDO no-sudo"
sc_assert_log      "SIDECAR_USE_SUDO no-sudo" "INNER_NOSUDO_RAN"
sc_assert_log      "SIDECAR_USE_SUDO no-sudo" "[telemetron] installed and enrolled"
if grep -q 'LEAKED_SIDECAR_ENV' "$SC_LOG"; then
  fail "SIDECAR_USE_SUDO no-sudo: SIDECAR_USE_SUDO leaked to inner script"
else
  pass "SIDECAR_USE_SUDO no-sudo: SIDECAR_USE_SUDO not leaked to inner env"
fi

# I1b. Unwritable log — "silent" contract holds even when log cannot be opened.
# Engine must fall back to /dev/null, not leak to caller's stdout/stderr.
D="${SC_TMP}/unwritable"; mk_sc_path "$D"
rm -f "${D}/curl"
cat > "${D}/curl" <<'CURL'
#!/bin/sh
exit 7
CURL
chmod +x "${D}/curl"
sc_run "$D" telemetron https://example/x.sh 3 # uses SC_LOG from sc_run = nonexistent path

# Override SC_LOG to a path with nonexistent parent, then run
SC_LOG="${SC_TMP}/no/such/dir/log.txt"
SC_STDOUT="${SC_TMP}/out_unwr"; SC_STDERR="${SC_TMP}/err_unwr"; : > "$SC_STDOUT"; : > "$SC_STDERR"
set +e
env -i PATH="${D}" HOME="${SC_TMP}/home" BASH_ENV= ENV= \
  bash --noprofile --norc -c "
    set -euo pipefail
    source \"${COMMON}\"
    run_optional_sidecar telemetron https://example/x.sh 3 \"${SC_TMP}/no/such/dir/log.txt\" FOO=bar
    echo AFTER_OK
  " >"$SC_STDOUT" 2>"$SC_STDERR"
set -e
leak_out="$(grep -v '^AFTER_OK$' "$SC_STDOUT" || true)"
[[ -z "$leak_out" ]] \
  && pass "unwritable log (engine): zero stdout" \
  || fail "unwritable log (engine): stdout leaked: $(printf %q "$leak_out")"
[[ ! -s "$SC_STDERR" ]] \
  && pass "unwritable log (engine): zero stderr" \
  || fail "unwritable log (engine): stderr leaked: $(printf %q "$(cat "$SC_STDERR")")"
grep -q '^AFTER_OK$' "$SC_STDOUT" \
  && pass "unwritable log (engine): set -euo pipefail not tripped" \
  || fail "unwritable log (engine): caller aborted"

# ── Summary ───────────────────────────────────────────────────────────────────
header "Summary"
printf "  ${GREEN}Passed:${NC}  %d\n" "$PASS"
printf "  ${RED}Failed:${NC}  %d\n" "$FAIL"
printf "  ${YELLOW}Skipped:${NC} %d\n" "$SKIP"

[[ $FAIL -eq 0 ]] || exit 1
exit 0
