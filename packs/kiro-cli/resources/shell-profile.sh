# Kiro CLI shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
PACK_TUI_COMMAND="kiro-cli"
# Defines aliases and welcome banner for the kiro-cli pack.
#
# NOTE: Kiro CLI requires interactive login after install.
#       Run: kiro-cli login --use-device-flow

PACK_ALIASES='
alias kiro="kiro-cli"
alias kiro-agent="kiro-cli --agent"
alias kiro-login="kiro-cli login --use-device-flow"
'

PACK_BANNER_NAME="Kiro CLI Agent Environment"
PACK_BANNER_EMOJI="⚡"
PACK_BANNER_COMMANDS='
  kiro-cli                            → Start interactive Kiro CLI
  kiro-cli --agent platform-engineer  → Start with specific agent
  kiro-cli login --use-device-flow    → Authenticate (REQUIRED first run)
  kiro-cli settings chat.defaultAgent → Show/set default agent
'

# ⚠ Login reminder: only in interactive shells (not during install sourcing)
if [[ $- == *i* ]] && command -v kiro-cli &>/dev/null; then
  printf '\n\033[0;33m⚠  Kiro CLI installed. If not yet authenticated, run: kiro-cli login --use-device-flow\033[0m\n\n'
fi
