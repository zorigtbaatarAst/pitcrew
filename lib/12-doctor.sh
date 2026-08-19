#!/usr/bin/env bash
# lib/12-doctor.sh — check pitcrew's own runtime deps, then hand off to the
# project's own checks (JDK version, node_modules, replica sets, ...) via an
# optional pitcrew_doctor_extra() function defined in the config.

cmd_doctor() {
  banner
  say "${BOLD}pitcrew runtime${RESET} ${GREY}(${PITCREW_OS})${RESET}"
  command -v bash >/dev/null && ok "bash   $BASH_VERSION"
  command -v lsof >/dev/null && ok "lsof   present ${GREY}(port → pid lookups)${RESET}" \
    || warn "lsof missing — falls back to ss (Linux) or port checks will be limited"
  command -v fzf  >/dev/null && ok "fzf    $(fzf --version | awk '{print $1}')" || warn "fzf missing — menus fall back to plain prompts"
  if [ "$PITCREW_COLLECTOR" = proc ]; then
    ok "meters /proc ${GREY}(fork-free collector · refresh ${PITCREW_REFRESH}s · graph ${PITCREW_GRAPH})${RESET}"
  else
    warn "meters ps fallback — no /proc, so each frame costs a ps + a port listing (refresh ${PITCREW_REFRESH}s)"
  fi
  if [ "${PITCREW_RESTART:-0}" = 1 ]; then
    ok "restart auto-restart on ${GREY}(backoff ${PITCREW_RESTART_BACKOFF}s, up to ${PITCREW_RESTART_MAX} tries — only while the dashboard is open)${RESET}"
  else
    ok "restart off ${GREY}(set PITCREW_RESTART=1 to auto-restart crashed components)${RESET}"
  fi
  if [ "$HAS_SYSTEMD" = 1 ]; then
    ok "systemd --user available — RAM caps (MemoryMax) are enforced"
  else
    warn "no systemd --user — components run uncapped (RAM meters still work via ps)"
  fi
  if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    if command -v docker >/dev/null; then
      docker info >/dev/null 2>&1 && ok "docker daemon running" || bad "docker daemon NOT running"
    else bad "docker not found (config declares PITCREW_DEPS)"; fi
  fi
  echo
  if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    say "${BOLD}deps${RESET}"
    local dep
    for dep in "${PITCREW_DEPS[@]}"; do
      container_running "$dep" && ok "$dep running" || bad "$dep not running"
    done
    echo
  fi
  if declare -F pitcrew_doctor_extra >/dev/null; then
    say "${BOLD}project checks${RESET}"
    pitcrew_doctor_extra
    echo
  fi
  # ── does this project fit on this machine, and does it clash with another? ──
  say "${BOLD}capacity${RESET}"
  ram_preflight "${PITCREW_COMPS[@]}"
  if [ -n "$RAM_WARN" ]; then warn "$RAM_WARN"
  else ok "RAM caps for all ${#PITCREW_COMPS[@]} components fit in this machine"; fi

  local me="" conflicts=0 line
  case "$PITCREW_CFG" in
    "$PROJECTS_DIR"/*) me=${PITCREW_CFG##*/}; me=${me%.sh} ;;
  esac
  if [ -n "$me" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      conflicts=$((conflicts + 1))
      set -- $line
      [ $conflicts -eq 1 ] && bad "ports also claimed by another registered project:"
      say "      ${C_WARN}$1${RESET}  ${C_MUTED}this project's${RESET} $2  ${C_MUTED}vs${RESET} $3/$4"
    done < <(port_conflicts "$me")
    [ $conflicts -eq 0 ] && ok "no port clashes with other registered projects"
    [ $conflicts -gt 0 ] && say "      ${C_MUTED}run both at once and each reports the other's services as its own${RESET}"
  fi
  echo

  local avail=""
  if [ "$PITCREW_OS" = linux ]; then
    avail=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
  fi
  [ -n "$avail" ] && say "  ${GREY}∙${RESET} ${avail}G RAM available · caps: backend $PITCREW_BE_MAX · frontend $PITCREW_FE_MAX"
  echo
}
