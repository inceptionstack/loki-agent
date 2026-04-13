#!/usr/bin/env bash

if [[ -n "${_LOKI_WIZARD_UI_SH:-}" ]]; then
  return 0
fi
_LOKI_WIZARD_UI_SH=1

# Display output target: /dev/tty if available, otherwise stderr
if [[ -w /dev/tty ]] 2>/dev/null; then
  WIZARD_DISPLAY="/dev/tty"
else
  WIZARD_DISPLAY="/dev/stderr"
fi

WIZARD_COLOR_BG="0"
WIZARD_COLOR_CARD="236"
WIZARD_COLOR_BLUE="75"
WIZARD_COLOR_GREEN="42"
WIZARD_COLOR_YELLOW="178"
WIZARD_COLOR_RED="203"
WIZARD_COLOR_TEXT="252"
WIZARD_COLOR_MUTED="246"
WIZARD_TOTAL_STEPS="${WIZARD_TOTAL_STEPS:-6}"
WIZARD_STEP_INDEX="${WIZARD_STEP_INDEX:-0}"
WIZARD_HEADER_ICON="${WIZARD_HEADER_ICON:-🔧}"

wizard_ui_require() {
  [[ -n "${GUM:-}" ]] || GUM="gum"
  command -v "${GUM}" >/dev/null 2>&1 || {
    echo "gum is required" >&2
    return 1
  }
}

wizard_ui_set_step() {
  WIZARD_STEP_INDEX="$1"
  WIZARD_TOTAL_STEPS="$2"
}

wizard_divider() {
  "${GUM}" style --foreground "${WIZARD_COLOR_MUTED}" "──────────────────────────────────────────"
}

wizard_header() {
  local title="$1"
  local subtitle="${2:-}"
  wizard_ui_require || return 1

  local heading
  heading="$("${GUM}" style \
    --border rounded \
    --border-foreground "${WIZARD_COLOR_BLUE}" \
    --foreground "${WIZARD_COLOR_TEXT}" \
    --padding "0 2" \
    --bold \
    "${WIZARD_HEADER_ICON} Deploy Agent — Step ${WIZARD_STEP_INDEX} of ${WIZARD_TOTAL_STEPS}")"
  printf '%s\n\n' "${heading}"
  "${GUM}" style --foreground "${WIZARD_COLOR_TEXT}" --bold "${title}"
  if [[ -n "${subtitle}" ]]; then
    "${GUM}" style --foreground "${WIZARD_COLOR_MUTED}" "${subtitle}"
  fi
  printf '\n'
}

wizard_note() {
  "${GUM}" style --foreground "${WIZARD_COLOR_MUTED}" "$1" >"${WIZARD_DISPLAY}"
}

wizard_success() {
  "${GUM}" style --foreground "${WIZARD_COLOR_GREEN}" "✓ $1" >"${WIZARD_DISPLAY}"
}

wizard_warning() {
  "${GUM}" style --foreground "${WIZARD_COLOR_YELLOW}" "⚠ $1" >"${WIZARD_DISPLAY}"
}

wizard_error() {
  "${GUM}" style --foreground "${WIZARD_COLOR_RED}" --bold "✗ $1" >"${WIZARD_DISPLAY}"
}

wizard_choose() {
  local title="$1"
  local subtitle="$2"
  local selected="${3:-}"
  shift 3
  wizard_header "${title}" "${subtitle}" >"${WIZARD_DISPLAY}"
  if [[ -n "${selected}" ]]; then
    "${GUM}" choose --cursor.foreground "${WIZARD_COLOR_BLUE}" --selected "${selected}" "$@" < /dev/tty
  else
    "${GUM}" choose --cursor.foreground "${WIZARD_COLOR_BLUE}" "$@" < /dev/tty
  fi
}

wizard_choose_multi() {
  local title="$1"
  local subtitle="$2"
  local selected_csv="${3:-}"
  shift 3
  wizard_header "${title}" "${subtitle}" >"${WIZARD_DISPLAY}"
  "${GUM}" choose --no-limit --cursor.foreground "${WIZARD_COLOR_BLUE}" --selected "${selected_csv}" "$@" < /dev/tty
}

wizard_input() {
  local title="$1"
  local subtitle="$2"
  local value="$3"
  local placeholder="$4"
  local mask="${5:-false}"
  wizard_header "${title}" "${subtitle}" >"${WIZARD_DISPLAY}"
  if [[ "${mask}" == "true" ]]; then
    "${GUM}" input --password --value "${value}" --placeholder "${placeholder}" < /dev/tty
  else
    "${GUM}" input --value "${value}" --placeholder "${placeholder}" < /dev/tty
  fi
}

wizard_confirm() {
  local title="$1"
  local subtitle="$2"
  local prompt="$3"
  local default_yes="${4:-false}"
  wizard_header "${title}" "${subtitle}" >"${WIZARD_DISPLAY}"
  if [[ "${default_yes}" == "true" ]]; then
    "${GUM}" confirm --default=yes "${prompt}" < /dev/tty
  else
    "${GUM}" confirm "${prompt}" < /dev/tty
  fi
}

wizard_summary() {
  local content="$1"
  "${GUM}" style \
    --border rounded \
    --border-foreground "${WIZARD_COLOR_GREEN}" \
    --foreground "${WIZARD_COLOR_TEXT}" \
    --padding "1 2" \
    "${content}"
}

wizard_spinner() {
  local title="$1"
  shift
  "${GUM}" spin --title "${title}" -- "$@"
}

wizard_mask_secret() {
  local value="$1"
  local prefix="${2:-4}"
  [[ -z "${value}" ]] && return 0
  local visible="${value:0:${prefix}}"
  local len="${#value}"
  local masked_len=$(( len - prefix ))
  (( masked_len < 0 )) && masked_len=0
  printf '%s' "${visible}"
  printf '•%.0s' $(seq 1 "${masked_len}")
}
