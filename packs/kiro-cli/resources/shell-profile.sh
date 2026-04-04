# Kiro CLI shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
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

# ⚠ Login reminder: check if kiro-cli is authenticated
if command -v kiro-cli &>/dev/null; then
  if ! kiro-cli status &>/dev/null 2>&1; then
    printf '\n\033[0;33m⚠  Kiro CLI: not authenticated. Run: kiro-cli login --use-device-flow\033[0m\n\n'
  fi
fi
