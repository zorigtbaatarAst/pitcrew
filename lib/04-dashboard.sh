#!/usr/bin/env bash
# lib/04-dashboard.sh — the one-shot status table and the full-screen live
# "watch" dashboard (btop-style, flicker-free redraw).

status_table() {
  local dep st
  if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    say "  ${BOLD}deps${RESET}"
    for dep in "${PITCREW_DEPS[@]}"; do
      st=$(comp_state "dep-$dep")
      printf '    %b %-16s %s\n' "$(state_icon "$st")" "$dep" "${GREY}${st}${RESET}"
    done
    say ""
  fi
  printf '  %b%-12s %-34s %s%b\n' "$BOLD" "app" "backend              ram" "frontend             ram" "$RESET"
  local app bs fs bx fx
  for app in "${PITCREW_APPS[@]}"; do
    bs=$(comp_state "be-$app"); fs=$(comp_state "fe-$app")
    bx=""; fx=""
    [ "$bs" != down ] && [ "$bs" != n/a ] && ! scope_exists "be-$app" && ! win_exists "be-$app" && bx=" ${DIM}ext${RESET}"
    [ "$fs" != down ] && [ "$fs" != n/a ] && ! scope_exists "fe-$app" && ! win_exists "fe-$app" && fx=" ${DIM}ext${RESET}"
    printf '    %b%-12s%b %b %-8s %b:%-5s%b %b%b%b   %b %-8s %b:%-5s%b %b%b%b\n' \
      "$CYAN" "$app" "$RESET" \
      "$(state_icon "$bs")" "$bs" "$GREY" "${PITCREW_BE_PORT[$app]:--}" "$RESET" "$(mem_meter "be-$app")" "$(err_flag "be-$app")" "$bx" \
      "$(state_icon "$fs")" "$fs" "$GREY" "${PITCREW_FE_PORT[$app]:--}" "$RESET" "$(mem_meter "fe-$app")" "$(err_flag "fe-$app")" "$fx"
  done
  say ""
  say "  ${GREY}● up  ◐ starting  ✗ crashed  ○ down  · n/a  ⚡ errors in log  ext = started outside pitcrew${RESET}"
}

cmd_status() { banner; status_table; echo; }

err_flag_watch() { :; }  # placeholder kept out of watch cells (see comp_cell) — errors shown via err_s below

poll_scopes() { # fills MEM_CUR / CPU_PCT for every component (runs in main shell)
  local el_us=$1 c out ns cur dns cpu
  while IFS= read -r c; do
    out=$(systemctl --user show "$SESSION-$c.scope" -p MemoryCurrent -p CPUUsageNSec 2>/dev/null)
    cur=$(grep -oP 'MemoryCurrent=\K[0-9]+' <<< "$out" || true)
    ns=$(grep -oP 'CPUUsageNSec=\K[0-9]+' <<< "$out" || true)
    MEM_CUR[$c]=${cur:-}
    CPU_PCT[$c]=""
    if [ -n "$ns" ]; then
      if [ -n "${W_CPU[$c]:-}" ] && [ "$el_us" -gt 0 ]; then
        dns=$((ns - W_CPU[$c])); [ $dns -lt 0 ] && dns=0
        cpu=$((dns / (el_us * 10))); [ $cpu -gt 999 ] && cpu=999
        CPU_PCT[$c]="${cpu}%"
      fi
      W_CPU[$c]=$ns
    fi
  done < <(all_components)
}

comp_cell() { # $1 comp, $2 bar width → one aligned service cell (reads MEM_CUR/CPU_PCT)
  local c=$1 bw=$2 st port cur max pct cpu_s mem_s en err_s
  st=$(comp_state "$c"); port=$(comp_port "$c")
  cur=${MEM_CUR[$c]:-}
  printf '%b ' "$(state_icon "$st")"
  if [ "$st" = n/a ]; then
    printf '%b%-5s%b ' "$GREY" "n/a" "$RESET"
  else
    printf '%b:%-5s%b ' "$GREY" "${port:--}" "$RESET"
  fi
  if [[ "$cur" =~ ^[0-9]+$ ]]; then
    max=$(to_bytes "$(comp_max "$c")")
    pct=$((cur * 100 / max))
    bar "$pct" "$bw"
    mem_s=$(human "$cur")
    cpu_s=${CPU_PCT[$c]:-"·"}
    printf ' %6s %4s' "$mem_s" "$cpu_s"
  elif [ "$st" = up ] || [ "$st" = starting ]; then
    printf '%b%*s%b' "$DIM$GREY" "$bw" "external" "$RESET"
    printf ' %6s %4s' "—" "—"
  else
    printf '%b%*s%b' "$DIM$GREY" "$bw" "" "$RESET"
    printf ' %6s %4s' "" ""
  fi
  en=$(err_n "$c"); err_s="   "
  [ "${en:-0}" -gt 0 ] && { err_s="⚡$en"; printf ' %b%-3s%b' "$RED" "$err_s" "$RESET"; return; }
  printf ' %-3s' "$err_s"
}

cmd_watch() {
  local W bw frame line key ts el_us now_us pick sc
  local p_total=0 p_idle=0 cpu_pct=0
  declare -A W_CPU=() MEM_CUR=() CPU_PCT=()
  local last_us=0
  tput smcup 2>/dev/null; tput civis 2>/dev/null
  trap 'printf "\033[?7h"; tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; trap - INT; return 0' INT
  while true; do
    printf '\033[?7l'   # no auto-wrap: a too-wide line must never break the repaint line count
    W=$(tput cols 2>/dev/null); [ -n "$W" ] || W=100
    bw=$(( (W - 64) / 2 )); [ $bw -lt 6 ] && bw=6; [ $bw -gt 22 ] && bw=22
    now_us=${EPOCHREALTIME/./}; now_us=${now_us:0:16}
    el_us=$((now_us - last_us)); last_us=$now_us
    [ $el_us -le 0 ] || [ $el_us -gt 10000000 ] && el_us=0

    # ── system gauges ──
    local total idle d_total d_idle
    read -r _ u n s i iow irq sirq steal _ < /proc/stat
    total=$((u + n + s + i + iow + irq + sirq + steal)); idle=$((i + iow))
    d_total=$((total - p_total)); d_idle=$((idle - p_idle))
    [ $d_total -gt 0 ] && cpu_pct=$(( (d_total - d_idle) * 100 / d_total ))
    p_total=$total; p_idle=$idle
    local m_total m_avail m_used m_pct
    m_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    m_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    m_used=$((m_total - m_avail)); m_pct=$((m_used * 100 / m_total))
    poll_scopes "$el_us"

    # ── build the frame off-screen, then paint once (no blinking) ──
    ts=$(date +%H:%M:%S)
    frame=""
    printf -v line '%b── %b%s · live%b ' "$CYAN" "$BOLD" "${PITCREW_PROJECT_NAME:-pitcrew}" "$RESET$CYAN"
    local rule_len=$((W - 12 - ${#PITCREW_PROJECT_NAME} - ${#ts})) r=""
    [ $rule_len -lt 0 ] && rule_len=0
    while [ ${#r} -lt $rule_len ]; do r+="─"; done
    frame+="$line$r $ts ──$RESET"$'\e[K\n\e[K\n'
    printf -v line '   %bCPU%b ' "$BOLD" "$RESET"
    frame+="$line$(bar "$cpu_pct" 20)"
    printf -v line ' %3s%%      %bRAM%b ' "$cpu_pct" "$BOLD" "$RESET"
    frame+="$line$(bar "$m_pct" 20)"
    printf -v line ' %s / %s' "$(human $((m_used * 1024)))" "$(human $((m_total * 1024)))"
    frame+="$line"$'\e[K\n\e[K\n'

    # ── deps ──
    if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
      local dep dline="   "
      for dep in "${PITCREW_DEPS[@]}"; do
        dline+="$(state_icon "$(comp_state "dep-$dep")") $dep   "
      done
      frame+="${GREY}── deps ${RESET}"$'\e[K\n'"$dline"$'\e[K\n\e[K\n'
    fi

    # ── services ──
    frame+="${GREY}── services ${RESET}"$'\e[K\n'
    printf -v line '   %b%-11s %-*s %s%b' "$BOLD$GREY" "app" "$((bw + 24))" "backend   ram        cpu" "frontend   ram        cpu" "$RESET"
    frame+="$line"$'\e[K\n'
    local app
    for app in "${PITCREW_APPS[@]}"; do
      printf -v line '   %b%-11s%b ' "$CYAN" "$app" "$RESET"
      line+="$(comp_cell "be-$app" "$bw")"
      line+="  $(comp_cell "fe-$app" "$bw")"
      frame+="$line"$'\e[K\n'
    done
    frame+=$'\e[K\n'
    printf -v line '   %b● up  ◐ starting  ✗ crashed  ○ down  · n/a  ⚡ log errors%b' "$DIM$GREY" "$RESET"
    frame+="$line"$'\e[K\n\e[K\n'
    printf -v line ' %bq%b quit  %bl%b logs  %bs%b stop  %bg%b grid  %bm%b menu  %b· refresh 2s%b' \
      "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$DIM$GREY" "$RESET"
    frame+="$line"$'\e[K'

    printf '\033[H%b\033[0J' "$frame"

    key=""
    read -rsn1 -t 2 key 2>/dev/null || true
    case "$key" in
      q|Q) break ;;
      l|L) log_view; last_us=0 ;;   # same alt screen — switch logs in place, q comes back here
      s|S) if command -v fzf >/dev/null; then
             printf '\033[?7h'; tput rmcup 2>/dev/null; tput cnorm 2>/dev/null
             pick=$(running_comps | fzf --multi --height=40% --border=rounded \
               --prompt='stop ❯ ' --pointer='▶' --marker='✔ ' \
               --header='TAB = select several · Enter = stop · Esc = cancel') || pick=""
             while IFS= read -r sc; do [ -n "$sc" ] && stop_comp "$sc"; done <<< "$pick"
             tput smcup 2>/dev/null; tput civis 2>/dev/null
           fi
           last_us=0 ;;
      g|G) printf '\033[?7h'; tput rmcup 2>/dev/null; tput cnorm 2>/dev/null
           cmd_grid
           tput smcup 2>/dev/null; tput civis 2>/dev/null; last_us=0 ;;
      m|M) if command -v fzf >/dev/null; then
             printf '\033[?7h'; tput rmcup 2>/dev/null; tput cnorm 2>/dev/null
             menu
             tput smcup 2>/dev/null; tput civis 2>/dev/null
           fi
           last_us=0 ;;
    esac
  done
  trap - INT
  printf '\033[?7h'; tput cnorm 2>/dev/null; tput rmcup 2>/dev/null
}
