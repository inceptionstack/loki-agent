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

# Install git-secrets hooks (if git-secrets is available)
if command -v git-secrets &>/dev/null; then
  ( cd "${REPO_ROOT}" && git secrets --register-aws 2>/dev/null || true )
  echo "✓ git-secrets AWS patterns registered"
else
  echo "⚠ git-secrets not found — install for local secret scanning:"
  echo "  brew install git-secrets  OR  https://github.com/awslabs/git-secrets#installing-git-secrets"
fi

echo "✓ Git hooks installed:"
echo "  pre-commit → runs all unit tests before commit"
echo ""
echo "  Skip with: git commit --no-verify"
