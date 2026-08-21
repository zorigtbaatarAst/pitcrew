#!/usr/bin/env bash
# lib/20-plugins.sh — loading checks that live outside this repository.
#
# This is not a plugin framework and should not become one. It is the smallest
# thing that lets `lib/19-diag.sh`'s registry be reachable from a file pitcrew
# does not ship: a directory of shell files, sourced after the project config,
# whose only documented job is to call `diag_register`.
#
# ── why user-level only ────────────────────────────────────────────────────
#
# Plugins load from ~/.config/pitcrew/plugins and NOT from anything inside a
# checkout. That is a deliberate refusal, and it is the one interesting
# decision in this file.
#
# A `pitcrew.config.sh` is shell, so a repository that ships one already asks
# you to run its code — but that is a visible, single, well-known file. YAML
# configs exist precisely so a project can be described by DATA, and a
# `.pitcrew/plugins/` directory that got sourced automatically would silently
# undo that: `pitcrew status` in a freshly cloned repository would execute
# whatever the repository felt like. Nothing about "look at the dashboard"
# should mean "run this stranger's shell".
#
# So: your machine, your files, your plugins. A project that wants to ship a
# check can put it in its own pitcrew.config.sh, where the exposure is the one
# you already accepted.
PITCREW_PLUGIN_DIR="${PITCREW_PLUGIN_DIR:-$PITCREW_HOME/plugins}"
PITCREW_PLUGINS=()

# NOTE: this only COLLECTS the paths. Sourcing happens at bin/pitcrew's top
# level, for the same reason the config does — a bare `declare -A` in a sourced
# file is scoped to the function that sourced it and silently discarded, and a
# plugin holding a lookup table is an obvious thing for someone to write.
plugin_files() { # → the plugins to load, in name order
  [ -d "$PITCREW_PLUGIN_DIR" ] || return 0
  local f
  for f in "$PITCREW_PLUGIN_DIR"/*.sh; do
    [ -r "$f" ] || continue
    printf '%s\n' "$f"
  done
}

cmd_plugins() {
  local files n f name
  mapfile -t files < <(plugin_files)
  n=${#files[@]}
  say ""
  say "  ${C_MUTED}${PITCREW_PLUGIN_DIR}${RESET}"
  say ""
  if [ "$n" -eq 0 ]; then
    say "  ${C_MUTED}no plugins${RESET}"
    say ""
    say "  ${C_MUTED}a plugin is a shell file that registers a diagnostic check:${RESET}"
    say "    ${C_SUBTLE}diag_register my_check${RESET}          ${C_FAINT}# runs every dashboard frame${RESET}"
    say "    ${C_SUBTLE}diag_register my_check slow${RESET}     ${C_FAINT}# may fork; only on \`pitcrew diagnose\`${RESET}"
    say ""
    say "  ${C_MUTED}there is a worked example in${RESET} ${BOLD}examples/plugins/jvm.sh${RESET}"
    say ""
    return 0
  fi
  # Which checks each file registered, so a plugin that loaded but registered
  # nothing is visible as exactly that rather than as a mystery.
  for f in "${files[@]}"; do
    name=${f##*/}
    printf '  %b●%b %b%-24s%b' "$C_OK" "$RESET" "$BOLD" "$name" "$RESET"
    local c listed=""
    for c in "${DIAG_CHECKS[@]}"; do
      case "${PLUGIN_OF[$c]:-}" in "$name") listed+="${listed:+, }$c${DIAG_CHECK_SLOW[$c]:+ (slow)}" ;; esac
    done
    if [ -n "$listed" ]; then printf ' %b%s%b\n' "$C_MUTED" "$listed" "$RESET"
    else printf ' %b%s%b\n' "$C_WARN" "registered no checks" "$RESET"; fi
  done
  say ""
  return 0
}

# Which file registered which check. Filled by bin/pitcrew as it sources them,
# so `pitcrew plugins` can attribute a check to its plugin — the first question
# anyone asks when a finding they do not recognise shows up.
declare -gA PLUGIN_OF=()
plugin_attribute() { # $1 plugin file name — everything registered since the last call is its
  local c
  for c in "${DIAG_CHECKS[@]}"; do
    [ -n "${PLUGIN_OF[$c]:-}" ] || PLUGIN_OF[$c]=$1
  done
  return 0
}
