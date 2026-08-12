#!/usr/bin/env bash
# lib/05-dashboard.sh — the one-shot status table and the full-screen live
# "watch" dashboard (flicker-free redraw, refreshes every 2s).

summary_line() {
  local c st up=0 starting=0 crashed=0 down=0
  while IFS= read -r c; do
    st=$(comp_state "$c")
    case "$st" in up) up=$((up+1));; starting) starting=$((starting+1));; \
                  crashed) crashed=$((crashed+1));; down) down=$((down+1));; esac
  done < <(all_components)
  printf '  %b%s up%b' "$GREEN" "$up" "$RESET"
  [ $starting -gt 0 ] && printf '  %b%s starting%b' "$YELLOW" "$starting" "$RESET"
  [ $crashed  -gt 0 ] && printf '  %b%s crashed%b'  "$RED" "$crashed" "$RESET"
  [ $down     -gt 0 ] && printf '  %b%s down%b'     "$GREY" "$down" "$RESET"
  printf '\n'
}

status_table() {
  poll_all
  local dep st
  if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    say "  ${BOLD}deps${RESET}"
    for dep in "${PITCREW_DEPS[@]}"; do
      st=$(comp_state "dep-$dep")
      printf '    %b %-16s %s\n' "$(state_icon "$st")" "$dep" "${GREY}${st}${RESET}"
    done
    say ""
  fi
  summary_line
  say ""
  printf '  %b%-12s %-34s %s%b\n' "$BOLD" "app" "backend              ram" "frontend             ram" "$RESET"
  local app bs fs bx fx
  for app in "${PITCREW_APPS[@]}"; do
    bs=$(comp_state "be-$app"); fs=$(comp_state "fe-$app")
    bx=""; fx=""
    is_external "be-$app" && bx=" ${DIM}ext${RESET}"
    is_external "fe-$app" && fx=" ${DIM}ext${RESET}"
    printf '    %b%-12s%b %b %-8s %b:%-5s%b %b%b%b   %b %-8s %b:%-5s%b %b%b%b\n' \
      "$CYAN" "$app" "$RESET" \
      "$(state_icon "$bs")" "$bs" "$GREY" "${PITCREW_BE_PORT[$app]:--}" "$RESET" "$(mem_meter "be-$app")" "$(err_flag "be-$app")" "$bx" \
      "$(state_icon "$fs")" "$fs" "$GREY" "${PITCREW_FE_PORT[$app]:--}" "$RESET" "$(mem_meter "fe-$app")" "$(err_flag "fe-$app")" "$fx"
  done
  say ""
  say "  ${GREY}● up  ◐ starting  ✗ crashed  ○ down  · n/a  ⚡ errors in log  ext = something else on that port${RESET}"
}

cmd_status() { banner; status_table; echo; }

comp_cell() { # $1 comp, $2 bar width → one aligned service cell (reads MEM_CUR/CPU_PCT)
  local c=$1 bw=$2 st port cur pct cpu_s mem_s en err_s
  st=$(comp_state "$c"); port=$(comp_port "$c")
  cur=${MEM_CUR[$c]:-}
  printf '%b ' "$(state_icon "$st")"
  if [ "$st" = n/a ]; then
    printf '%b%-5s%b ' "$GREY" "n/a" "$RESET"
  else
    printf '%b:%-5s%b ' "$GREY" "${port:--}" "$RESET"
  fi
  if [[ "$cur" =~ ^[0-9]+$ ]]; then
    pct=$((cur * 100 / $(to_bytes "$(comp_max "$c")") ))
    bar "$pct" "$bw"
    mem_s=$(human "$cur")
    cpu_s=${CPU_PCT[$c]:-"·"}
    printf ' %6s %4s' "$mem_s" "$cpu_s"
  elif is_external "$c"; then
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
  local W bw frame line key ts pick sc
  local last_us=0
  tput smcup 2>/dev/null; tput civis 2>/dev/null
  trap 'printf "\033[?7h"; tput cnorm 2>/dev/null; tput rmcup 2>/dev/null; trap - INT; return 0' INT
  while true; do
    printf '\033[?7l'   # no auto-wrap: a too-wide line must never break the repaint line count
    W=$(tput cols 2>/dev/null); [ -n "$W" ] || W=100
    bw=$(( (W - 64) / 2 )); [ $bw -lt 6 ] && bw=6; [ $bw -gt 22 ] && bw=22
    sys_gauges
    poll_all

    # ── build the frame off-screen, then paint once (no blinking) ──
    ts=$(date +%H:%M:%S)
    frame=""
    printf -v line '%b── %b%s · live%b ' "$CYAN" "$BOLD" "${PITCREW_PROJECT_NAME:-pitcrew}" "$RESET$CYAN"
    local rule_len=$((W - 12 - ${#PITCREW_PROJECT_NAME} - ${#ts})) r=""
    [ $rule_len -lt 0 ] && rule_len=0
    while [ ${#r} -lt $rule_len ]; do r+="─"; done
    frame+="$line$r $ts ──$RESET"$'\e[K\n\e[K\n'
    printf -v line '   %bCPU%b ' "$BOLD" "$RESET"
    frame+="$line$(bar "${SYS_CPU_PCT:-0}" 20)"
    printf -v line ' %3s%%      %bRAM%b ' "${SYS_CPU_PCT:-0}" "$BOLD" "$RESET"
    if [ -n "$SYS_MEM_TOTAL_KB" ]; then
      local m_pct=$((SYS_MEM_USED_KB * 100 / SYS_MEM_TOTAL_KB))
      frame+="$line$(bar "$m_pct" 20)"
      printf -v line ' %s / %s' "$(human $((SYS_MEM_USED_KB * 1024)))" "$(human $((SYS_MEM_TOTAL_KB * 1024)))"
    else
      frame+="$line${GREY}unavailable on this OS${RESET}"; line=""
    fi
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
    printf -v line "${GREY}── services%b" "$(summary_line)"
    frame+="${line}${RESET}"$'\e[K\n'
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
    printf -v line ' %bq%b quit  %bl%b logs  %bs%b stop  %bm%b menu  %b· refresh 2s%b' \
      "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$BOLD$MAGENTA" "$RESET" "$DIM$GREY" "$RESET"
    frame+="$line"$'\e[K'

    printf '\033[H%b\033[0J' "$frame"

    key=""
    read -rsn1 -t 2 key 2>/dev/null || true
    case "$key" in
      q|Q) break ;;
      l|L) log_view ;;   # same alt screen — switch logs in place, q comes back here
      s|S) if command -v fzf >/dev/null; then
             printf '\033[?7h'; tput rmcup 2>/dev/null; tput cnorm 2>/dev/null
             pick=$(running_comps | fzf --multi --height=40% --border=rounded \
               --prompt='stop ❯ ' --pointer='▶' --marker='✔ ' \
               --header='TAB = select several · Enter = stop · Esc = cancel') || pick=""
             while IFS= read -r sc; do [ -n "$sc" ] && stop_comp "$sc"; done <<< "$pick"
             tput smcup 2>/dev/null; tput civis 2>/dev/null
           fi ;;
      m|M) if command -v fzf >/dev/null; then
             printf '\033[?7h'; tput rmcup 2>/dev/null; tput cnorm 2>/dev/null
             menu
             tput smcup 2>/dev/null; tput civis 2>/dev/null
           fi ;;
    esac
  done
  trap - INT
  printf '\033[?7h'; tput cnorm 2>/dev/null; tput rmcup 2>/dev/null
}
