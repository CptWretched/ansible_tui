#!/bin/bash
# =================================================# ping_test.sh - Runs playbooks/ping_test.yml with a chosen group# =========================================================
# Live output (friendly filtered) + writes results to $TUI_RESULT_FILE
# =========================================================

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

INVENTORY="${ROOT_DIR}/playbooks/inventory"
PLAYBOOK="${ROOT_DIR}/playbooks/ping_test.yml"

RESULT_FILE="${TUI_RESULT_FILE:-/tmp/tui_result.ping_test.$$}"

# Colors (for prompts)
RESET=$'\033[0m'
DIM=$'\033[38;5;244m'
CYAN=$'\033[38;5;117m'
GREEN=$'\033[38;5;114m'
YELLOW=$'\033[38;5;221m'
RED=$'\033[38;5;203m'
BOLD=$'\033[1m'

write_result() {
  local status="$1" message="$2" nodes="$3" tasks="$4"
  {
    echo "STATUS=${status}"
    echo "MESSAGE=${message}"
    echo "NODES=${nodes}"
    echo "TASKS=${tasks}"
  } > "$RESULT_FILE"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# ---------------- Preflight ----------------
if [[ ! -f "$INVENTORY" ]]; then
  echo "[ERROR] Inventory not found: $INVENTORY"
  write_result "ERROR" "Inventory missing" 0 0
  exit 1
fi

if [[ ! -f "$PLAYBOOK" ]]; then
  echo "[ERROR] Playbook not found: $PLAYBOOK"
  write_result "ERROR" "Playbook missing" 0 0
  exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "[ERROR] ansible-playbook not found in PATH"
  write_result "ERROR" "ansible-playbook missing" 0 0
  exit 1
fi

# Reduce noise (you already have deprecation_warnings=False in ansible.cfg,
# but this env var helps ensure it stays quiet in different contexts)
export ANSIBLE_DEPRECATION_WARNINGS=False

# ---------------- Discover groups (simple, CRLF-safe) ----------------
groups=()
while IFS= read -r line; do
  line="${line%$'\r'}"
  line="$(trim "$line")"
  [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

  if [[ "$line" =~ ^\[([A-Za-z0-9_:-]+)\]$ ]]; then
    header="${BASH_REMATCH[1]}"
    base="${header%%:*}"
    suffix=""
    [[ "$header" == *:* ]] && suffix="${header#*:}"
    [[ "$suffix" == "vars" || "$suffix" == "children" ]] && continue
    [[ "$base" == "all" || "$base" == "ungrouped" ]] && continue

    seen=false
    for g in "${groups[@]}"; do [[ "$g" == "$base" ]] && seen=true && break; done
    $seen || groups+=("$base")
  fi
done < "$INVENTORY"

if [[ ${#groups[@]} -eq 0 ]]; then
  echo "[ERROR] No selectable groups found in inventory"
  write_result "ERROR" "No groups found" 0 0
  exit 1
fi

# ---------------- UI ----------------
echo ""
echo "Available inventory groups:"
echo ""
for g in "${groups[@]}"; do echo "  * $g"; done
echo ""

printf "Enter group name: "
read -r chosen_group
chosen_group="$(trim "${chosen_group%$'\r'}")"

valid=false
for g in "${groups[@]}"; do [[ "$g" == "$chosen_group" ]] && valid=true && break; done
if ! $valid || [[ -z "$chosen_group" ]]; then
  echo "[ERROR] '$chosen_group' is not a valid group."
  write_result "ERROR" "Invalid group: $chosen_group" 0 0
  exit 1
fi

# ---------------- Count nodes in group ----------------
node_count=0
in_group=false
while IFS= read -r line; do
  line="${line%$'\r'}"
  line="${line%%#*}"
  line="${line%%;*}"
  line="$(trim "$line")"
  [[ -z "$line" ]] && continue

  if [[ "$line" =~ ^\[([A-Za-z0-9_:-]+)\]$ ]]; then
    header="${BASH_REMATCH[1]}"
    base="${header%%:*}"
    suffix=""
    [[ "$header" == *:* ]] && suffix="${header#*:}"
    if [[ "$base" == "$chosen_group" && -z "$suffix" ]]; then in_group=true; else in_group=false; fi
    continue
  fi

  if $in_group; then
    host="${line%%[[:space:]]*}"
    [[ -n "$host" ]] && ((node_count++))
  fi
done < "$INVENTORY"

echo ""
# ✅ Node count in green again:
printf "Run ping_test against group %s (%b%d%b nodes)? (yes/no): " \
  "$chosen_group" "$GREEN" "$node_count" "$RESET"
read -r confirm
confirm="$(trim "${confirm%$'\r'}")"

if [[ "$confirm" != "yes" ]]; then
  echo "[WARN] Aborted by user."
  write_result "WARN" "Aborted" "$node_count" 0
  exit 0
fi

echo ""
echo "[INFO] Running playbook against group: $chosen_group"
echo ""

# ---------------- Live output (friendly filter) ----------------
# We keep a full log for debugging, but stream a readable view to the screen.
logfile="/tmp/tui_ping_test_${chosen_group}_$(date +%Y%m%d_%H%M%S).log"

# Friendly output filter:
# Show PLAY/TASK headers, host status lines, recap section. Suppress most warnings/noise.
friendly_filter='
/^\[DEPRECATION WARNING\]/ {next}
/^\[WARNING\]/ {next}
/^PLAY \[/ {print; next}
/^TASK \[/ {print ""; print; next}
/^(ok|changed|skipping|fatal):/ {print; next}
/UNREACHABLE!/ {print; next}
/^PLAY RECAP/ {print ""; print; next}
/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print; next}
{next}
'

# Run Ansible with live output; store full output to logfile.
# No interactive prompts occur after this point, so piping is safe.
set +e
ansible-playbook "$PLAYBOOK" -i "$INVENTORY" --limit "$chosen_group" 2>&1 \
  | tee "$logfile" \
  | awk "$friendly_filter"
exit_code=${PIPESTATUS[0]}
set -e

# ---------------- Post-process stats ----------------
# Count tasks as number of TASK headers in the full log
task_count="$(grep -c '^TASK \[' "$logfile" 2>/dev/null || echo 0)"

# Count unreachable hosts (count recap lines where unreachable= is > 0)
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
  echo "[OK] Playbook completed successfully"
  write_result "OK" "Completed" "$node_count" "$task_count"
elif [[ $exit_code -eq 4 ]]; then
  echo "[WARN] Playbook completed with unreachable hosts (exit 4)"
  write_result "WARN" "Unreachable hosts: ${unreach_count}" "$node_count" "$task_count"
else
  echo "[ERROR] Playbook finished with errors (exit $exit_code)"
  write_result "ERROR" "Playbook failed (exit $exit_code)" "$node_count" "$task_count"
fi

echo ""
printf "Press any key to return..."
read -rsn1 </dev/tty
echo ""

exit "$exit_code"

