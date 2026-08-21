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

resolve_targets() {
  local out=() w app
  for w in "$@"; do
    case "$w" in
      all)       while IFS= read -r w; do out+=("$w"); done < <(all_components) ;;
      backends)  while IFS= read -r w; do out+=("$w"); done < <(all_components | grep '^be-') ;;
      frontends) while IFS= read -r w; do out+=("$w"); done < <(all_components | grep '^fe-') ;;
      # Docker deps are not components, so there is deliberately nothing to
      # emit here — but the word is meaningful and callers must act on it.
      # cmd_start already special-cases it; cmd_stop does too. Silently
      # dropping it is what made `pitcrew stop deps` a no-op that exited 0.
      deps)      ;;
      be-*|fe-*) out+=("$w") ;;
      *)
        if [[ " ${PITCREW_APPS[*]} " == *" $w "* ]]; then
          while IFS= read -r app; do out+=("$app"); done < <(all_components | grep -- "-$w\$")
        else die "unknown target '$w' (apps: ${PITCREW_APPS[*]})"; fi ;;
    esac
  done
  [ ${#out[@]} -eq 0 ] && return 0      # see the note in expand_profiles
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}
