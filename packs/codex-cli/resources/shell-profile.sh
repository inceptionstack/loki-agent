# Codex CLI shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
# This file defines aliases and the welcome banner for the codex-cli pack.

PACK_ALIASES='
alias cx="codex"
alias cxl="codex login"
alias cxe="codex exec"
alias cxr="codex resume --last"
'

PACK_BANNER_NAME="Codex CLI (Builder Agent)"
PACK_BANNER_EMOJI="🧠"
PACK_BANNER_COMMANDS='
  codex                           → Start interactive TUI
  codex exec "Your prompt"        → One-shot execution
  codex resume --last             → Resume last session
  codex login                     → Browser ChatGPT login
  codex login --with-api-key      → Login with OPENAI_API_KEY from stdin
'
