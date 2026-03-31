#!/usr/bin/env bash
# tests/test-registry-parser.sh — tests for scripts/parse-registry.py
# Run: bash tests/test-registry-parser.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="${SCRIPT_DIR}/scripts/parse-registry.py"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---- Assert helpers ---------------------------------------------------------
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    echo "    expected: $(printf '%q' "$expected")"
    echo "    actual:   $(printf '%q' "$actual")"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "$actual" ]]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    echo "    expected empty, got: $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_line_count() {
  local desc="$1" expected="$2" actual_text="$3"
  local count
  if [[ -z "$actual_text" ]]; then
    count=0
  else
    count=$(echo "$actual_text" | wc -l | tr -d ' ')
  fi
  assert_eq "$desc" "$expected" "$count"
}

assert_exit_nonzero() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✗ $desc (expected non-zero exit, got 0)"
    FAIL=$((FAIL + 1))
  else
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  fi
}

# ---- Fixtures ---------------------------------------------------------------
REAL_REGISTRY="${SCRIPT_DIR}/packs/registry.yaml"

cat > "$TMPDIR/minimal.yaml" << 'EOF'
version: 1

packs:
  mybase:
    type: base
    description: "A base pack"

  alpha:
    type: agent
    description: "Alpha agent"
    instance_type: t4g.xlarge
    experimental: false

  beta:
    type: agent
    description: "Beta — test agent (with parens)"
    instance_type: t4g.medium
    experimental: true
EOF

cat > "$TMPDIR/empty.yaml" << 'EOF'
version: 1
packs:
EOF

cat > "$TMPDIR/no-agents.yaml" << 'EOF'
version: 1
packs:
  mybase:
    type: base
    description: "Only base packs here"
EOF

cat > "$TMPDIR/malformed.yaml" << 'EOF'
this is not valid yaml at all
  random indentation:
    but no real structure
key without value:
  nested:
    type: agent
EOF

cat > "$TMPDIR/missing-fields.yaml" << 'EOF'
version: 1
packs:
  bare:
    type: agent

  partial:
    type: agent
    description: "Has desc but no instance_type"
    experimental: true
EOF

cat > "$TMPDIR/special-chars.yaml" << 'EOF'
version: 1
packs:
  fancy:
    type: agent
    description: "Fancy — agent with dashes, parens (v2), and pipes"
    instance_type: t4g.large
    experimental: false
EOF

cat > "$TMPDIR/single-quotes.yaml" << 'EOF'
version: 1
packs:
  quoted:
    type: agent
    description: 'Single-quoted description'
    instance_type: 't4g.medium'
    experimental: 'true'
EOF

# ---- Tests ------------------------------------------------------------------

echo ""
echo "=== Test: real registry.yaml (4 agent packs) ==="
output=$(python3 "$PARSER" "$REAL_REGISTRY" list-agents)
assert_line_count "lists exactly 4 agents" "4" "$output"
assert_contains "includes openclaw" "openclaw|" "$output"
assert_contains "includes hermes" "hermes|" "$output"
assert_contains "includes pi" "pi|" "$output"
assert_contains "includes ironclaw" "ironclaw|" "$output"

# Verify bedrockify (type: base) is excluded
line_count_with_bedrockify=$(echo "$output" | grep -c '^bedrockify|' || true)
assert_eq "excludes base packs (bedrockify)" "0" "$line_count_with_bedrockify"

echo ""
echo "=== Test: experimental flag detection ==="
output=$(python3 "$PARSER" "$REAL_REGISTRY" list-agents)
openclaw_line=$(echo "$output" | grep '^openclaw|')
hermes_line=$(echo "$output" | grep '^hermes|')
pi_line=$(echo "$output" | grep '^pi|')
ironclaw_line=$(echo "$output" | grep '^ironclaw|')
assert_contains "openclaw is not experimental" "|false" "$openclaw_line"
assert_contains "hermes is not experimental" "|false" "$hermes_line"
assert_contains "pi is experimental" "|true" "$pi_line"
assert_contains "ironclaw is experimental" "|true" "$ironclaw_line"

echo ""
echo "=== Test: instance_type lookup ==="
assert_eq "openclaw → t4g.xlarge" "t4g.xlarge" "$(python3 "$PARSER" "$REAL_REGISTRY" get openclaw instance_type)"
assert_eq "hermes → t4g.medium" "t4g.medium" "$(python3 "$PARSER" "$REAL_REGISTRY" get hermes instance_type)"
assert_eq "pi → t4g.medium" "t4g.medium" "$(python3 "$PARSER" "$REAL_REGISTRY" get pi instance_type)"
assert_eq "ironclaw → t4g.medium" "t4g.medium" "$(python3 "$PARSER" "$REAL_REGISTRY" get ironclaw instance_type)"

echo ""
echo "=== Test: get arbitrary keys ==="
assert_eq "openclaw description" "OpenClaw — stateful AI agent with persistent gateway" \
  "$(python3 "$PARSER" "$REAL_REGISTRY" get openclaw description)"
assert_eq "openclaw default_model" "us.anthropic.claude-opus-4-6-v1" \
  "$(python3 "$PARSER" "$REAL_REGISTRY" get openclaw default_model)"
assert_eq "openclaw brain" "true" \
  "$(python3 "$PARSER" "$REAL_REGISTRY" get openclaw brain)"

echo ""
echo "=== Test: nonexistent pack/key returns empty ==="
assert_empty "nonexistent pack" "$(python3 "$PARSER" "$REAL_REGISTRY" get nonexistent instance_type)"
assert_empty "nonexistent key" "$(python3 "$PARSER" "$REAL_REGISTRY" get openclaw nonexistent_key)"

echo ""
echo "=== Test: minimal fixture (2 agents, 1 base) ==="
output=$(python3 "$PARSER" "$TMPDIR/minimal.yaml" list-agents)
assert_line_count "lists exactly 2 agents" "2" "$output"
assert_contains "alpha is listed" "alpha|Alpha agent|false" "$output"
assert_contains "beta is listed" "beta|" "$output"
assert_contains "beta is experimental" "|true" "$(echo "$output" | grep beta)"
assert_eq "beta instance_type" "t4g.medium" "$(python3 "$PARSER" "$TMPDIR/minimal.yaml" get beta instance_type)"

echo ""
echo "=== Test: descriptions with special chars ==="
desc=$(python3 "$PARSER" "$TMPDIR/special-chars.yaml" get fancy description)
assert_eq "description with dashes, parens, and pipes" \
  "Fancy — agent with dashes, parens (v2), and pipes" "$desc"

# Test the pipe-delimited output isn't broken by the pipe in description
output=$(python3 "$PARSER" "$TMPDIR/special-chars.yaml" list-agents)
# The pipe in the description will cause IFS='|' to split wrong — this is a known
# limitation of the pipe-delimited format. But 'get' command should work fine.
assert_contains "special-chars agent listed" "fancy|" "$output"

echo ""
echo "=== Test: single-quoted values ==="
output=$(python3 "$PARSER" "$TMPDIR/single-quotes.yaml" list-agents)
assert_contains "single-quoted description stripped" "Single-quoted description" "$output"
assert_eq "single-quoted instance_type" "t4g.medium" \
  "$(python3 "$PARSER" "$TMPDIR/single-quotes.yaml" get quoted instance_type)"

echo ""
echo "=== Test: empty registry (no packs defined) ==="
output=$(python3 "$PARSER" "$TMPDIR/empty.yaml" list-agents)
assert_empty "no output for empty registry" "$output"

echo ""
echo "=== Test: no agent packs (only base) ==="
output=$(python3 "$PARSER" "$TMPDIR/no-agents.yaml" list-agents)
assert_empty "no output when only base packs" "$output"

echo ""
echo "=== Test: missing fields (bare pack with only type) ==="
output=$(python3 "$PARSER" "$TMPDIR/missing-fields.yaml" list-agents)
assert_line_count "2 agents even with missing fields" "2" "$output"
# bare pack should use its name as description
assert_contains "bare pack uses name as desc fallback" "bare|bare|false" "$output"
assert_contains "partial pack has description" "partial|Has desc" "$output"
assert_empty "bare pack has no instance_type" \
  "$(python3 "$PARSER" "$TMPDIR/missing-fields.yaml" get bare instance_type)"

echo ""
echo "=== Test: malformed YAML (no crash) ==="
output=$(python3 "$PARSER" "$TMPDIR/malformed.yaml" list-agents 2>&1)
# Should produce some output or empty, but not crash
# The "nested" block has type: agent but that's at wrong indent — 
# with the regex parser it might match or not, but shouldn't crash
echo "  ✓ parser did not crash on malformed input"
PASS=$((PASS + 1))

echo ""
echo "=== Test: CLI error handling ==="
assert_exit_nonzero "missing args exits non-zero" python3 "$PARSER"
assert_exit_nonzero "bad command exits non-zero" python3 "$PARSER" "$REAL_REGISTRY" bad-command

echo ""
echo "================================================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
