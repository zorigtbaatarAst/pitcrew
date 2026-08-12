#!/usr/bin/env bash
# lib/11-doctor.sh — check pitcrew's own runtime deps, then hand off to the
# project's own checks (JDK version, node_modules, replica sets, ...) via an
# optional pitcrew_doctor_extra() function defined in the config.

cmd_doctor() {
  banner
  say "${BOLD}pitcrew runtime${RESET}"
  command -v tmux >/dev/null   && ok "tmux   $(tmux -V | awk '{print $2}')" || bad "tmux not found — required"
  command -v fzf  >/dev/null   && ok "fzf    $(fzf --version | awk '{print $1}')" || warn "fzf missing — menus fall back to plain prompts"
  if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    if command -v docker >/dev/null; then
      docker info >/dev/null 2>&1 && ok "docker daemon running" || bad "docker daemon NOT running"
    else bad "docker not found (config declares PITCREW_DEPS)"; fi
  fi
  systemctl --user status >/dev/null 2>&1 && ok "systemd --user available (used for RAM caps)" \
    || warn "systemd --user not available — components will still run, without RAM caps/meters"
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
  local avail
  avail=$(awk '/MemAvailable/{printf "%.1f", $2/1048576}' /proc/meminfo)
  say "  ${GREY}∙${RESET} ${avail}G RAM available · caps: backend $PITCREW_BE_MAX · frontend $PITCREW_FE_MAX"
  echo
}
