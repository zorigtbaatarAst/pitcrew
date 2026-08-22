#!/usr/bin/env bash
# lib/10-profiles.sh — named, saved sets of targets (e.g. "sales backoffice")
# stored per-project under ~/.config/pitcrew/<project>/profiles.
#
# A profile is a file of TARGET WORDS, not of components: "sales" stays
# "sales", so a profile keeps meaning what you meant when that app grows a
# worker. The flip side is that a profile can rot — rename an app and the file
# still names the old one, and `pitcrew start @that` dies on a target that no
# longer exists. So everything here reports what a profile resolves to TODAY,
# missing entries included, rather than echoing the file back.

# Every profile name, sorted. One place that knows an empty directory is not an
# error, instead of three callers each running their own `ls`.
profile_names() {
  profile_names_arr
  [ ${#PROFILE_NAMES[@]} -eq 0 ] && return 0
  printf '%s\n' "${PROFILE_NAMES[@]}"
  return 0
}

# The same list, into an array, with no fork anywhere: `pitcrew json --watch`
# reports every profile on every frame, and `< <(profile_names)` is a process
# substitution — one fork per frame before a single profile has been read.
profile_names_arr() {
  PROFILE_NAMES=()
  [ -d "$PROFILE_DIR" ] || return 0
  local f
  for f in "$PROFILE_DIR"/*; do
    [ -f "$f" ] || continue
    PROFILE_NAMES+=("${f##*/}")
  done
  return 0
}

profile_has_any() { [ -n "$(profile_names)" ]; }

# The words a profile holds, one per line, as written.
profile_targets() { # $1 name
  [ -f "$PROFILE_DIR/$1" ] || return 1
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done < "$PROFILE_DIR/$1"
  return 0
}

# What a profile means right now.
#   PROFILE_COMPS    the components it resolves to, deduped, in order
#   PROFILE_MISSING  target words that no longer name anything
#
# Fork-free on purpose, and it never dies. `pitcrew json --watch` reports every
# profile on every frame, and resolve_targets ends in an awk — a frame may not
# fork per profile. resolve_targets also die()s on an unknown target, which is
# right for a command somebody typed and quite wrong here: a stale profile is
# something to REPORT, not something that takes the dashboard down.
profile_resolve() { # $1 name
  PROFILE_COMPS=(); PROFILE_MISSING=()
  local w c
  local -a words=()
  # `mapfile < file` is a redirect, not a subshell — `< <(profile_targets …)`
  # would have been a fork per profile per frame.
  [ -f "$PROFILE_DIR/$1" ] && mapfile -t words < "$PROFILE_DIR/$1"
  for w in "${words[@]}"; do
    [ -n "$w" ] || continue
    case "$w" in
      all)       for c in "${PITCREW_COMPS[@]}"; do _profile_add "$c"; done; continue ;;
      backends)  for c in "${PITCREW_COMPS[@]}"; do [ "${c%%-*}" = be ] && _profile_add "$c"; done; continue ;;
      frontends) for c in "${PITCREW_COMPS[@]}"; do [ "${c%%-*}" = fe ] && _profile_add "$c"; done; continue ;;
      deps)      continue ;;                     # meaningful, but not a component
    esac
    if [[ " ${PITCREW_COMPS[*]} " == *" $w "* ]]; then
      _profile_add "$w"
    elif [[ " ${PITCREW_APPS[*]} " == *" $w "* ]]; then
      for c in "${PITCREW_COMPS[@]}"; do [ "${c#*-}" = "$w" ] && _profile_add "$c"; done
    elif [[ " ${PITCREW_ROLES[*]} " == *" $w "* ]]; then
      for c in "${PITCREW_COMPS[@]}"; do [ "${c%%-*}" = "$w" ] && _profile_add "$c"; done
    else
      PROFILE_MISSING+=("$w")
    fi
  done
  return 0
}

_profile_add() { # $1 comp — append once
  local c
  for c in "${PROFILE_COMPS[@]}"; do [ "$c" = "$1" ] && return 0; done
  PROFILE_COMPS+=("$1")
  return 0
}

# The numbers worth knowing before you press start. Sets globals rather than
# echoing — the same convention comp_max_source and human use — so the JSON
# writer can ask once per profile per frame without a subshell.
#
#   PSTAT_TOTAL     components it resolves to
#   PSTAT_UP        how many are up or external right now
#   PSTAT_STARTING  how many are on their way
#   PSTAT_RSS       bytes those are using
#   PSTAT_CAP       bytes it commits if every component reaches its cap
#   PSTAT_PORTS     the ports it claims, space separated
#   PSTAT_TARGETS   the words as saved
#   PSTAT_MISSING   target words that no longer name anything
profile_stat() { # $1 name — call snapshot() first for the live half
  local -a words=()
  [ -f "$PROFILE_DIR/$1" ] && mapfile -t words < "$PROFILE_DIR/$1"
  profile_resolve "$1"
  PSTAT_TOTAL=${#PROFILE_COMPS[@]}
  PSTAT_UP=0; PSTAT_STARTING=0; PSTAT_RSS=0; PSTAT_CAP=0; PSTAT_PORTS=""
  PSTAT_MISSING="${PROFILE_MISSING[*]}"
  PSTAT_TARGETS="${words[*]:-}"
  local c st port
  for c in "${PROFILE_COMPS[@]}"; do
    st=${SNAP_STATE[$c]:-n/a}
    case "$st" in
      up|external) PSTAT_UP=$(( PSTAT_UP + 1 )) ;;
      starting)    PSTAT_STARTING=$(( PSTAT_STARTING + 1 )) ;;
    esac
    PSTAT_RSS=$(( PSTAT_RSS + ${SNAP_RSS[$c]:-0} ))
    PSTAT_CAP=$(( PSTAT_CAP + ${COMP_MAX_B[$c]:-0} ))
    port=${PITCREW_PORT[$c]:-}
    [ -n "$port" ] && PSTAT_PORTS+="${PSTAT_PORTS:+ }$port"
  done
  return 0
}

cmd_profile() {
  case "${1:-list}" in
    save)
      shift
      local name=${1:-}; shift || true
      [ -n "$name" ] && [ $# -ge 1 ] || die "usage: pitcrew profile save <name> <app|be-app|fe-app ...>"
      # The name becomes a filename. A slash in it would write somewhere else
      # entirely, which is not a thing a save command should be able to do.
      case "$name" in
        */*|.|..|-*) die "'$name' cannot be a profile name — it becomes a filename" ;;
      esac
      resolve_targets "$@" >/dev/null || exit 1   # validate targets
      mkdir -p "$PROFILE_DIR"
      printf '%s\n' "$@" > "$PROFILE_DIR/$name"
      ok "saved profile ${BOLD}@$name${RESET} = $*" ;;
    list)
      if ! profile_has_any; then
        say "  ${C_MUTED}no profiles yet — start what you want, then: pitcrew profile save <name> <app...>${RESET}"
        return 0
      fi
      snapshot
      local n
      say ""
      while IFS= read -r n; do _profile_line "$n"; done < <(profile_names)
      say ""
      say "  ${C_FAINT}pitcrew start @<name>   ·   pitcrew profile show <name>${RESET}"
      say "" ;;
    show)
      [ -n "${2:-}" ] || die "usage: pitcrew profile show <name>"
      [ -f "$PROFILE_DIR/$2" ] || die "no profile '@$2' — see: pitcrew profile list"
      snapshot
      _profile_detail "$2" ;;
    rm)
      [ -n "${2:-}" ] || die "usage: pitcrew profile rm <name>"
      [ -f "$PROFILE_DIR/$2" ] || die "no profile '@$2' — see: pitcrew profile list"
      rm -f "$PROFILE_DIR/$2" && ok "removed @$2" ;;
    *) die "usage: pitcrew profile save|list|show|rm" ;;
  esac
}

# One line per profile: what it is, and what it is doing right now. `list` used
# to print the file back at you — the words you already typed — which answered
# none of the questions you open it to ask.
_profile_line() { # $1 name
  profile_stat "$1"
  local state mem ports=""
  if   [ "$PSTAT_TOTAL" = 0 ];           then state="${C_CRIT}resolves to nothing${RESET}"
  elif [ "$PSTAT_UP" = "$PSTAT_TOTAL" ]; then state="${C_OK}${PSTAT_UP}/${PSTAT_TOTAL} up${RESET}"
  elif [ "$PSTAT_UP" = 0 ];              then state="${C_MUTED}0/${PSTAT_TOTAL} up${RESET}"
  else                                        state="${C_WARN}${PSTAT_UP}/${PSTAT_TOTAL} up${RESET}"
  fi
  [ "$PSTAT_STARTING" -gt 0 ] && state+=" ${C_WARN}+${PSTAT_STARTING}${RESET}"
  mem="${C_FAINT}—${RESET}"
  if [ "$PSTAT_RSS" -gt 0 ]; then human "$PSTAT_RSS"; mem="${C_TEXT}${HUMAN}${RESET}"; fi
  [ -n "$PSTAT_PORTS" ] && ports="${C_MUTED}:${PSTAT_PORTS// /  :}${RESET}"
  printf '  %b@%-14s%b %-30b %-18b %b\n' \
    "$C_ACCENT" "$1" "$RESET" "$state" "$mem" "$ports"
  [ -n "$PSTAT_MISSING" ] && \
    printf '   %b└ %s no longer exists — this profile will not start%b\n' \
      "$C_CRIT" "$PSTAT_MISSING" "$RESET"
  return 0
}

_profile_detail() { # $1 name
  profile_stat "$1"
  local c st rss cap w
  say ""
  say "  ${C_ACCENT}${BOLD}@$1${RESET}"
  say "  ${C_MUTED}$PROFILE_DIR/$1${RESET}"
  say ""
  say "  ${C_MUTED}saved as${RESET}   $(profile_targets "$1" | tr '\n' ' ')"
  human "$PSTAT_RSS"; rss=$HUMAN
  human "$PSTAT_CAP"; cap=$HUMAN
  say "  ${C_MUTED}right now${RESET}  ${PSTAT_UP}/${PSTAT_TOTAL} up · using $rss"
  say "  ${C_MUTED}commits${RESET}    $cap if every component reaches its cap"
  say ""
  for c in "${PROFILE_COMPS[@]}"; do
    st=${SNAP_STATE[$c]:-n/a}
    state_icon "$st"
    printf '    %b %-22s %b%-9s%b %b:%s%b\n' "$R" "$c" "$C_MUTED" "$st" "$RESET" \
      "$C_FAINT" "${PITCREW_PORT[$c]:--}" "$RESET"
  done
  if [ -n "$PSTAT_MISSING" ]; then
    say ""
    for w in $PSTAT_MISSING; do
      bad "'$w' is in this profile and is no longer an app, a role or a component"
    done
    say "  ${C_MUTED}re-save it over the top: pitcrew profile save $1 <targets…>${RESET}"
  fi
  say ""
  return 0
}

pick_profile() {
  profile_has_any || return 1
  # The preview is the profile's own detail view rather than `cat` of the file:
  # what it resolves to and what is up, which is the question you are in this
  # picker to answer.
  profile_names | pick --height 40% --prompt 'profile ❯ ' \
    --preview "'$SELF' profile show {}" --preview-window 'right:55%' \
    --header 'pick a profile · Esc=cancel'
}
