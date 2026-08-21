#!/usr/bin/env bash
# lib/17-limits.sh — per-component RAM caps.
#
# `PITCREW_BE_MAX` / `PITCREW_FE_MAX` are two numbers for a whole stack, which
# is the wrong shape once the stack is not uniform: a Spring backend wants 8G
# and a cron worker next to it wants 512M, and giving both 8G means the caps
# never bite and the OOM killer picks the victim instead.
#
# Resolution, highest first:
#
#   1. this file's per-component override   ~/.config/pitcrew/<session>/limits
#   2. a per-app cap in the project config  pitcrew_app api --be-max 2G
#   3. the role default                     PITCREW_BE_MAX / PITCREW_FE_MAX
#
# Why (1) is a machine-local file rather than more config: a cap is a property
# of the MACHINE, not the project. 8G is generous on a 64G workstation and
# suicidal on a 16G laptop, and the two developers sharing that repo should not
# be editing each other's numbers in git. (2) still exists for a project that
# genuinely wants to state "this one is small" for everybody.

LIMITS_FILE=""
declare -gA COMP_MAX_OVERRIDE=()

limits_file_for() { # → LIMITS_FILE, once SESSION is known
  LIMITS_FILE="${PITCREW_HOME:-$HOME/.config/pitcrew}/$SESSION/limits"
}

# A size is <integer><M|G>, or a plain byte count. Deliberately strict: this is
# handed to systemd's MemoryMax, and "8gb" or "8 G" there fails the unit at
# start time with an error nobody connects back to a typo in a limits file.
limits_valid() { # $1 → 0 if usable as a cap
  case "$1" in
    ''|*[!0-9MmGg]*) return 1 ;;
    *[MmGg])  case "${1%[MmGg]}" in ''|*[!0-9]*) return 1 ;; esac; [ "${1%[MmGg]}" -gt 0 ] ;;
    *)        [ "$1" -gt 0 ] ;;
  esac
}

limits_load() { # populate COMP_MAX_OVERRIDE from the file
  COMP_MAX_OVERRIDE=()
  limits_file_for
  [ -r "$LIMITS_FILE" ] || return 0
  local key val
  while IFS='=' read -r key val; do
    case "$key" in ''|\#*) continue ;; esac
    # A value this version cannot use means a hand edit or a newer format.
    # Ignore that one line rather than refusing to start the whole tool.
    limits_valid "$val" && COMP_MAX_OVERRIDE[$key]=$val
  done < "$LIMITS_FILE"
  return 0
}

limits_save() { # $1 comp, $2 value ("" clears it) → rewrite the file
  limits_file_for
  local c v out="" changed=0
  for c in "${PITCREW_COMPS[@]}"; do
    if [ "$c" = "$1" ]; then v=$2; changed=1; else v=${COMP_MAX_OVERRIDE[$c]:-}; fi
    [ -n "$v" ] && out+="$c=$v"$'\n'
  done
  [ "$changed" = 1 ] || return 1
  mkdir -p "$(dirname "$LIMITS_FILE")" 2>/dev/null || return 1
  if [ -z "$out" ]; then rm -f "$LIMITS_FILE"; else printf '%s' "$out" > "$LIMITS_FILE"; fi
  limits_load
  return 0
}

cap_cache_set() { # $1 comp → refresh the two derived values the frame loop reads
  local cap; cap=$(comp_max "$1")
  COMP_MAX_B[$1]=$(to_bytes "$cap")
  # Precomputed because the dashboard prints it every frame for every component,
  # and a frame is not allowed to fork. "8G" is already the label we want; a cap
  # written as a raw byte count is humanised.
  case "$cap" in
    *[MmGg]) cap=${cap%[mg]}; COMP_MAX_LABEL[$1]=${cap^^} ;;
    *)       human "${COMP_MAX_B[$1]}"; COMP_MAX_LABEL[$1]=${HUMAN/.0/} ;;
  esac
}

# fzf feed: "<comp><TAB><label>", the same contract the action and render menus use.
limit_choices() {
  local c src
  for c in "${PITCREW_COMPS[@]}"; do
    case "$(comp_max_source "$c")" in
      override) src="${C_OK}set here${RESET}" ;;
      app)      src="${C_MUTED}from the config${RESET}" ;;
      *)        src="${C_FAINT}role default${RESET}" ;;
    esac
    printf '%s\t%b%-22s%b %b%6s%b  %b\n' "$c" \
      "$C_ACCENT" "$c" "$RESET" "$C_TEXT" "$(comp_max "$c")" "$RESET" "$src"
  done
}

LIMIT_SIZES=(default 256M 512M 1G 2G 3G 4G 6G 8G 12G 16G)

limit_size_choices() { # $1 comp
  local v cur mark inherited saved
  cur=${COMP_MAX_OVERRIDE[$1]:-}

  # What "default" would fall back to: the layer under the override. Computed
  # once by lifting the override out and putting it straight back, rather than
  # re-deriving the precedence rules here and having two versions of them.
  saved=$cur
  unset "COMP_MAX_OVERRIDE[$1]"
  inherited=$(comp_max "$1")
  [ -n "$saved" ] && COMP_MAX_OVERRIDE[$1]=$saved

  for v in "${LIMIT_SIZES[@]}"; do
    mark="${C_FAINT}○${RESET}"
    if [ "$v" = default ]; then
      [ -z "$cur" ] && mark="${C_OK}●${RESET}"
      printf '%s\t%b  %b%-8s%b %b%s%b\n' "$v" "$mark" "$C_TEXT" "$v" "$RESET" \
        "$C_FAINT" "no override — inherits $inherited" "$RESET"
      continue
    fi
    [ "$v" = "$cur" ] && mark="${C_OK}●${RESET}"
    printf '%s\t%b  %b%-8s%b\n' "$v" "$mark" "$C_TEXT" "$v" "$RESET"
  done
}

comp_max_source() { # $1 comp → MAXSRC: override | app | role
  # Sets a global rather than echoing, so the JSON writer can ask without a
  # subshell — it asks once per component per frame. Same convention as
  # `human` → HUMAN in the render path.
  local app=${1#??-}
  [ -n "${COMP_MAX_OVERRIDE[$1]:-}" ] && { MAXSRC=override; return; }
  if [ "${1:0:2}" = be ]; then [ -n "${PITCREW_BE_MAX_APP[$app]:-}" ] && { MAXSRC=app; return; }
  else [ -n "${PITCREW_FE_MAX_APP[$app]:-}" ] && { MAXSRC=app; return; }; fi
  MAXSRC=role
}

cmd_limit() { # [] | [<comp> <size|default>]
  if [ $# -eq 0 ]; then
    local c src
    say ""
    say "  ${BOLD}RAM caps${RESET}   ${C_MUTED}$LIMITS_FILE${RESET}"
    say ""
    for c in "${PITCREW_COMPS[@]}"; do
      src=$(comp_max_source "$c")
      case "$src" in
        override) src="${C_OK}set here${RESET}" ;;
        app)      src="${C_MUTED}from the config${RESET}" ;;
        *)        src="${C_FAINT}role default${RESET}" ;;
      esac
      printf '    %b%-22s%b %8s   %b\n' "$C_ACCENT" "$c" "$RESET" "$(comp_max "$c")" "$src"
    done
    say ""
    say "  ${C_MUTED}pitcrew limit <component> 2G   ·   pitcrew limit <component> default${RESET}"
    say ""
    return 0
  fi
  [ $# -eq 2 ] || die "usage: pitcrew limit [<component> <size|default>]"

  local comp=$1 value=$2 known=0 c
  for c in "${PITCREW_COMPS[@]}"; do [ "$c" = "$comp" ] && known=1; done
  [ "$known" = 1 ] || die "no component '$comp' — see: pitcrew limit"

  if [ "$value" = default ] || [ "$value" = clear ]; then
    limits_save "$comp" "" || die "could not write $LIMITS_FILE"
    ok "$comp back to $(comp_max "$comp") ${C_MUTED}($(comp_max_source "$comp"))${RESET}"
    return 0
  fi
  limits_valid "$value" || die "'$value' is not a size — use 512M, 2G, or a byte count"
  limits_save "$comp" "$value" || die "could not write $LIMITS_FILE"
  cap_cache_set "$comp"                   # keep the meters honest without a reload
  ok "$comp capped at $value"
  # The cap is applied when a component STARTS, so changing it under a running
  # one changes nothing until it is restarted. Saying so beats being asked why.
  case "$(comp_state "$comp")" in
    up|starting) say "    ${C_MUTED}restart it for the new cap to apply: pitcrew restart ${comp#??-}${RESET}" ;;
  esac
  return 0
}
