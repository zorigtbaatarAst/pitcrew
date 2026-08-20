#!/usr/bin/env bash
# lib/12-doctor.sh — check pitcrew's own runtime deps, then hand off to the
# project's own checks (JDK version, node_modules, replica sets, ...) via an
# optional pitcrew_doctor_extra() function defined in the config.

cmd_doctor() {
  banner
  say "${BOLD}pitcrew runtime${RESET} ${GREY}(${PITCREW_OS})${RESET}"
  ok "version ${PITCREW_VERSION:-unknown}"
  command -v bash >/dev/null && ok "bash   $BASH_VERSION"
  command -v lsof >/dev/null && ok "lsof   present ${GREY}(port → pid lookups)${RESET}" \
    || warn "lsof missing — falls back to ss (Linux) or port checks will be limited"
  command -v fzf  >/dev/null && ok "fzf    $(fzf --version | awk '{print $1}')" || warn "fzf missing — menus fall back to plain prompts"
  if [ "$PITCREW_COLLECTOR" = proc ]; then
    ok "meters /proc ${GREY}(fork-free collector · refresh ${PITCREW_REFRESH}s · graph ${PITCREW_GRAPH})${RESET}"
  elif [ "$PITCREW_OS" = macos ] || [ "$PITCREW_OS" = bsd ]; then
    ok "meters ps ${GREY}(the portable collector — one ps + one port listing per frame · refresh ${PITCREW_REFRESH}s · graph ${PITCREW_GRAPH})${RESET}"
  elif [ "${PITCREW_FORCE_COLLECTOR:-}" = ps ]; then
    # Say which it is. "/proc is unreadable" would be a plain lie here, and a
    # lie in doctor is worse than no line at all.
    ok "meters ps ${GREY}(forced by PITCREW_FORCE_COLLECTOR — this is the macOS path, running on ${PITCREW_OS})${RESET}"
  else
    warn "meters ps fallback — /proc is unreadable here, so each frame costs a ps + a port listing (refresh ${PITCREW_REFRESH}s)"
  fi
  if [ "${PITCREW_RESTART:-0}" = 1 ]; then
    ok "restart auto-restart on ${GREY}(backoff ${PITCREW_RESTART_BACKOFF}s, up to ${PITCREW_RESTART_MAX} tries — only while the dashboard is open)${RESET}"
  else
    ok "restart off ${GREY}(set PITCREW_RESTART=1 to auto-restart crashed components)${RESET}"
  fi
  # A cap you cannot enforce is worth saying out loud — the meters look
  # identical either way, so nothing else on screen distinguishes the two.
  if [ "$HAS_SYSTEMD" = 1 ]; then
    ok "caps   systemd --user available — MemoryMax is enforced per component"
  elif [ "$PITCREW_OS" = macos ]; then
    warn "caps   not enforceable on macOS — there is no cgroup equivalent, so PITCREW_BE_MAX/FE_MAX are budgets the meters measure against, not limits the kernel applies"
  else
    warn "caps   no systemd --user — components run uncapped (the RAM meters still work)"
  fi
  if [ "$PITCREW_OS" = windows ]; then
    bad "windows  pitcrew is not supported natively here — run it inside WSL2, where it gets a normal Linux userland (and real RAM caps)"
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

  # sys_gauges knows how to ask each OS — /proc/meminfo here, vm_stat there.
  # This line used to be Linux-only, which left the one number that decides
  # whether the stack fits blank on exactly the platform with no RAM caps.
  sys_gauges
  local avail=""
  if [ "${SYS_MEM_TOTAL_KB:-0}" -gt 0 ] && [ -n "${SYS_MEM_USED_KB:-}" ]; then
    avail=$(( (SYS_MEM_TOTAL_KB - SYS_MEM_USED_KB) * 10 / 1048576 ))   # tenths of a GiB
    [ "$avail" -lt 10 ] && avail="0$avail"                             # 7 → 0.7, not .7
    avail="${avail%?}.${avail: -1}"
  fi
  [ -n "$avail" ] && say "  ${GREY}∙${RESET} ${avail}G RAM available · caps: backend $PITCREW_BE_MAX · frontend $PITCREW_FE_MAX"
  echo
}

# `doctor --json` — the same facts, for a machine.
#
# Deliberately NOT a reformat of the prose above: that output is arranged for a
# human reading it once, and scraping it would break the first time a glyph
# changed. This emits the checks themselves, so CI can gate on `capsFit` or
# `portClashes` without knowing what the pretty version looks like.
cmd_doctor_json() {
  snapshot
  local dep deps_json="" first=1 clashes
  for dep in "${PITCREW_DEPS[@]:-}"; do
    [ -n "$dep" ] || continue
    [ $first = 1 ] || deps_json+=","
    first=0
    deps_json+="$(printf '{"name":%s,"running":%s}' \
      "$(_json_str "$dep")" "$(container_running "$dep" && echo true || echo false)")"
  done

  ram_preflight "${PITCREW_COMPS[@]}"

  # port_conflicts only means anything for a project in the registry — an
  # in-repo config has no name to compare the others against.
  local me=""
  case "$PITCREW_CFG" in
    "$PROJECTS_DIR"/*) me=${PITCREW_CFG##*/}; me=${me%.sh} ;;
  esac
  clashes=0
  [ -n "$me" ] && clashes=$(port_conflicts "$me" 2>/dev/null | grep -c . || true)

  printf '{'
  printf '"schema":%s,' "$PITCREW_JSON_SCHEMA"
  printf '"version":%s,' "$(_json_str "${PITCREW_VERSION:-unknown}")"
  printf '"os":%s,' "$(_json_str "$PITCREW_OS")"
  printf '"bash":%s,' "$(_json_str "$BASH_VERSION")"
  printf '"collector":%s,' "$(_json_str "$PITCREW_COLLECTOR")"
  printf '"capsEnforced":%s,' "$(_caps_enforced && echo true || echo false)"
  printf '"capsFit":%s,' "$([ -z "$RAM_WARN" ] && echo true || echo false)"
  printf '"capsWarning":%s,' "$(_json_str "${RAM_WARN:-}")"
  printf '"portClashes":%s,' "$(_json_num "${clashes:-0}")"
  printf '"tools":{"lsof":%s,"fzf":%s,"docker":%s},' \
    "$(command -v lsof  >/dev/null 2>&1 && echo true || echo false)" \
    "$(command -v fzf   >/dev/null 2>&1 && echo true || echo false)" \
    "$(command -v docker >/dev/null 2>&1 && echo true || echo false)"
  printf '"deps":[%s]' "$deps_json"
  printf '}\n'
  # Exit non-zero when something a CI job should care about is wrong, so
  # `pitcrew doctor --json` can BE the gate rather than needing one wrapped
  # around it.
  [ -z "$RAM_WARN" ] && [ "${clashes:-0}" -eq 0 ]
}

_caps_enforced() {
  case "$PITCREW_OS" in
    macos|bsd) return 1 ;;
    *) systemctl --user is-system-running >/dev/null 2>&1 ;;
  esac
}
