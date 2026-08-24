#!/usr/bin/env bash
# lib/21-migrate.sh — turn a loaded config into the YAML that means the same.
#
# `pitcrew.config.sh` is not deprecated and never will be: a config that has to
# branch on the machine it runs on needs a shell. But most of them do not, and
# a real one looks like this —
#
#   declare -A _BE_PORT=([backoffice]=8091 [sales]=8082 …)
#   for _app in "${PITCREW_APPS[@]}"; do
#     pitcrew_app "$_app" --be-cmd "./gradlew :$_app:backend:bootRun" …
#   done
#
# — which is compact to write, and unreadable to anyone asking "what port is
# sales on". It also cannot be edited as a form, because a form that could not
# round-trip a `for` loop would quietly drop it.
#
# pitcrew has already done the hard part by the time this runs: the loop has
# been executed and the model holds six concrete apps. So this writes out what
# the model actually says.
#
# The conversion is CHECKED, not asserted. The generated file is loaded in a
# subshell and its model compared, field by field, against the one in memory.
# A migration that silently changed a port would be worse than no migration.

# Every path pitcrew resolved is absolute, because that is what it needs at
# run time. A config full of one laptop's absolute paths is not one you can
# commit, so put them back the way a person would have written them.
# A variable, not a literal, so shellcheck can tell a `~` being WRITTEN from a
# `~` somebody forgot to let the shell expand.
_MIG_TILDE='~'

_mig_relpath() { # $1 absolute path → MIG_PATH (relative to ROOT, or ~/…, or as-is)
  local p=$1
  case "$p" in
    "$ROOT")    MIG_PATH="" ;;
    "$ROOT"/*)  MIG_PATH=${p#"$ROOT"/} ;;
    "$HOME"/*)  MIG_PATH="$_MIG_TILDE/${p#"$HOME"/}" ;;
    *)          MIG_PATH=$p ;;
  esac
}

# `cd <dir> && <command>` is what `dir:` exists to spell. Splitting it back out
# is most of what makes the generated file readable: one `dir:` line instead of
# an absolute path repeated in front of every command.
#
# Handles both spellings — bare from a .sh config, single-quoted from the YAML
# loader's own folding — and leaves anything it does not recognise alone.
_mig_split_cd() { # $1 command → MIG_DIR (absolute, or ""), MIG_CMD
  local cmd=$1 rest dir
  MIG_DIR=""; MIG_CMD=$cmd
  case "$cmd" in
    "cd '"*)
      rest=${cmd#cd \'}
      case "$rest" in *"' && "*) ;; *) return 0 ;; esac
      dir=${rest%%\' && *}
      MIG_DIR=$dir; MIG_CMD=${rest#"$dir"\' && } ;;
    'cd '*)
      rest=${cmd#cd }
      case "$rest" in *' && '*) ;; *) return 0 ;; esac
      dir=${rest%% && *}
      # A directory with a space in it, unquoted, is not a `cd` we can take
      # apart with any confidence. Leave the command whole.
      case "$dir" in *' '*|*\'*|*\"*) MIG_DIR=""; MIG_CMD=$cmd; return 0 ;; esac
      MIG_DIR=$dir; MIG_CMD=${rest#"$dir" && } ;;
  esac
  return 0
}

# A .sh config expands "$ROOT/x" at source time, so the model holds one
# laptop's absolute paths. `$ROOT` and `$HOME` are the two things the YAML
# loader expands itself, so putting them back makes the generated file the one
# a person would have written — and one that survives being committed and
# cloned somewhere else.
#
# ROOT before HOME, because a checkout usually lives under the home directory
# and the more specific substitution has to win.
_mig_portable() { # $1 → MIG_TEXT
  local v=$1
  [ -n "$ROOT" ] && [ "$ROOT" != / ] && v=${v//"$ROOT"/'$ROOT'}
  [ -n "$HOME" ] && [ "$HOME" != / ] && v=${v//"$HOME"/'$HOME'}
  MIG_TEXT=$v
}

# `[a, b, c]` — with the space, because this file is meant to be read.
_mig_list() {
  local first=1 item
  for item in "$@"; do
    [ -n "$item" ] || continue
    [ $first = 1 ] || printf ', '
    first=0
    printf '%s' "$(_yqb "$item")"
  done
}

# A stable dump of what the config MEANS, for comparing before and after. Not
# the file, not the source values — the resolved model every other part of
# pitcrew reads.
migrate_fingerprint() {
  local app role c
  printf 'name\t%s\n'  "$PITCREW_PROJECT_NAME"
  printf 'emoji\t%s\n' "$PITCREW_EMOJI"
  printf 'wait\t%s\n'  "$PITCREW_WAIT_SECS"
  printf 'apps\t%s\n'  "${PITCREW_APPS[*]}"
  printf 'deps\t%s\n'  "${PITCREW_DEPS[*]:-}"
  printf 'pdeps\t%s\n' "${PITCREW_PROTECTED_DEPS[*]:-}"
  printf 'ready\t%s\n' "$PITCREW_DEPS_READY_CMD"
  for app in "${PITCREW_APPS[@]}"; do
    printf 'app\t%s\t%s\t%s\n' "$app" "${PITCREW_APP_ROLES[$app]:-}" "${PITCREW_URL_PATH[$app]:-}"
  done
  for c in $(all_components); do
    # The `cd` prefix is compared as a DIRECTORY and a command, not as a
    # string: a .sh config writes `cd /path && …` and the YAML loader writes
    # `cd '/path' && …`, which run identically and differ by two quotes. A
    # check that failed on that would only teach people to pass --force.
    _mig_split_cd "${PITCREW_CMD[$c]:-}"
    printf 'comp\t%s\tdir=%s\tcmd=%s\tport=%s\thealth=%s\tmax=%s\tenv=%s\tprot=%s\toff=%s\n' \
      "$c" "$MIG_DIR" "$MIG_CMD" "${PITCREW_PORT[$c]:-}" "${PITCREW_HEALTH[$c]:-}" \
      "$(comp_max "$c")" "$(comp_env "$c")" \
      "${PITCREW_PROTECTED[$c]:-}" "${PITCREW_DISABLED[$c]:-}"
  done
  local name
  for name in $(printf '%s\n' "${!PITCREW_SHELLS[@]}" | sort); do
    printf 'shell\t%s\t%s\n' "$name" "${PITCREW_SHELLS[$name]}"
  done
  return 0
}

# Watch dirs are compared SEPARATELY, and a difference in them is a note
# rather than a refusal.
#
# The reason is a real behaviour change the conversion makes on purpose. A .sh
# config open-codes `cd <dir> && …` and watches only what --watch-be named; in
# YAML that `cd` becomes `dir:`, and a component with a dir and no watch of its
# own watches the directory it runs in. So a frontend that watched nothing now
# watches its own folder — which is better, and is still a change to what
# `pitcrew stale` reports, so it gets said out loud rather than either
# swallowed or treated as a corrupted conversion.
migrate_watchprint() {
  local c
  for c in $(all_components); do
    printf '%s\t%s\n' "$c" "${PITCREW_WATCH_DIR[$c]:-}"
  done
  return 0
}

# The YAML itself. Written from the model, so a `for` loop that produced six
# apps produces six apps here — spelled out, which is the entire point.
migrate_render() {
  local app role c dir cmd watch w rel any name
  printf '# %s — converted from %s by `pitcrew migrate` on %(%Y-%m-%d)T.\n' \
    "${PITCREW_PROJECT_NAME:-pitcrew}" "${CONFIG_FILE##*/}" -1
  printf '#\n'
  printf '# Everything the old config computed is written out here. Full annotated\n'
  printf '# schema: examples/pitcrew.yaml\n\n'
  [ -n "$PITCREW_PROJECT_NAME" ] && printf 'name: %s\n' "$(_yqb "$PITCREW_PROJECT_NAME")"
  [ -n "$PITCREW_EMOJI" ]        && printf 'emoji: %s\n' "$(_yqb "$PITCREW_EMOJI")"
  printf '\napps:\n'
  for app in "${PITCREW_APPS[@]}"; do
    printf '  %s:\n' "$app"
    [ -n "${PITCREW_URL_PATH[$app]:-}" ] && \
      printf '    url_path: %s\n' "$(_yqb "${PITCREW_URL_PATH[$app]}")"
    for role in ${PITCREW_APP_ROLES[$app]:-}; do
      c="$role-$app"
      printf '    %s:\n' "$role"
      _mig_split_cd "${PITCREW_CMD[$c]:-}"
      cmd=$MIG_CMD
      if [ -n "$MIG_DIR" ]; then
        _mig_relpath "$MIG_DIR"
        # A component outside the project root keeps its own `root:` — which is
        # what that key is for, and what a two-repo project needs.
        case "$MIG_PATH" in
          '')  ;;
          /*|"$_MIG_TILDE"/*) printf '      root: %s\n' "$(_yqb "$MIG_PATH")" ;;
          *)   printf '      dir: %s\n' "$(_yqb "$MIG_PATH")" ;;
        esac
      fi
      _mig_portable "$cmd"
      printf '      cmd: %s\n' "$(_yqb "$MIG_TEXT")"
      [ -n "${PITCREW_PORT[$c]:-}" ]      && printf '      port: %s\n' "${PITCREW_PORT[$c]}"
      [ -n "${PITCREW_HEALTH[$c]:-}" ]    && printf '      health: %s\n' "$(_yqb "${PITCREW_HEALTH[$c]}")"
      [ -n "${PITCREW_MAX_COMP[$c]:-}" ]  && printf '      max: %s\n' "$(_yqb "${PITCREW_MAX_COMP[$c]}")"
      [ -n "${PITCREW_PROTECTED[$c]:-}" ] && printf '      protected: true\n'
      [ -n "${PITCREW_DISABLED[$c]:-}" ]  && printf '      enabled: false\n'
      # Only when it is not just the directory the component runs in — that is
      # the default, and writing it out would be noise in every single block.
      watch=""
      if [ -n "${PITCREW_WATCH_DIR[$c]:-}" ] && [ "${PITCREW_WATCH_DIR[$c]}" != "$MIG_DIR" ]; then
        any=""
        for w in ${PITCREW_WATCH_DIR[$c]}; do
          _mig_relpath "$w"
          rel=$MIG_PATH; [ -n "$rel" ] || rel=.
          watch+="${any:+, }$(_yqb "$rel")"; any=1
        done
        printf '      watch: [%s]\n' "$watch"
      fi
    done
  done

  if [ ${#PITCREW_DEPS[@]} -gt 0 ]; then
    printf '\ndeps: [%s]\n' "$(_mig_list "${PITCREW_DEPS[@]}")"
    [ ${#PITCREW_PROTECTED_DEPS[@]} -gt 0 ] && \
      printf 'protected_deps: [%s]\n' "$(_mig_list "${PITCREW_PROTECTED_DEPS[@]}")"
    if [ -n "$PITCREW_DEPS_READY_CMD" ]; then
      _mig_portable "$PITCREW_DEPS_READY_CMD"
      printf 'deps_ready: %s\n' "$(_yqb "$MIG_TEXT")"
    fi
  fi

  local rfirst=1
  for role in "${PITCREW_ROLES[@]:-}"; do
    [ -n "${PITCREW_ROLE_ENV[$role]:-}" ] || continue
    [ $rfirst = 1 ] && { printf '\nenv:\n'; rfirst=0; }
    _mig_portable "${PITCREW_ROLE_ENV[$role]}"
    printf '  %s: %s\n' "$role" "$(_yqb "$MIG_TEXT")"
  done

  rfirst=1
  for role in "${PITCREW_ROLES[@]:-}"; do
    [ -n "${PITCREW_ROLE_MAX[$role]:-}" ] || continue
    [ $rfirst = 1 ] && { printf '\nmax:\n'; rfirst=0; }
    printf '  %s: %s\n' "$role" "$(_yqb "${PITCREW_ROLE_MAX[$role]}")"
  done
  printf 'wait: %s\n' "$PITCREW_WAIT_SECS"

  if [ ${#PITCREW_SHELLS[@]} -gt 0 ]; then
    printf '\nshells:\n'
    local name
    for name in $(printf '%s\n' "${!PITCREW_SHELLS[@]}" | sort); do
      _mig_portable "${PITCREW_SHELLS[$name]}"
      printf '  %s: %s\n' "$name" "$(_yqb "$MIG_TEXT")"
    done
  fi
  return 0
}

# What the YAML cannot carry. Said before anything is written, because these
# are the parts somebody has to port by hand.
migrate_warnings() {
  local out=()
  declare -F pitcrew_doctor_extra >/dev/null && \
    out+=("pitcrew_doctor_extra() is a shell function — rewrite it as \`doctor:\` label/command pairs")
  [ -n "${PITCREW_ROOT:-}" ] && [ "$PITCREW_ROOT" != "$ROOT" ] && \
    out+=("PITCREW_ROOT points somewhere else — check the \`root:\` in the result")
  [ ${#out[@]} -eq 0 ] && return 0
  printf '%s\n' "${out[@]}"
}

# ── the pointer at the config ───────────────────────────────────────────────
#
# "pitcrew reads YAML in preference to .sh" is true of a config found by
# walking up from a directory, and NOT true of a registered project. `pitcrew
# -p autoland` resolves to ~/.config/pitcrew/projects/autoland.sh, and the
# entry `pitcrew init` writes for a repo that ships its own config names the
# file it points at out loud:
#
#     source "$PITCREW_ROOT/pitcrew.config.sh"
#
# Leave that alone and the conversion writes a file nothing ever reads: every
# -p command, the dashboard and the desktop app keep loading the .sh, and the
# only visible symptom is the app offering to convert it a second time. So the
# pointer moves with the file it points at.
#
# Only the pointer. A registry entry that HOLDS a config rather than pointing
# at one is somebody's own file, and this command does not rewrite those — it
# says what is still being read instead.
_mig_entry_is_pointer() { # $1 registry entry → is it a stub that sources the .sh?
  grep -qE '^[[:space:]]*(\.|source)[[:space:]]+.*pitcrew\.config\.sh' "$1" 2>/dev/null
}

migrate_repoint_registry() { # $1 the YAML just written
  local dest=$1 name entry target rel
  name=$(project_for_dir "$ROOT") || return 0
  [ -n "$name" ] || return 0
  entry=$(project_file "$name")
  [ -f "$entry" ] || return 0
  config_is_yaml "$entry" && return 0

  if ! _mig_entry_is_pointer "$entry"; then
    say ""
    warn "the registry entry for ${BOLD}${name}${RESET} is a bash config in its own right:"
    say "    ${C_MUTED}${entry}${RESET}"
    say "    ${C_MUTED}pitcrew -p ${name} still loads that one. Re-register with${RESET} pitcrew init $ROOT"
    return 0
  fi

  case "$dest" in
    "$ROOT"/*) rel=${dest#"$ROOT"/} ;;
    *) say ""
       warn "the registry entry for ${BOLD}${name}${RESET} still points at ${CONFIG_FILE##*/}"
       say "    ${C_MUTED}${entry}${RESET}"
       say "    ${C_MUTED}it points into ${ROOT}, and this went elsewhere — repoint it by hand${RESET}"
       return 0 ;;
  esac

  target="$PROJECTS_DIR/$name.yaml"
  {
    printf '# %s — repointed by `pitcrew migrate` on %(%Y-%m-%d)T.\n' "$name" -1
    printf '#\n# This project ships its own %s, so this entry just points at it.\n' "${dest##*/}"
    printf '# Edit the config in the repository, not here. `pitcrew init --detect`\n'
    printf '# replaces this with a freshly detected config instead.\n\n'
    # `include:` FIRST — the loader requires it to be the first key (lib/18-yaml.sh).
    printf 'include: %s\n' "$rel"
    printf 'root: %s\n' "$ROOT"
  } > "$target" || die "could not write $target"
  ok "the registry entry for ${BOLD}${name}${RESET} points at it now"
  say "    ${C_MUTED}${target}${RESET}"
  _init_prune_registry "$name" "$target"
}

cmd_migrate() { # [--force] [--print] [-o FILE]
  local force=0 print_only=0 dest=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      --print|-n) print_only=1; shift ;;
      -o)         [ $# -ge 2 ] || die "-o needs a file"; dest=$2; shift 2 ;;
      *) die "usage: pitcrew migrate [--print] [--force] [-o <file>]" ;;
    esac
  done
  [ -n "$dest" ] || dest="$ROOT/pitcrew.yaml"

  if config_is_yaml "$CONFIG_FILE" && [ "$print_only" = 0 ]; then
    die "$CONFIG_FILE is already YAML — nothing to convert"
  fi

  local rendered; rendered=$(migrate_render)

  if [ "$print_only" = 1 ]; then
    printf '%s\n' "$rendered"
    return 0
  fi

  banner
  say "  ${BOLD}converting${RESET} ${C_MUTED}${CONFIG_FILE}${RESET}"
  say ""

  local warn_lines; warn_lines=$(migrate_warnings)
  if [ -n "$warn_lines" ]; then
    local l
    while IFS= read -r l; do warn "$l"; done <<< "$warn_lines"
    say ""
  fi

  # ── the check ──
  # Write to a temporary file, load THAT, and compare what it means against
  # what is loaded now. A conversion that quietly changed a port would be
  # worse than not offering one.
  local probe; probe=$(mktemp).yaml
  printf '%s\n' "$rendered" > "$probe"
  local before after wbefore wafter
  before=$(migrate_fingerprint)
  wbefore=$(migrate_watchprint)
  after=$(
    ROOT_KEEP=$ROOT
    config_defaults
    ROOT=$ROOT_KEEP; PITCREW_ROOT=$ROOT
    yaml_config_load "$probe" >/dev/null 2>&1
    _config_fold_legacy; _config_collect_roles
    CONFIG_FILE=$probe
    migrate_fingerprint
  )
  wafter=$(
    ROOT_KEEP=$ROOT
    config_defaults
    ROOT=$ROOT_KEEP; PITCREW_ROOT=$ROOT
    yaml_config_load "$probe" >/dev/null 2>&1
    _config_fold_legacy; _config_collect_roles
    migrate_watchprint
  )
  if [ "$before" != "$after" ]; then
    rm -f "$probe"
    say "  ${C_CRIT}✗${RESET} the generated YAML does not mean the same thing."
    say ""
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null \
      | sed 's/^/    /' | head -20
    say ""
    die "nothing was written — please open an issue with the config that did this"
  fi
  rm -f "$probe"
  ok "the result loads to exactly the same model — every port, command and cap"

  # The one thing the conversion deliberately changes.
  if [ "$wbefore" != "$wafter" ]; then
    local c wa wb
    say ""
    warn "\`pitcrew stale\` will watch a little more than it did:"
    while IFS=$'\t' read -r c wb; do
      wa=$(printf '%s\n' "$wafter" | awk -F'\t' -v k="$c" '$1 == k {print $2}')
      [ "$wa" = "$wb" ] && continue
      _mig_relpath "${wa:-}"
      say "    ${C_MUTED}${c}${RESET}  ${wb:-nothing} ${C_MUTED}→${RESET} ${MIG_PATH:-nothing}"
    done <<< "$wbefore"
    say "    ${C_MUTED}a component with a dir: and no watch: of its own watches where it runs${RESET}"
  fi

  if [ -e "$dest" ] && [ "$force" = 0 ]; then
    die "$dest already exists — pass --force to overwrite, or -o <file>"
  fi
  # The bash config that is left over, which is NOT always $CONFIG_FILE: for a
  # registered project that is the registry pointer, and the repoint below
  # replaces it. Read before, because it may not exist after.
  local leftover=$CONFIG_FILE
  _mig_entry_is_pointer "$CONFIG_FILE" && [ -f "$ROOT/pitcrew.config.sh" ] \
    && leftover="$ROOT/pitcrew.config.sh"

  printf '%s\n' "$rendered" > "$dest" || die "could not write $dest"
  ok "wrote $dest"
  migrate_repoint_registry "$dest"
  say ""
  # find_config prefers YAML, so the new file is already what pitcrew reads.
  # Saying so beats letting somebody edit the .sh for an afternoon.
  say "  ${C_MUTED}pitcrew reads YAML in preference to .sh, so this is live now.${RESET}"
  say "  ${C_MUTED}Check it with${RESET} pitcrew check ${C_MUTED}and${RESET} pitcrew status${C_MUTED}, then delete${RESET} ${leftover##*/}${C_MUTED}.${RESET}"
  say ""
  return 0
}
