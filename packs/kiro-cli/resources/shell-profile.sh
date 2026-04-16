# Kiro CLI shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
# Defines aliases and a welcome banner for the kiro-cli pack.
#
# Kiro CLI v2 supports two auth modes. This profile is auth-mode-aware:
#   - If ~/.kiro/env exists → headless mode is configured; banner reflects that.
#   - Otherwise            → show the interactive-login reminder.

PACK_TUI_COMMAND="kiro-cli"

PACK_ALIASES='
alias kiro="kiro-cli"
alias kiro-agent="kiro-cli --agent"
alias kiro-login="kiro-cli login --use-device-flow"
alias kiro-exec="kiro-cli --no-interactive"
'

PACK_BANNER_NAME="Kiro CLI Agent Environment"
PACK_BANNER_EMOJI="⚡"
PACK_BANNER_COMMANDS='
  kiro-cli                            → Start interactive Kiro CLI
  kiro-cli --no-interactive "prompt"  → One-shot (headless, CI-friendly)
  kiro-cli --agent platform-engineer  → Start with specific agent
  kiro-cli login --use-device-flow    → Browser SSO auth (if no API key set)
  kiro-cli settings chat.defaultAgent → Show/set default agent
'

# Interactive-shell reminder: only if headless mode isn't already configured.
# Also ensure ~/.kiro/env is sourced in case .bash_profile isn't executed
# (e.g. SSM sessions may skip login shells on some configs).
if [[ $- == *i* ]] && command -v kiro-cli &>/dev/null; then
  if [[ -f "${HOME}/.kiro/env" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.kiro/env" 2>/dev/null || true
  elif [[ -z "${KIRO_API_KEY:-}" ]]; then
    printf '\n\033[0;33m⚠  Kiro CLI: not authenticated. Run "kiro-cli login --use-device-flow" or configure headless mode via the pack.\033[0m\n\n'
  fi
fi
