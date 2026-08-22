#!/usr/bin/env bash
# lib/06-targets.sh — turn CLI words ("all", "backends", "sales", "@profile",
# "be-sales") into a concrete, deduped list of components to act on.

expand_profiles() {
  local out=() w f l
  for w in "$@"; do
    if [[ $w == @* ]]; then
      f="$PROFILE_DIR/${w#@}"
      [ -f "$f" ] || die "no profile '$w' — see: pitcrew profile list"
      while IFS= read -r l; do [ -n "$l" ] && out+=("$l"); done < "$f"
    else
      out+=("$w")
    fi
  done
  # `printf '%s\n' "${arr[@]}"` on an EMPTY array still prints one blank line,
  # which mapfile downstream turns into a phantom empty element. Guard it.
  [ ${#out[@]} -eq 0 ] && return 0
  printf '%s\n' "${out[@]}"
}

# Every component a GROUP target covers: disabled ones are skipped, because
# `enabled: false` is exactly the statement "not part of the group by default".
# Naming a component or its app directly still reaches it — that is a
# deliberate instruction, and a switch you cannot override is a trap.
_group_components() { # $1 = "" for all, or a role, or an app
  local c
  for c in "${PITCREW_COMPS[@]}"; do
    comp_disabled "$c" && continue
    case "${1:-}" in
      '')     printf '%s\n' "$c" ;;
      role:*) [ "${c%%-*}" = "${1#role:}" ] && printf '%s\n' "$c" ;;
      app:*)  [ "${c#*-}"  = "${1#app:}"  ] && printf '%s\n' "$c" ;;
    esac
  done
  return 0
}

resolve_targets() {
  local out=() w app
  for w in "$@"; do
    case "$w" in
      all)       while IFS= read -r app; do out+=("$app"); done < <(_group_components) ;;
      backends)  while IFS= read -r app; do out+=("$app"); done < <(_group_components role:be) ;;
      frontends) while IFS= read -r app; do out+=("$app"); done < <(_group_components role:fe) ;;
      # Docker deps are not components, so there is deliberately nothing to
      # emit here — but the word is meaningful and callers must act on it.
      # cmd_start already special-cases it; cmd_stop does too. Silently
      # dropping it is what made `pitcrew stop deps` a no-op that exited 0.
      deps)      ;;
      *)
        # A component id, named outright — including a disabled one.
        if [[ " ${PITCREW_COMPS[*]} " == *" $w "* ]]; then out+=("$w")
        # An app: every role in the group, minus the ones switched off.
        elif [[ " ${PITCREW_APPS[*]} " == *" $w "* ]]; then
          while IFS= read -r app; do out+=("$app"); done < <(_group_components "app:$w")
        # A role, across every app that has one — `pitcrew restart worker`.
        # Apps win a name clash, and config_validate warns when there is one.
        elif [[ " ${PITCREW_ROLES[*]} " == *" $w "* ]]; then
          while IFS= read -r app; do out+=("$app"); done < <(_group_components "role:$w")
        else die "unknown target '$w' (apps: ${PITCREW_APPS[*]} · roles: ${PITCREW_ROLES[*]})"; fi ;;
    esac
  done
  [ ${#out[@]} -eq 0 ] && return 0      # see the note in expand_profiles
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}
