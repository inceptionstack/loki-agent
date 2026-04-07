# IronClaw shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
# This file defines aliases and the welcome banner for the IronClaw pack.

PACK_ALIASES='
# Source IronClaw env vars (DATABASE_URL, LLM config) for interactive use
if [ -f "$HOME/.ironclaw/.env" ]; then
  set -a; source "$HOME/.ironclaw/.env"; set +a
fi
alias ic="ironclaw run --no-onboard"
alias ironclaw-wizard="ironclaw"
'

PACK_BANNER_NAME="IronClaw Agent Environment"
PACK_BANNER_EMOJI="🦀"
PACK_BANNER_COMMANDS='
  ic                    → Run IronClaw agent
  ironclaw --help       → Show IronClaw options
  ironclaw --version    → Show installed version
'
