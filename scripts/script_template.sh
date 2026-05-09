#!/bin/bash
# =================================================ojaveops.sh - Shared helpers for MojaveOps TUI scripts# =========================================================
# Bash 4.4+
#
# Provides:
# - Colors + consistent logging
# - Result file contract writer (STATUS/MESSAGE/NODES/TASKS)
# - CRLF-safe inventory group parsing + node counting
# - Confirmation prompt with bold green "(X nodes)"
# - Best-effort hostname prefetch (IP -> hostname)
# =========================================================

set -u

# ---------- Colors (safe defaults) ----------
MO_RESET=$'\033[0m'
MO_DIM=$'\033[38;5;244m'
MO_CYAN=$'\033[38;5;117m'
MO_GREEN=$'\033[38;5;114m'
MO_YELLOW=$'\033[38;5;221m'
MO_RED=$'\033[38;5;203m'
MO_BOLD=$'\033[1m'

# ---------- Logging (consistent tags) ----------
mo_info()  { printf "%b[INFO]%b %s\n"  "$MO_CYAN"  "$MO_RESET" "$*"; }
mo_ok()    { printf "%b[OK]%b   %s\n"  "$MO_GREEN" "$MO_RESET" "$*"; }
mo_warn()  { printf "%b[WARN]%b %s\n"  "$MO_YELLOW" "$MO_RESET" "$*"; }
mo_err()   { printf "%b[ERROR]%b %s\n" "$MO_RED"   "$MO_RESET" "$*"; }

# ---------- String helpers ----------
mo_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "$s"
}

# ---------- Result file contract ----------
# TUI provides TUI_RESULT_FILE; scripts write to it at the end.
mo_result_file() {
  printf "%s" "${TUI_RESULT_FILE:-/tmp/tui_result.$$}"
}

mo_write_result() {
  # Usage: mo_write_result OK|WARN|ERROR "Message" nodes tasks
  local status="$1" msg="$2" nodes="${3:-0}" tasks="${4:-0}"
  local rf
  rf="$(mo_result_file)"
  {
    echo "STATUS=${status}"
    echo "MESSAGE=${msg}"
    echo "NODES=${nodes}"
    echo "TASKS=${tasks}"
  } > "$rf"
}

# ---------- Sanity checks ----------
mo_require_file() {
  local f="$1" label="${2:-file}"
  if [[ ! -f "$f" ]]; then
    mo_err "${label} not found: $f"
    mo_write_result "ERROR" "${label} missing" 0 0
    return 1
  fi
  return 0
}

mo_require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    mo_err "$cmd not found in PATH"
    mo_write_result "ERROR" "$cmd missing" 0 0
    return 1
  fi
  return 0
}

# ---------- Inventory parsing (INI, CRLF-safe) ----------
mo_discover_groups() {
  # Usage: mo_discover_groups /path/to/inventory
  # Prints group names (one per line) to stdout
  local inv="$1"
  local line header base suffix
  declare -A seen=()

  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="$(mo_trim "$line")"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

    if [[ "$line" =~ ^\[([A-Za-z0-9_:-]+)\]$ ]]; then
      header="${BASH_REMATCH[1]}"
      base="${header%%:*}"
      suffix=""
      [[ "$header" == *:* ]] && suffix="${header#*:}"

      [[ "$suffix" == "vars" || "$suffix" == "children" ]] && continue
      [[ "$base" == "all" || "$base" == "ungrouped" ]] && continue

      seen["$base"]=1
    fi
  done < "$inv"

  for base in "${!seen[@]}"; do
    printf "%s\n" "$base"
  done | sort
}

mo_count_nodes_in_group() {
  # Usage: mo_count_nodes_in_group /path/to/inventory group
  local inv="$1" group="$2"
  local line header base suffix in_group=false count=0 host

  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    line="${line%%;*}"
    line="$(mo_trim "$line")"
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[([A-Za-z0-9_:-]+)\]$ ]]; then
      header="${BASH_REMATCH[1]}"
      base="${header%%:*}"
      suffix=""
      [[ "$header" == *:* ]] && suffix="${header#*:}"

      if [[ "$base" == "$group" && -z "$suffix" ]]; then
        in_group=true
      else
        in_group=false
      fi
      continue
    fi

    if $in_group; then
      host="${line%%[[:space:]]*}"
      [[ -n "$host" ]] && ((count++))
    fi
  done < "$inv"

  printf "%d" "$count"
}

# ---------- Confirmation prompt formatting ----------
mo_confirm_group_run() {
  # Usage: mo_confirm_group_run group node_count
  local group="$1" nodes="$2" confirm
  printf "Run against group %s (%b%b%d nodes%b)? (yes/no): " \
    "$group" "$MO_BOLD" "$MO_GREEN" "$nodes" "$MO_RESET"
  read -r confirm
  confirm="$(mo_trim "${confirm%$'\r'}")"
  [[ "$confirm" == "yes" ]]
}

# ---------- Hostname prefetch (best effort) ----------
mo_prefetch_hostnames() {
  # Usage: mo_prefetch_hostnames inventory group output_mapfile
  # Writes tab-delimited "IP<TAB>hostname" lines to output_mapfile
  local inv="$1" group="$2" out="$3"
  : > "$out"

  # If ansible isn't available, skip
  command -v ansible >/dev/null 2>&1 || return 0

  # Some hosts may be unreachable; ignore errors
  set +e
  ansible "$group" -i "$inv" -m command -a hostname -o 2>/dev/null \
    | awk -F' \\| ' '
        ($0 ~ /\| (SUCCESS|CHANGED) \|/) {
          host=$1;
          out=$NF;
          sub(/^\(stdout\)[[:space:]]*/, "", out);
          if (host != "" && out != "") print host "\t" out;
        }
      ' > "$out"
  set -e
}

# ---------- Clean connectivity summary (for ping-like playbooks) ----------
mo_stream_connectivity_summary() {
  # Usage:
  #   mo_stream_connectivity_summary mapfile
  #
  # Reads ansible-playbook output from stdin and prints:
  # - PLAY header
  # - CONNECTIVITY RESULTS (IP + hostname + PASS/UNREACH/FAIL)
  # - PLAY RECAP lines
  # - RESULTS rollup with hostnames
  #
  # Note: Designed for playbooks where the first task is "Ping hosts..."
  local mapfile="$1"

  awk -v mapfile="$mapfile" '
    BEGIN {
      in_ping_task=0; in_recap=0; printed_conn_hdr=0;

      # load host->hostname map
      while ((getline line < mapfile) > 0) {
        n=split(line, a, "\t");
        if (n >= 2) {
          host=a[1];
          hn=a[2];
          if (n > 2) { for (i=3; i<=n; i++) hn = hn "\t" a[i]; }
          host2hn[host]=hn;
        }
      }
      close(mapfile);
    }

    # Drop noise
    /^\[DEPRECATION WARNING\]/ {next}
    /^\[WARNING\]/ {next}

    # PLAY header
    /^PLAY \[/ { print $0; next }

    # Detect ping task by name
    /^TASK \[Ping hosts/ {
      in_ping_task=1; in_recap=0;
      if (!printed_conn_hdr) {
        print "";
        print "CONNECTIVITY RESULTS:";
        printed_conn_hdr=1;
      }
      next
    }

    # Leaving ping task at next TASK
    /^TASK \[/ { if (in_ping_task==1) in_ping_task=0; next }

    function hn_for(h) { return (h in host2hn) ? host2hn[h] : "-"; }

    # PASS
    in_ping_task==1 && /^ok: \[/ {
      host=$0; sub(/^ok: \[/,"",host); sub(/\].*/,"",host);
      status[host]="PASS";
      printf("  %-16s  %-18s  PASS\n", host, hn_for(host));
      next
    }

    # UNREACH
    in_ping_task==1 && /^fatal: \[/ && /UNREACHABLE!/ {
      host=$0; sub(/^fatal: \[/,"",host); sub(/\].*/,"",host);

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

    # FAIL
    in_ping_task==1 && /^fatal: \[/ && /FAILED!/ {
      host=$0; sub(/^fatal: \[/,"",host); sub(/\].*/,"",host);
      status[host]="FAIL";
      printf("  %-16s  %-18s  FAIL\n", host, hn_for(host));
      next
    }

    # Recap start
    /^PLAY RECAP/ { in_recap=1; print ""; print $0; next }

    # Recap lines + finalize
    in_recap==1 && /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
      print $0;
      host=$1; un=0; fl=0;
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
      else { for(i=0;i<pass_n;i++){ h=pass[i]; printf(" %s(%s)", h, hn_for(h)); } print "" }

      printf("  UNREACH(%d):", un_n);
      if (un_n==0) print " (none)";
      else { for(i=0;i<un_n;i++){ h=un[i]; printf(" %s(%s)", h, hn_for(h)); } print "" }

      printf("  FAIL   (%d):", fail_n);
      if (fail_n==0) print " (none)";
      else { for(i=0;i<fail_n;i++){ h=fail[i]; printf(" %s(%s)", h, hn_for(h)); } print "" }
    }
  '
}
