#!/usr/bin/env bash
# run.sh - Entrypoint for the Ansible TUI launcher (MVP)
# Bash requirement: 4.4+
#
# Usage: ./run.sh
#
# Adding a new menu item:
#  - Drop an executable .sh file into ./actions
#  - Add metadata near the top:
#      # NAME: My Action
#      # DESC: What it does
#  - chmod +x actions/XX_my_action.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
ACTIONS_DIR="${SCRIPT_DIR}/actions"

# shellcheck source=lib/tui.sh
source "${LIB_DIR}/tui.sh"
# shellcheck source=lib/actions.sh
source "${LIB_DIR}/actions.sh"

main() {
  export TUI_ROOT="${SCRIPT_DIR}"
  export TUI_ACTIONS_DIR="${ACTIONS_DIR}"
  tui_main_loop
}

main "$@"

