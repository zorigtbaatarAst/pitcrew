#!/usr/bin/env bash
# lib/03-meters.sh — RAM/CPU meters (read live from the service's systemd
# cgroup) and the log error radar (tail of each service log).

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

mem_meter() {
  local cur max
  cur=$(systemctl --user show "$SESSION-$1.scope" -p MemoryCurrent --value 2>/dev/null)
  [[ "$cur" =~ ^[0-9]+$ ]] || { printf '%b' "${GREY}      —${RESET}"; return; }
  max=$(to_bytes "$(comp_max "$1")")
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
