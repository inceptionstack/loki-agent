# OpenClaw shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
# This file defines aliases and the welcome banner for the OpenClaw pack.

PACK_ALIASES='
alias loki="openclaw"
alias lt="openclaw tui"
alias gr="openclaw gateway restart"
'

PACK_BANNER_NAME="OpenClaw Agent Environment"
PACK_BANNER_EMOJI="🤖"
PACK_BANNER_COMMANDS='
  openclaw tui          → Launch agent terminal UI
  openclaw gateway      → Gateway status
  openclaw gateway restart → Restart gateway
'
