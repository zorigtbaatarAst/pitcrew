#!/usr/bin/env bash
# lib/10-profiles.sh — named, saved sets of targets (e.g. "sales backoffice")
# stored per-project under ~/.config/pitcrew/<project>/profiles.

cmd_profile() {
  case "${1:-list}" in
    save)
      shift
      local name=${1:-}; shift || true
      [ -n "$name" ] && [ $# -ge 1 ] || die "usage: pitcrew profile save <name> <app|be-app|fe-app ...>"
      resolve_targets "$@" >/dev/null || exit 1   # validate targets
      mkdir -p "$PROFILE_DIR"
      printf '%s\n' "$@" > "$PROFILE_DIR/$name"
      ok "saved profile ${BOLD}@$name${RESET} = $*" ;;
    list)
      if [ -d "$PROFILE_DIR" ] && [ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ]; then
        local f
        for f in "$PROFILE_DIR"/*; do
          say "  ${CYAN}@$(basename "$f")${RESET}  ${GREY}$(tr '\n' ' ' < "$f")${RESET}"
        done
      else
        say "  ${GREY}no profiles yet — create one: pitcrew profile save <name> <app...>${RESET}"
      fi ;;
    rm)
      [ -n "${2:-}" ] || die "usage: pitcrew profile rm <name>"
      rm -f "$PROFILE_DIR/$2" && ok "removed @$2" ;;
    *) die "usage: pitcrew profile save|list|rm" ;;
  esac
}

pick_profile() {
  [ -d "$PROFILE_DIR" ] && [ -n "$(ls -A "$PROFILE_DIR" 2>/dev/null)" ] || return 1
  ls "$PROFILE_DIR" | pick --height 30% --prompt 'profile ❯ ' \
    --preview "cat $PROFILE_DIR/{}" --preview-window 'right:40%' \
    --header 'pick a profile · Esc=cancel'
}
