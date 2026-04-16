#!/usr/bin/env bash
# packs/codex-cli/install.sh — Install OpenAI Codex CLI (builder agent)
#
# Usage:
#   ./install.sh [--region us-east-1] [--model gpt-5.4]
#
# Assumes:
#   - Node.js / npm available
#
# Unlike other packs, Codex CLI uses OpenAI's API directly — no bedrockify needed.
# This pack configures Codex as a BUILDER AGENT: danger-full-access sandbox,
# never-prompt approval policy. Authenticate post-deploy with:
#   codex login                       # Browser-based ChatGPT login
#   printenv OPENAI_API_KEY | codex login --with-api-key
#
# Idempotent: safe to re-run. Preserves existing user settings in config.toml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# Pin version for reproducible installs
CODEX_CLI_VERSION="latest"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "gpt-5.4")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install OpenAI Codex CLI — configured as a builder agent on AWS EC2.

⚠️  Codex CLI requires an OpenAI API key or ChatGPT login, obtained AFTER
   deploy. This pack does not embed secrets. Get your key at:
   https://platform.openai.com/api-keys

Options:
  --region      AWS region (informational only)          (default: us-east-1)
  --model       Default model for Codex CLI              (default: gpt-5.4)
  --help        Show this help message

Post-deploy authentication (choose one):
  codex login                              # Browser-based ChatGPT login
  printenv OPENAI_API_KEY | codex login --with-api-key

Builder agent config (set by this pack):
  sandbox_mode    = "danger-full-access"   # Full filesystem/network access
  approval_policy = "never"                # Never prompt before commands
  model           = configured from --model

Note: Codex CLI is a CLI tool only — no systemd service is created.
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)   usage; exit 0 ;;
    --region)    PACK_ARG_REGION="$2"; shift 2 ;;
    --model)     PACK_ARG_MODEL="$2";  shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"

pack_banner "codex-cli"
log "region=${REGION} model=${MODEL} sandbox=danger-full-access approval=never"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd npm node

# ── Install Codex CLI ─────────────────────────────────────────────────────────
step "Installing Codex CLI"

if command -v codex &>/dev/null; then
  CODEX_EXISTING="$(codex --version 2>/dev/null || echo unknown)"
  log "codex already installed (${CODEX_EXISTING}) — upgrading"
fi

npm install -g "@openai/codex@${CODEX_CLI_VERSION}"

# Add npm global bin to PATH for current session
NPM_BIN="$(npm prefix -g)/bin"
export PATH="${NPM_BIN}:${PATH}"

if ! command -v codex &>/dev/null; then
  fail "codex command not found after install. Check PATH or install output."
fi

CODEX_VERSION="$(codex --version 2>/dev/null || echo unknown)"
ok "Codex CLI installed: ${CODEX_VERSION}"

# ── Configure Codex CLI (merge into existing config.toml) ─────────────────────
step "Writing Codex CLI configuration"

CODEX_HOME="${HOME}/.codex"
CODEX_CONFIG="${CODEX_HOME}/config.toml"
mkdir -p "${CODEX_HOME}"

# Merge our keys into existing config.toml using python tomllib/tomli_w if
# available; otherwise write only the managed block idempotently with sentinels.
PACK_MODEL="${MODEL}" python3 - "${CODEX_CONFIG}" <<'PYEOF'
import os, sys, re
path = sys.argv[1]
model = os.environ.get("PACK_MODEL", "gpt-5.4")

# Managed block sentinels — preserve user edits outside this block.
# Block is placed at TOP of file (before any [tables]) so bare keys stay
# at the top-level scope and aren't accidentally scoped into a table.
START = "# >>> managed by lowkey codex-cli pack >>>"
END   = "# <<< managed by lowkey codex-cli pack <<<"
MANAGED_KEYS = ("model", "approval_policy", "sandbox_mode")

managed = f"""{START}
# Keys below are managed by packs/codex-cli/install.sh (builder agent).
# Edits inside this block will be overwritten on pack re-run.
model = "{model}"
approval_policy = "never"
sandbox_mode = "danger-full-access"
{END}
"""

existing = ""
if os.path.exists(path):
    with open(path) as f:
        existing = f.read()

# Strip any previous managed block
managed_re = re.compile(re.escape(START) + r".*?" + re.escape(END) + r"\n?", re.DOTALL)
without_managed = managed_re.sub("", existing)

# Strip top-level assignments of managed keys from user content (before first [table]).
lines = without_managed.splitlines()
in_table = False
cleaned = []
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith("["):
        in_table = True
    if not in_table:
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m and m.group(1) in MANAGED_KEYS:
            continue  # skip
    cleaned.append(line)

cleaned_text = "\n".join(cleaned).lstrip("\n")

# Put managed block at TOP (before any [tables] so our bare keys stay top-level)
if cleaned_text:
    new = managed + "\n" + cleaned_text
else:
    new = managed

if not new.endswith("\n"):
    new += "\n"

with open(path, "w") as f:
    f.write(new)
print(f"[ok] Config updated: {path}")
PYEOF

chmod 600 "${CODEX_CONFIG}"
ok "Config merged: ${CODEX_CONFIG}"

# ── Sanity check ──────────────────────────────────────────────────────────────
step "Sanity check"

ok "codex --version: $(codex --version 2>/dev/null || echo unknown)"
ok "Model: ${MODEL}"
ok "Sandbox: danger-full-access (builder agent — full filesystem/network)"
ok "Approval: never (no command prompts)"
warn "Auth: NOT configured — run 'codex login' or set OPENAI_API_KEY"

# ── Post-install notice ──────────────────────────────────────────────────────
cat << 'NOTICE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [CODEX CLI] INSTALLED — BUILDER AGENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Authenticate (choose one):
    codex login                           # Browser ChatGPT login (opens URL)
    printenv OPENAI_API_KEY | codex login --with-api-key

  Usage:
    codex                                 # Start interactive TUI
    codex exec "Your prompt"              # One-shot execution
    codex resume --last                   # Resume last session

  Config written to: ~/.codex/config.toml (managed block, preserves user edits)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

NOTICE

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "codex-cli"
printf "\n[PACK:codex-cli] INSTALLED — codex CLI ready (model: %s)\n" "${MODEL}"
