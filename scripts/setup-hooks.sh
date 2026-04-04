#!/usr/bin/env bash
# Install git hooks for local development.
# Usage: bash scripts/setup-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="${REPO_ROOT}/.git/hooks"

if [[ ! -d "${REPO_ROOT}/.git" ]]; then
  echo "Error: not a git repository. Run from the repo root." >&2
  exit 1
fi

mkdir -p "${HOOKS_DIR}"

# Install pre-commit hook
cp "${REPO_ROOT}/scripts/pre-commit" "${HOOKS_DIR}/pre-commit"
chmod +x "${HOOKS_DIR}/pre-commit"

echo "✓ Git hooks installed:"
echo "  pre-commit → runs all unit tests before commit"
echo ""
echo "  Skip with: git commit --no-verify"
