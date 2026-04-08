# NemoClaw shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
PACK_TUI_COMMAND="nemoclaw loki-assistant shell"
# This file defines aliases and the welcome banner for the NemoClaw pack.

PACK_ALIASES='
alias nemo="nemoclaw"
alias nemo-status="nemoclaw loki-assistant status --json | python3 -m json.tool"
alias nemo-logs="nemoclaw loki-assistant logs --follow"
alias nemo-restart="nemoclaw loki-assistant restart"
alias nemo-shell="nemoclaw loki-assistant shell"
alias nemo-stop="nemoclaw loki-assistant stop"
alias nemo-start="nemoclaw loki-assistant start"
alias nemo-brain="nemoclaw loki-assistant brain"
'

PACK_BANNER_NAME="NemoClaw Sandboxed Agent Environment"
PACK_BANNER_EMOJI="🛡️"
PACK_BANNER_COMMANDS='
  nemoclaw loki-assistant status    → Sandbox status
  nemoclaw loki-assistant logs -f   → Follow sandbox logs
  nemoclaw loki-assistant shell     → Open shell inside sandbox
  nemoclaw loki-assistant restart   → Restart sandbox
  nemoclaw loki-assistant brain     → Manage brain files
  nemo-status                       → Status (JSON formatted)
  nemo-logs                         → Follow logs (alias)
'
