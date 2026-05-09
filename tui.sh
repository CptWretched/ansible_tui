#!/bin/bash
export LC_ALL=C.UTF-8

# ---------------- Theme / Colors ----------------
RESET='\033[0m'
TEXT='\033[38;5;252m'
DIM='\033[38;5;244m'
CYAN='\033[38;5;117m'
GREEN='\033[38;5;114m'
YELLOW='\033[38;5;221m'
RED='\033[38;5;203m'
BORDER='\033[38;5;81m'
SELECT_BG='\033[48;5;24m'
SELECT_FG='\033[38;5;255m'

# ---------------- Paths ----------------
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"

# ---------------- State ----------------
selected=0
cols=0; rows=0; header_h=4; footer_h=3; body_h=0; start=0; end=0
needs_redraw=1

# Per-item status (same index as scripts[])
declare -a SCRIPTS=()
declare -a STATUS=()

# Header stats (updated from last run result)
node_count=0
task_count=0

SAVED_STTY="$(stty -g)"

cleanup() {
  stty "$SAVED_STTY" 2>/dev/null || true
  printf '\033[?25h'  # show cursor
  printf '%b' "$RESET"
}
trap cleanup EXIT INT TERM

on_resize() { needs_redraw=1; }
trap on_resize WINCH

hline() { printf "%${1}s" "" | tr ' ' '-'; }

trunc() {
  local s="$1" w="$2"
  (( w <= 0 )) && { printf ""; return; }
  if (( ${#s} > w )); then
    if (( w <= 3 )); then printf "%*s" "$w" ""; else printf "%s" "${s:0:$((w-3))}..."; fi
  else
    printf "%-*s" "$w" "$s"
  fi
}

discover_scripts() {
  SCRIPTS=()
  STATUS=()

  shopt -s nullglob
  local f base i=0
  for f in "${SCRIPTS_DIR}"/*.sh; do
    [[ -f "$f" ]] || continue
    [[ -x "$f" ]] || continue
    base="$(basename "$f")"
    SCRIPTS+=("$base")
    STATUS+=("[INFO] Ready")
    ((i++))
  done
  shopt -u nullglob
}

calc_layout() {
  cols="$(tput cols 2>/dev/null || echo 120)"
  rows="$(tput lines 2>/dev/null || echo 30)"
  body_h=$((rows - header_h - footer_h))
  (( body_h < 3 )) && body_h=3
}

calc_window() {
  local total=${#SCRIPTS[@]}
  start=$((selected - body_h / 2)); (( start < 0 )) && start=0
  end=$((start + body_h)); (( end > total )) && end=$total
  start=$((end - body_h)); (( start < 0 )) && start=0
}

draw_header() {
  local left_vis="MojaveOps Ansible Register Manager"
  local right_vis="Nodes:${node_count} Tasks:${task_count}"
  local pad=$((cols - 2 - ${#left_vis} - ${#right_vis} - 2))
  (( pad < 1 )) && pad=1

  printf "%b+%s+%b\n" "$BORDER" "$(hline $((cols-2)))" "$RESET"
  printf "%b|%b %bMojaveOps%b %bAnsible Register Manager%b" "$BORDER" "$RESET" "$CYAN" "$RESET" "$DIM" "$RESET"
  printf "%${pad}s" ""
  printf "%bNodes:%s Tasks:%s%b %b|%b\n" "$GREEN" "$node_count" "$task_count" "$RESET" "$BORDER" "$RESET"
  printf "%b+%s+%b\n" "$BORDER" "$(hline $((cols-2)))" "$RESET"
}

draw_body() {
  local right_w=$((cols - 27 - 1))

  if (( ${#SCRIPTS[@]} == 0 )); then
    printf "%b|%b %bNo executable scripts found in:%b %s%*s%b|%b\n" \
      "$BORDER" "$RESET" "$YELLOW" "$RESET" "$SCRIPTS_DIR" \
      $((cols - 4 - 31 - ${#SCRIPTS_DIR})) "" "$BORDER" "$RESET"
    return 0
  fi

  local i
  for ((i=start; i<end; i++)); do
    local name="${SCRIPTS[$i]}"
    local st="${STATUS[$i]}"

    printf "%b|%b" "$BORDER" "$RESET"
    if (( i == selected )); then
      printf "%b%b > %s %b" "$SELECT_BG" "$SELECT_FG" "$(trunc "$name" 22)" "$RESET"
    else
      printf "   %s " "$(trunc "$name" 22)"
    fi
    printf "%b|%b" "$BORDER" "$RESET"

    local color="$TEXT"
    [[ "$st" == *"[WARN]"*  ]] && color="$YELLOW"
    [[ "$st" == *"[ERROR]"* ]] && color="$RED"
    [[ "$st" == *"[OK]"*    ]] && color="$GREEN"

    printf "%b %s%b%b|%b\n" \
      "$color" "$(trunc "$st" $((right_w-2)))" "$RESET" "$BORDER" "$RESET"
  done
}

draw_footer() {
  local left_vis="[ENTER] Run  [J/K] Navigate  [Q] Quit"
  local right_vis="READY"
  local pad=$((cols - 2 - ${#left_vis} - ${#right_vis} - 2))
  (( pad < 1 )) && pad=1

  printf "%b+%s+%b\n" "$BORDER" "$(hline $((cols-2)))" "$RESET"
  printf "%b|%b %b[ENTER] Run  [J/K] Navigate  [Q] Quit%b" "$BORDER" "$RESET" "$DIM" "$RESET"
  printf "%${pad}s" ""
  printf "%bREADY%b %b|%b\n" "$GREEN" "$RESET" "$BORDER" "$RESET"
  printf "%b+%s+%b\n" "$BORDER" "$(hline $((cols-2)))" "$RESET"
}

render() { clear; calc_layout; calc_window; draw_header; draw_body; draw_footer; }

read_key() {
  local k s
  IFS= read -rsn1 k </dev/tty
  if [[ "$k" == $'\x1b' ]]; then
    IFS= read -rsn8 -t 0.05 s </dev/tty || true
    k="ESC$s"
  fi
  printf '%s' "$k"
}

# Result file contract:
# Script writes lines like:
#   STATUS=OK|WARN|ERROR
#   MESSAGE=Some short message
#   NODES=123
#   TASKS=456
read_result_file() {
  local rf="$1"
  local key val
  local status="" message="" nodes="" tasks=""
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    case "$key" in
      STATUS)  status="$val" ;;
      MESSAGE) message="$val" ;;
      NODES)   nodes="$val" ;;
      TASKS)   tasks="$val" ;;
    esac
  done < "$rf"

  [[ -n "$nodes" ]] && node_count="$nodes"
  [[ -n "$tasks" ]] && task_count="$tasks"

  printf "%s|%s" "$status" "$message"
}

run_selected() {
  if (( ${#SCRIPTS[@]} == 0 )); then return 0; fi

  local script="${SCRIPTS_DIR}/${SCRIPTS[$selected]}"
  if [[ ! -x "$script" ]]; then
    STATUS[$selected]="[ERROR] Script not executable"
    needs_redraw=1
    return 0
  fi

  # Leave raw mode so interactive script works normally
  stty "$SAVED_STTY"
  printf '\033[?25h'
  clear

  # Provide a result file for the script to write to
  local rf
  rf="$(mktemp "/tmp/tui_result.${SCRIPTS[$selected]}.XXXX")"
  export TUI_RESULT_FILE="$rf"
  export TUI_ROOT="$ROOT_DIR"

  # Run script with full terminal access (NO PIPE)
  bash "$script"
  local rc=$?

  # Return to TUI raw mode
  stty -echo -icanon min 1 time 0
  printf '\033[?25l'

  # Default status if script didn't write result file content
  local st="[ERROR]"
  local msg="exit:${rc}"

  if [[ -s "$rf" ]]; then
    local parsed status_key message
    parsed="$(read_result_file "$rf")"
    status_key="${parsed%%|*}"
    message="${parsed#*|}"

    case "$status_key" in
      OK)   st="[OK]" ;;
      WARN) st="[WARN]" ;;
      ERROR|*) st="[ERROR]" ;;
    esac
    [[ -n "$message" ]] && msg="$message"
  fi

  rm -f "$rf"

  STATUS[$selected]="${st} ${msg}"
  needs_redraw=1
}

main() {
  discover_scripts

  # Enter raw mode for menu
  stty -echo -icanon min 1 time 0
  printf '\033[?25l'

  while true; do
    if (( needs_redraw )); then
      render
      needs_redraw=0
    fi

    case "$(read_key)" in
      k|'ESC[A'|'ESCOA')
        ((selected--)); (( selected < 0 )) && selected=$((${#SCRIPTS[@]} - 1))
        needs_redraw=1
        ;;
      j|'ESC[B'|'ESCOB')
        ((selected++)); (( selected >= ${#SCRIPTS[@]} )) && selected=0
        needs_redraw=1
        ;;
      "")
        run_selected
        # re-discover in case scripts were added/removed
        discover_scripts
        (( selected >= ${#SCRIPTS[@]} )) && selected=0
        needs_redraw=1
        ;;
      q|Q)
        break
        ;;
      *)
        ;;
    esac
  done
}

main
