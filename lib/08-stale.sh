#!/usr/bin/env bash
# lib/08-stale.sh — flag (and optionally restart) running components whose
# source changed after they started. A component opts into this by setting
# PITCREW_WATCH_DIR[app-role] (or just PITCREW_WATCH_DIR[app] for both roles)
# in the config — without it, staleness can't be determined and it's skipped.

watch_dirs_for() { # $1 comp → newline-separated dirs to check, or nothing
  local c=$1
  local app=${c#??-}
  local d="${PITCREW_WATCH_DIR[$c]:-${PITCREW_WATCH_DIR[$app]:-}}"
  [ -n "$d" ] && printf '%s\n' $d
}

stale_comps() {
  local c app ts epoch dirs
  while IFS= read -r c; do
    ts=$(systemctl --user show "$SESSION-$c.scope" -p ActiveEnterTimestamp --value 2>/dev/null)
    [ -n "$ts" ] && [ "$ts" != "n/a" ] || continue          # external / no scope → skip
    epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
    mapfile -t dirs < <(watch_dirs_for "$c")
    [ ${#dirs[@]} -eq 0 ] && continue                        # no watch dir configured → skip
    if find "${dirs[@]}" -type f -newermt "@$epoch" -print -quit 2>/dev/null | grep -q .; then
      echo "$c"
    fi
  done < <(running_comps)
}

cmd_stale() {
  local do_restart=0
  [ "${1:-}" = "--restart" ] && do_restart=1
  say "${GREY}checking running services against source changes…${RESET}"
  local stale; mapfile -t stale < <(stale_comps)
  if [ ${#stale[@]} -eq 0 ]; then ok "everything is fresh — no restarts needed"; return; fi
  local c
  for c in "${stale[@]}"; do warn "$c — code changed since it started"; done
  if [ $do_restart -eq 1 ]; then
    for c in "${stale[@]}"; do stop_comp "$c"; done
    for c in "${stale[@]}"; do start_comp "$c"; done
    wait_dashboard "${stale[@]}"
  else
    say "  ${GREY}restart them with:${RESET} pitcrew stale --restart"
  fi
}
