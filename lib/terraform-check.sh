#!/usr/bin/env bash
# Standalone test for terraform_ok() — sources functions from install.sh
# Usage: bash lib/terraform-check.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stubs for functions used by terraform_ok
json_field() { jq -r ".$1" 2>/dev/null; }
dbg() { :; }

# Extract the functions we need
eval "$(sed -n '/^hw_arch/,/^}/p' "$SCRIPT_DIR/install.sh")"
eval "$(sed -n '/^terraform_version_string/,/^}/p' "$SCRIPT_DIR/install.sh")"
eval "$(sed -n '/^terraform_ok/,/^}/p' "$SCRIPT_DIR/install.sh")"

echo "terraform path: $(command -v terraform 2>/dev/null || echo 'NOT FOUND')"
echo "terraform ver:  $(terraform_version_string 2>/dev/null || echo 'N/A')"
echo "host arch:      $(hw_arch)"
tf_bin=$(command -v terraform 2>/dev/null)
if [[ -n "$tf_bin" ]]; then
  echo "binary arch:    $(file "$tf_bin")"
fi
echo ""
if terraform_ok; then
  echo "RESULT: OK"
else
  echo "RESULT: FAIL"
fi
