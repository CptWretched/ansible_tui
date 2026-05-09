#!/bin/bash
# =========================================================
# ping_test.sh
# - Prompt for inventory group
# - Confirm run (bold green "X nodes")
# - Pre-fetch hostnames (best effort) for reachable nodes
# - Run playbook with LIVE, CLEAN output:
#     * CONNECTIVITY RESULTS: IP + hostname + PASS/UNREACH/FAIL
#     * PLAY RECAP (as-is)
#     * RESULTS summary (PASS/UNREACH/FAIL lists with hostnames)
# - Write results to $TUI_RESULT_FILE for the TUI to read
# =========================================================

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

INVENTORY="${ROOT_DIR}/playbooks/inventory"
PLAYBOOK="${ROOT_DIR}/playbooks/ping_test.yml"

RESULT_FILE="${TUI_RESULT_FILE:-/tmp/tui_result.ping_test.$$}"

# Colors (prompt/labels only)
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

# Best-effort: hostname prefetch uses ansible (ad-hoc)
HAS_ANSIBLE=1
command -v ansible >/dev/null 2>&1 || HAS_ANSIBLE=0

# Keep output quieter if a different ansible.cfg is used
export ANSIBLE_DEPRECATION_WARNINGS=False

# ---------------- Discover selectable groups from inventory (CRLF-safe) ----------------
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
# ✅ Bold + green for the ENTIRE "7 nodes"
printf "Run ping_test against group %s (%b%b%d nodes%b)? (yes/no): " \
  "$chosen_group" "$BOLD" "$GREEN" "$node_count" "$RESET"
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

# ---------------- Pre-fetch hostnames (best effort) ----------------
# Creates a tab-delimited mapping file: "IP<TAB>hostname"
hostmap="$(mktemp "/tmp/tui_hostmap_${chosen_group}.XXXX")"
: > "$hostmap"

if (( HAS_ANSIBLE )); then
  # This may return non-zero if some hosts are unreachable; that's OK.
  # We only capture successful hostnames.
  set +e
  ansible "$chosen_group" -i "$INVENTORY" -m command -a hostname -o 2>/dev/null \
    | awk -F' \\| ' '
        # expected: host | SUCCESS/CHANGED | rc=0 | (stdout) hostname
        ($0 ~ /\| (SUCCESS|CHANGED) \|/) {
          host=$1;
          out=$NF;
          sub(/^\(stdout\)[[:space:]]*/, "", out);
          if (host != "" && out != "") print host "\t" out;
        }
      ' > "$hostmap"
  set -e
fi

# ---------------- Live output: clean per-host status + final RESULTS ----------------
logfile="/tmp/tui_ping_test_${chosen_group}_$(date +%Y%m%d_%H%M%S).log"

set +e
ansible-playbook "$PLAYBOOK" -i "$INVENTORY" --limit "$chosen_group" 2>&1 \
  | tee "$logfile" \
  | awk -v mapfile="$hostmap" '
    BEGIN {
      in_ping_task=0;
      in_recap=0;
      printed_conn_hdr=0;

      # load host->hostname map
      while ((getline line < mapfile) > 0) {
        n=split(line, a, "\t");
        if (n >= 2) {
          host=a[1];
          hn=a[2];
          # in case hostname contains tabs/spaces (rare), rebuild remainder
          if (n > 2) {
            for (i=3; i<=n; i++) hn = hn "\t" a[i];
          }
          host2hn[host]=hn;
        }
      }
      close(mapfile);
    }

    # Drop noise
    /^\[DEPRECATION WARNING\]/ {next}
    /^\[WARNING\]/ {next}

    # Print PLAY header once
    /^PLAY \[/ { print $0; next }

    # Detect ping task
    /^TASK \[Ping hosts/ {
      in_ping_task=1;
      in_recap=0;
      if (!printed_conn_hdr) {
        print "";
        print "CONNECTIVITY RESULTS:";
        printed_conn_hdr=1;
      }
      next
    }

    # Leaving ping task when next TASK begins
    /^TASK \[/ {
      if (in_ping_task==1) in_ping_task=0;
      next
    }

    # helper: get hostname or "-"
    function hn_for(h) {
      if (h in host2hn) return host2hn[h];
      return "-";
    }

    # While in ping task: ok line
    in_ping_task==1 && /^ok: \[/ {
      host=$0;
      sub(/^ok: \[/,"",host);
      sub(/\].*/,"",host);
      status[host]="PASS";
      printf("  %-16s  %-18s  PASS\n", host, hn_for(host));
      next
    }

    # unreachable
    in_ping_task==1 && /^fatal: \[/ && /UNREACHABLE!/ {
      host=$0;
      sub(/^fatal: \[/,"",host);
      sub(/\].*/,"",host);

      reason=$0;
      if (reason ~ /Connection timed out/) reason="Connection timed out";
      else if (reason ~ /No route to host/) reason="No route to host";
      else if (reason ~ /Connection refused/) reason="Connection refused";
      else if (reason ~ /Permission denied/) reason="Permission denied";
      else reason="Unreachable";

      status[host]="UNREACH";
      printf("  %-16s  %-18s  UNREACH  (%s)\n", host, hn_for(host), reason);
      next
    }

    # failed (not unreachable)
    in_ping_task==1 && /^fatal: \[/ && /FAILED!/ {
      host=$0;
      sub(/^fatal: \[/,"",host);
      sub(/\].*/,"",host);
      status[host]="FAIL";
      printf("  %-16s  %-18s  FAIL\n", host, hn_for(host));
      next
    }

    # Start recap
    /^PLAY RECAP/ {
      in_recap=1;
      print "";
      print $0;
      next
    }

    # Print recap lines and finalize statuses
    in_recap==1 && /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
      print $0;

      host=$1;
      un=0; fl=0;
      for(i=1;i<=NF;i++){
        if($i ~ /^unreachable=/){ split($i,a,"="); un=a[2]; }
        if($i ~ /^failed=/){ split($i,b,"="); fl=b[2]; }
      }

      if (un > 0) status[host]="UNREACH";
      else if (fl > 0) status[host]="FAIL";
      else if (status[host] == "") status[host]="PASS";

      next
    }

    END {
      pass_n=0; un_n=0; fail_n=0;
      for (h in status) {
        if (status[h]=="PASS") pass[pass_n++]=h;
        else if (status[h]=="UNREACH") un[un_n++]=h;
        else if (status[h]=="FAIL") fail[fail_n++]=h;
      }

      print "";
      print "RESULTS:";

      printf("  PASS   (%d):", pass_n);
      if (pass_n==0) print " (none)";
      else {
        for(i=0;i<pass_n;i++){
          h=pass[i];
          printf(" %s(%s)", h, hn_for(h));
        }
        print ""
      }

      printf("  UNREACH(%d):", un_n);
      if (un_n==0) print " (none)";
      else {
        for(i=0;i<un_n;i++){
          h=un[i];
          printf(" %s(%s)", h, hn_for(h));
        }
        print ""
      }

      printf("  FAIL   (%d):", fail_n);
      if (fail_n==0) print " (none)";
      else {
        for(i=0;i<fail_n;i++){
          h=fail[i];
          printf(" %s(%s)", h, hn_for(h));
        }
        print ""
      }
    }
  '
exit_code=${PIPESTATUS[0]}
set -e

rm -f "$hostmap" 2>/dev/null || true

# ---------------- Post-process stats for TUI ----------------
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
