#!/usr/bin/env bash
# lib/04-meters.sh — RAM/CPU meters (summed over each component's whole
# process tree via `ps`, portable across Linux/macOS) and the log error
# radar (tail of each service log).

to_bytes() {
  local n=${1%[GgMm]}
  case "$1" in *G|*g) echo $((n * 1024 ** 3)) ;; *M|*m) echo $((n * 1024 ** 2)) ;; *) echo "$1" ;; esac
}

human() {
  awk -v b="$1" 'BEGIN{ if (b >= 1073741824) printf "%.1fG", b/1073741824; else printf "%dM", b/1048576 }'
}

bar() { # $1 pct, $2 width → colored block bar
  local pct=$1 w=$2 filled i out color=$GREEN
  [ "$pct" -ge 60 ] && color=$YELLOW
  [ "$pct" -ge 85 ] && color=$RED
  filled=$((pct * w / 100)); [ $filled -gt "$w" ] && filled=$w; [ $filled -lt 0 ] && filled=0
  out="$color"
  for ((i = 0; i < filled; i++)); do out+="█"; done
  out+="$DIM$GREY"
  for ((i = filled; i < w; i++)); do out+="░"; done
  printf '%b' "$out$RESET"
}

# fills MEM_CUR[comp] (bytes) / CPU_PCT[comp] ("NN%") for every configured
# component — one `ps` call per live component, via its whole process tree.
poll_all() {
  declare -gA MEM_CUR CPU_PCT
  local c pid
  while IFS= read -r c; do
    pid=$(read_pid "$c")
    if pid_alive "$pid"; then
      proc_tree_stats "$pid"
      MEM_CUR[$c]=""; [ -n "$PSTREE_RSS_KB" ] && MEM_CUR[$c]=$((PSTREE_RSS_KB * 1024))
      CPU_PCT[$c]=""; [ -n "$PSTREE_CPU_PCT" ] && CPU_PCT[$c]="${PSTREE_CPU_PCT}%"
    else
      MEM_CUR[$c]=""; CPU_PCT[$c]=""
    fi
  done < <(all_components)
}

mem_meter() { # $1 comp — one aligned "bar RAM" cell, or a dim "—" if not running
  local cur=${MEM_CUR[$1]:-}
  [[ "$cur" =~ ^[0-9]+$ ]] || { printf '%b' "${GREY}      —${RESET}"; return; }
  local max; max=$(to_bytes "$(comp_max "$1")")
  local idx=$((cur * 7 / max)); [ $idx -gt 7 ] && idx=7
  local pct=$((cur * 100 / max)) color=$GREEN
  [ $pct -ge 60 ] && color=$YELLOW
  [ $pct -ge 85 ] && color=$RED
  printf '%b%s %5s%b' "$color" "${BARS[$idx]}" "$(human "$cur")" "$RESET"
}

err_n() {
  local f="$LOG_DIR/$1.log"
  [ -f "$f" ] || { echo 0; return; }
  tail -n 150 "$f" 2>/dev/null | grep -cE 'ERROR|FATAL|Exception|UnhandledRejection' || true
}

err_flag() {
  local n; n=$(err_n "$1")
  [ "${n:-0}" -gt 0 ] && printf ' %b⚡%s%b' "$RED" "$n" "$RESET"
}
