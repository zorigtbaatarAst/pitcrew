#!/usr/bin/env bash
# lib/14-init.sh — `pitcrew init`: look at a project and write a config that
# actually runs it.
#
# This used to emit `echo '>> set PITCREW_BE_CMD for app' && exit 1` for every
# component, so the first thing a newly-initialised project did was fail. It
# now reads the repository (see lib/14-detect.sh) and writes real commands,
# real ports and real health paths.
#
# The config goes into pitcrew's own directory by default, not into the
# project — see lib/15-registry.sh for why. `--in-project` puts it in the
# checkout instead, for a repo whose team all use pitcrew.
#
# Runs BEFORE config resolution (see bin/pitcrew): the whole point is that
# there is no config yet.

_port_taken() { local p; for p in "${USED_PORTS[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

# Sets NEXT_PORT and RESERVES it. It must not print its answer: called as
# $(_next_port 8080) the reservation happens in a subshell and is thrown away,
# so every component is handed the same "first free" port and the generated
# config collides with itself.
_next_port() { # $1 base → NEXT_PORT
  NEXT_PORT=$1
  while _port_taken "$NEXT_PORT"; do NEXT_PORT=$((NEXT_PORT + 1)); done
  USED_PORTS+=("$NEXT_PORT")
}

cmd_init() { # [--in-project] [--force] [--name <name>] [<dir>]
  local dir="" name="" in_project=0 force=0 redetect=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --in-project) in_project=1; shift ;;
      --detect)     redetect=1; shift ;;
      --force|-f)   force=1; shift ;;
      --name)       [ $# -ge 2 ] || die "--name needs a value"; name=$2; shift 2 ;;
      -*)           die "init: unknown option '$1'" ;;
      *)            dir=$1; shift ;;
    esac
  done
  dir=${dir:-$PWD}
  [ -d "$dir" ] || die "init: no such directory: $dir"
  dir=$(cd "$dir" && pwd)

  # A repo that ships its own config has already answered every question this
  # command exists to guess at — and that file wins at resolution time anyway,
  # so a detected copy in the registry would be dead weight that drifts. Point
  # at it instead. `--detect` overrides, for when you want a fresh look.
  local existing="$dir/pitcrew.config.sh"
  if [ -f "$existing" ] && [ "$in_project" != 1 ] && [ "$redetect" != 1 ]; then
    name=${name:-$(basename "$dir")}
    local lslug; lslug=$(project_slug "$name")
    mkdir -p "$PROJECTS_DIR"
    local ltarget; ltarget=$(project_file "$lslug")
    if [ -e "$ltarget" ] && [ "$force" != 1 ]; then
      die "$ltarget already exists — pass --force to replace it"
    fi
    {
      printf '#!/usr/bin/env bash
'
      printf '# %s — registered by `pitcrew init` on %(%Y-%m-%d)T.
' "$lslug" -1
      printf '#
# This project ships its own pitcrew.config.sh, so this entry just points at
'
      printf '# it. Edit the config in the repository, not here. `pitcrew init --detect`
'
      printf '# replaces this with a freshly detected config instead.

'
      printf 'PITCREW_ROOT=%q
' "$dir"
      printf '# shellcheck source=/dev/null
'
      printf 'source "$PITCREW_ROOT/pitcrew.config.sh"
'
    } > "$ltarget"
    project_set_current "$lslug"
    say ""
    ok "registered ${BOLD}$lslug${RESET} ${C_MUTED}→ its own pitcrew.config.sh${RESET}"
    say "    ${C_MUTED}$existing${RESET}"
    say ""
    return 0
  fi

  say ""
  say "  ${C_MUTED}looking at${RESET} ${BOLD}$dir${RESET}"

  DET_APPS=(); detect_scan "$dir"
  DET_DEPS=(); detect_deps "$dir"

  if [ ${#DET_APPS[@]} -eq 0 ]; then
    warn "nothing recognisable found in $dir"
    say "  ${C_MUTED}pitcrew looks for gradle, maven, npm, go, cargo, django, python and ruby${RESET}"
    say "  ${C_MUTED}projects, either at the top level or under apis/ apps/ packages/ services/${RESET}"
    say "  ${C_MUTED}Write the config by hand instead: see examples/pitcrew.config.example.sh${RESET}"
    return 1
  fi

  name=${name:-$(basename "$dir")}
  local slug; slug=$(project_slug "$name")

  local target
  if [ "$in_project" = 1 ]; then target="$dir/pitcrew.config.sh"
  else mkdir -p "$PROJECTS_DIR"; target=$(project_file "$slug"); fi
  if [ -e "$target" ] && [ "$force" != 1 ]; then
    die "$target already exists — pass --force to regenerate it"
  fi

  # ── work out ports before writing anything, so collisions can be resolved ──
  USED_PORTS=()
  local app role d kind port
  declare -A P_PORT=() P_CMD=() P_HEALTH=() P_KIND=()
  for app in "${DET_APPS[@]}"; do
    for role in be fe; do
      d=${DET_DIR[$app.$role]:-}; [ -n "$d" ] || continue
      _detect_kind "$d"; P_KIND[$app.$role]=$KIND
      _node_flavour "$d"
      _detect_port "$d" "$KIND"
      if [ -n "$PORT" ] && ! _port_taken "$PORT"; then
        USED_PORTS+=("$PORT"); P_PORT[$app.$role]=$PORT
      fi
    done
  done
  # anything still without one gets the next free port in its role's range
  for app in "${DET_APPS[@]}"; do
    for role in be fe; do
      d=${DET_DIR[$app.$role]:-}; [ -n "$d" ] || continue
      [ -n "${P_PORT[$app.$role]:-}" ] && continue
      if [ "$role" = be ]; then _next_port 8080; else _next_port 3000; fi
      P_PORT[$app.$role]=$NEXT_PORT
    done
  done
  for app in "${DET_APPS[@]}"; do
    for role in be fe; do
      d=${DET_DIR[$app.$role]:-}; [ -n "$d" ] || continue
      _node_flavour "$d"
      _detect_cmd "$dir" "$d" "${P_KIND[$app.$role]}" "${P_PORT[$app.$role]}"
      P_CMD[$app.$role]=$CMD
      _detect_health "$d" "${P_KIND[$app.$role]}"
      P_HEALTH[$app.$role]=$HEALTH
    done
  done

  # ── write it ──
  {
    printf '#!/usr/bin/env bash\n'
    printf '# %s — generated by `pitcrew init` on %(%Y-%m-%d)T.\n' "${target##*/}" -1
    printf '# A guess, not gospel: check the commands and ports below, then edit freely.\n'
    printf '# Full annotated schema: examples/pitcrew.config.example.sh\n\n'
    printf 'PITCREW_ROOT=%q\n' "$dir"
    printf 'PITCREW_PROJECT_NAME=%q\n' "$name"
    printf 'PITCREW_EMOJI="🏁"\n\n'
    printf 'PITCREW_APPS=(%s)\n\n' "${DET_APPS[*]}"

    local a r line
    for a in "${DET_APPS[@]}"; do
      printf '# %s' "$a"
      for r in be fe; do
        [ -n "${DET_DIR[$a.$r]:-}" ] && printf '  ·  %s: %s (%s)' "$r" "${DET_DIR[$a.$r]#"$dir"/}" "${P_KIND[$a.$r]}"
      done
      printf '\n'
      printf 'pitcrew_app %s' "$a"
      for r in be fe; do
        d=${DET_DIR[$a.$r]:-}; [ -n "$d" ] || continue
        printf ' \\\n  --%s-cmd "%s" --%s-port %s' "$r" "${P_CMD[$a.$r]}" "$r" "${P_PORT[$a.$r]}"
        [ -n "${P_HEALTH[$a.$r]}" ] && printf ' \\\n  --%s-health "%s"' "$r" "${P_HEALTH[$a.$r]}"
        if [ -d "$d/src" ]; then printf ' \\\n  --watch-%s "$ROOT/%s/src"' "$r" "${d#"$dir"/}"
        else                     printf ' \\\n  --watch-%s "$ROOT/%s"'     "$r" "${d#"$dir"/}"; fi
      done
      printf '\n\n'
    done

    printf '# ── docker dependencies ─────────────────────────────────────────────────────\n'
    if [ ${#DET_DEPS[@]} -gt 0 ]; then
      printf '# Found in this project'"'"'s compose file. These are CONTAINER names — if yours\n'
      printf '# are prefixed by the compose project, correct them, then uncomment.\n'
      printf '# PITCREW_DEPS=(%s)\n' "${DET_DEPS[*]}"
      printf '# PITCREW_PROTECTED_DEPS=()   # never stopped by `pitcrew stop --deps`\n'
    else
      printf '# PITCREW_DEPS=(postgres redis)\n'
      printf '# PITCREW_PROTECTED_DEPS=(postgres)\n'
    fi
    printf '\n'
    printf '# ── environment prepended to every start command ────────────────────────────\n'
    printf '# PITCREW_BE_ENV="JAVA_HOME=$HOME/.sdkman/candidates/java/current"\n'
    printf '# PITCREW_FE_ENV=""\n\n'
    printf '# ── resource caps and boot timeout ──────────────────────────────────────────\n'
    printf '# PITCREW_BE_MAX="8G"\n# PITCREW_FE_MAX="10G"\n# PITCREW_WAIT_SECS=240\n'
  } > "$target"

  # ── report ──
  say ""
  local a r n_be=0 n_fe=0 guessed=0
  for a in "${DET_APPS[@]}"; do
    printf '    %b%-18s%b' "$C_ACCENT" "$a" "$RESET"
    for r in be fe; do
      [ -n "${DET_DIR[$a.$r]:-}" ] || continue
      [ "$r" = be ] && n_be=$((n_be + 1)) || n_fe=$((n_fe + 1))
      printf ' %b%s%b %b:%s%b %b%s%b' "$C_SUBTLE" "$r" "$RESET" \
        "$C_MUTED" "${P_PORT[$a.$r]}" "$RESET" "$C_FAINT" "${P_KIND[$a.$r]}" "$RESET"
    done
    printf '\n'
  done
  say ""
  ok "wrote ${BOLD}$target${RESET}"
  say "    ${C_MUTED}${#DET_APPS[@]} apps · $n_be backend · $n_fe frontend${RESET}"

  if [ "$in_project" != 1 ]; then
    project_set_current "$slug"
    say "    ${C_MUTED}registered as${RESET} ${BOLD}$slug${RESET} ${C_MUTED}and made current${RESET}"
  fi
  say ""
  say "  ${C_MUTED}next:${RESET} ${BOLD}pitcrew doctor${RESET} ${C_MUTED}to sanity-check it, then${RESET} ${BOLD}pitcrew${RESET}"
  say "  ${C_MUTED}ports and commands are inferred — ${RESET}${BOLD}pitcrew edit${RESET}${C_MUTED} to correct them${RESET}"
  say ""
  return 0
}
