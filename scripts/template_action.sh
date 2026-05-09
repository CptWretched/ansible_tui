#!/bin/bash#!/ =========================================================
# _template_action.sh - MojaveOps TUI Script Template
#
# How to use:
#   1) Copy:   cp scripts/_template_action.sh scripts/my_new_task.sh
#   2) Edit:   set PLAYBOOK name, TASK_NAME, and summary style
#   3) chmod:  chmod +x scripts/my_new_task.sh
#   4) Run via TUI
#
# This template:
# - lists groups from playbooks/inventory
# - prompts for group
# - shows bold green "(X nodes)"
# - optionally prefetches hostnames
# - runs a playbook and prints a clean connectivity-style summary
# - writes STATUS/MESSAGE/NODES/TASKS to $TUI_RESULT_FILE for the TUI
# =========================================================

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# ---- Customize these 3 lines for new scripts ----
TASK_NAME="Ping Test"
PLAYBOOK="${ROOT_DIR}/playbooks/ping_test.yml"
INVENTORY="${ROOT_DIR}/playbooks/inventory"
# -----------------------------------------------

# Load shared formatting + helpers
# shellcheck source=scripts/_lib_mojaveops.sh
source "${ROOT_DIR}/scripts/_lib_mojaveops.sh"

# Optional toggles (keep MVP simple)
PREFETCH_HOSTNAMES=1     # 1=try to get hostnames for reachable nodes
USE_CONNECTIVITY_SUMMARY=1  # 1=use connectivity summary streamer (best for ping-like playbooks)

# Preflight
mo_require_file "$INVENTORY" "Inventory" || exit 1
mo_require_file "$PLAYBOOK" "Playbook" || exit 1
mo_require_cmd "ansible-playbook" || exit 1

echo ""
echo "=== ${TASK_NAME} ==="
echo ""

# Show groups
mapfile -t GROUPS < <(mo_discover_groups "$INVENTORY")
if (( ${#GROUPS[@]} == 0 )); then
  mo_err "No selectable groups found"
  mo_write_result "ERROR" "No groups found" 0 0
  exit 1
fi

echo "Available inventory groups:"
echo ""
for g in "${GROUPS[@]}"; do echo "  * $g"; done
echo ""

# Prompt group
printf "Enter group name: "
read -r chosen_group
chosen_group="$(mo_trim "${chosen_group%$'\r'}")"

valid=false
for g in "${GROUPS[@]}"; do [[ "$g" == "$chosen_group" ]] && valid=true && break; done
if ! $valid || [[ -z "$chosen_group" ]]; then
  mo_err "'$chosen_group' is not a valid group."
  mo_write_result "ERROR" "Invalid group: $chosen_group" 0 0
  exit 1
fi

# Count nodes
node_count="$(mo_count_nodes_in_group "$INVENTORY" "$chosen_group")"
echo ""

# Confirm
if ! mo_confirm_group_run "$chosen_group" "$node_count"; then
  mo_warn "Aborted by user."
  mo_write_result "WARN" "Aborted" "$node_count" 0
  exit 0
fi

echo ""
mo_info "Running ${TASK_NAME} against group: ${chosen_group}"
echo ""

# Prefetch hostnames (optional)
hostmap="$(mktemp "/tmp/tui_hostmap_${chosen_group}.XXXX")"
: > "$hostmap"
if (( PREFETCH_HOSTNAMES )); then
  mo_prefetch_hostnames "$INVENTORY" "$chosen_group" "$hostmap"
fi

# Run playbook (log full output)
logfile="/tmp/tui_${TASK_NAME// /_}_${chosen_group}_$(date +%Y%m%d_%H%M%S).log"

export ANSIBLE_DEPRECATION_WARNINGS=False

set +e
if (( USE_CONNECTIVITY_SUMMARY )); then
  ansible-playbook "$PLAYBOOK" -i "$INVENTORY" --limit "$chosen_group" 2>&1 \
    | tee "$logfile" \
    | mo_stream_connectivity_summary "$hostmap"
else
  # Fallback: show raw-ish live output (not recommended unless needed)
  ansible-playbook "$PLAYBOOK" -i "$INVENTORY" --limit "$chosen_group" 2>&1 | tee "$logfile"
fi
exit_code=${PIPESTATUS[0]}
set -e

rm -f "$hostmap" 2>/dev/null || true

# Compute task count (simple heuristic)
task_count="$(grep -c '^TASK \[' "$logfile" 2>/dev/null || echo 0)"
unreach_count="$(awk '
  /: ok=/ && /unreachable=/ {
    for(i=1;i<=NF;i++){
      if($i ~ /^unreachable=/){
        split($i,a,"=")
        if(a[2] > 0) c++
      }
    }
  }
  END{print c+0}
' "$logfile" 2>/dev/null || echo 0)"

echo ""
if [[ $exit_code -eq 0 ]]; then
  mo_ok "Completed successfully"
  mo_write_result "OK" "Completed" "$node_count" "$task_count"
elif [[ $exit_code -eq 4 ]]; then
  mo_warn "Completed with unreachable hosts (exit 4)"
  mo_write_result "WARN" "Unreachable hosts: ${unreach_count}" "$node_count" "$task_count"
else
  mo_err "Failed (exit $exit_code)"
  mo_write_result "ERROR" "Failed (exit $exit_code)" "$node_count" "$task_count"
fi

echo ""
printf "Press any key to return..."
read -rsn1 </dev/tty
echo ""

exit "$exit_code"
``
