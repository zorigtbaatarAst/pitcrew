#!/usr/bin/env bash
# lib/02-config.sh — locate + load a project's config, fill in defaults, and
# expose small helpers over the resulting app/role model.
#
# A project is: a list of named "apps" (PITCREW_APPS), each with up to two
# roles — "be" (backend) and "fe" (frontend) — a role only exists for an app
# if the config sets a start command for it (PITCREW_BE_CMD[app] /
# PITCREW_FE_CMD[app]). Everything else (ports, health checks, env, deps) is
# optional and keyed the same way.
#
# Those PITCREW_* variables are the model. A config can be written two ways:
# `pitcrew.yaml` (see examples/pitcrew.yaml, parsed by lib/18-yaml.sh) or the
# older `pitcrew.config.sh` (examples/pitcrew.config.example.sh), which is
# bash and sets them directly. The YAML is a front end onto the same
# variables, so everything below this file is format-blind.

# A config's paths are resolved against $ROOT — and in the .sh format its start
# commands expand the moment the file is sourced — so ROOT has to be known
# BEFORE the file is read. For an in-project config that is just the file's
# directory; for one of pitcrew's own it is whatever the file declares. Read it
# out textually rather than loading the file twice.
config_declared_root() { # $1 config file → declared root, or nothing
  [ -r "$1" ] || return 0
  config_is_yaml "$1" && { yaml_declared_root "$1"; return 0; }
  sed -n 's/^[[:space:]]*PITCREW_ROOT=//p' "$1" | head -1 \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# The names an in-project config may have, most preferred first. YAML wins:
# it is the format `pitcrew init` writes and the one a newcomer will have, and
# a project that still has a .sh alongside it is mid-migration — which is worth
# one line of output, not a silent coin-flip.
PITCREW_CONFIG_NAMES=(pitcrew.yaml pitcrew.yml pitcrew.config.sh)

_walk_up_for_config() { # $1 start dir → the nearest in-project config
  local d=$1 f found
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    found=""
    for f in "${PITCREW_CONFIG_NAMES[@]}"; do
      [ -f "$d/$f" ] || continue
      if [ -z "$found" ]; then found=$f
      else warn "$d has both $found and $f — reading $found, ignoring $f"; fi
    done
    [ -n "$found" ] && { printf '%s' "$d/$found"; return 0; }
    d=$(dirname "$d")
  done
  return 1
}

config_is_yaml() { case "$1" in *.yaml|*.yml) return 0 ;; *) return 1 ;; esac; }

# Read a config into the PITCREW_* model, whichever format it is written in.
#
# The .sh branch MUST run at the caller's top level, never inside a function:
# bash scopes a bare `declare -A` in a sourced file to whatever function is
# running, so a project's own `declare -A PITCREW_BE_CMD=(...)` would silently
# shadow-and-discard the real global. That is why this is a wrapper the caller
# expands rather than a function that does the sourcing — see bin/pitcrew.
# The YAML branch has no such hazard: it only assigns into arrays that
# config_defaults already created with `declare -gA`.
config_load() { # $1 file — YAML only; .sh must be sourced by the caller
  yaml_config_load "$1"
}

# Resolution order, most explicit first. An in-project pitcrew.config.sh always
# beats the registry: a repo that ships one is stating how it wants to be run,
# and that should not be silently overridden by whatever happens to be
# registered on this particular machine.
find_config() {
  local dir n f

  # 1. -C/--project <dir> — an explicit ask, so it wins over everything
  if [ -n "${PITCREW_PROJECT_DIR:-}" ]; then
    [ -f "$PITCREW_PROJECT_DIR" ] && { printf '%s' "$PITCREW_PROJECT_DIR"; return 0; }
    [ -d "$PITCREW_PROJECT_DIR" ] || die "--project $PITCREW_PROJECT_DIR: no such file or directory"
    dir=$(cd "$PITCREW_PROJECT_DIR" && pwd)
    _walk_up_for_config "$dir" && return 0
    n=$(project_for_dir "$dir")
    [ -n "$n" ] && { project_file "$n"; return 0; }
    die "no config for $PITCREW_PROJECT_DIR — create one with: pitcrew init $PITCREW_PROJECT_DIR"
  fi

  # 2. -p/--name <name> — a registered project, by name
  if [ -n "${PITCREW_PROJECT_SEL:-}" ]; then
    f=$(project_file "$PITCREW_PROJECT_SEL")
    [ -f "$f" ] || die "no project '$PITCREW_PROJECT_SEL' — see: pitcrew projects"
    printf '%s' "$f"; return 0
  fi

  # 3. $PITCREW_CONFIG
  if [ -n "${PITCREW_CONFIG:-}" ]; then
    [ -f "$PITCREW_CONFIG" ] || die "PITCREW_CONFIG=$PITCREW_CONFIG does not exist"
    printf '%s' "$PITCREW_CONFIG"; return 0
  fi

  # 4. an in-project config, walked up from here
  _walk_up_for_config "$PWD" && return 0

  # 5. a registered project that contains this directory
  n=$(project_for_dir "$PWD")
  [ -n "$n" ] && { project_file "$n"; return 0; }

  # 6. whatever `pitcrew use` last selected
  n=$(project_current) && { project_file "$n"; return 0; }

  return 1
}

# NOTE: config_defaults/config_finalize are functions (fine — they only touch
# scalars, or arrays declared with explicit `-g`, so they're safely global
# either way). The config file itself must NOT be `source`d from inside a
# function: bash scopes a bare `declare -A` in a sourced file to whatever
# function is currently running, so a project's own `declare -A PITCREW_BE_CMD=(...)`
# would silently shadow-and-discard the real global. bin/pitcrew sources it at
# the script's top level instead — see there for the load sequence.

# ── the component model ─────────────────────────────────────────────────────
# An app is a GROUP of components, and the group is open: `be` and `fe` are two
# ordinary role names, not the only two there can be. A component id is
# "<role>-<app>", split on the FIRST dash — which is why a role name may not
# contain one and an app name may (`report-api` is a real app in the wild).
#
# This used to be two fixed roles all the way down: PITCREW_BE_CMD[app],
# PITCREW_FE_PORT[app], `${c:0:2}` to read a role and `${c#??-}` to read an
# app. A monorepo with a worker, a scheduler or a second frontend had nowhere
# to put them. The maps below are keyed by COMPONENT instead, so adding a role
# is data rather than code.
#
# The old arrays are still an input: a hand-written pitcrew.config.sh assigning
# PITCREW_BE_CMD[sales] directly is documented and must keep working, so
# config_finalize folds them in. Nothing READS them after that point.
config_defaults() {
  # defaults — a config file only needs to set what it wants to change
  PITCREW_APPS=()
  PITCREW_ROLES=()                                # every role in use, be/fe first
  declare -gA PITCREW_APP_ROLES=()                # app  -> "be fe worker", in order
  declare -gA PITCREW_CMD=()                      # comp -> start command
  declare -gA PITCREW_PORT=()                     # comp -> port
  declare -gA PITCREW_HEALTH=()                   # comp -> health path
  declare -gA PITCREW_MAX_COMP=()                 # comp -> cap from the config
  declare -gA PITCREW_ROLE_ENV=()                 # role -> env prefix
  declare -gA PITCREW_ROLE_MAX=()                 # role -> default cap
  # A component the config switched off. Still listed — an excluded service
  # that vanishes from the dashboard is one you spend an afternoon looking for
  # — but never started by `all`, a role or an app. Naming it still starts it:
  # this is a default, not a lock.
  declare -gA PITCREW_DISABLED=()
  declare -gA PITCREW_URL_PATH=() PITCREW_WATCH_DIR=() PITCREW_SHELLS=()
  # What the FILE says, before any of it is resolved: `dir: services/orders`
  # rather than the absolute path it became, and a command without the `cd`
  # that gets folded in front of it. `pitcrew config --json` reports these so
  # an editor shows you what you wrote — showing back a resolved path you never
  # typed is how an editor turns a two-line config into a twenty-line one.
  declare -gA PITCREW_SRC_CMD=() PITCREW_SRC_DIR=() PITCREW_SRC_ROOT=() PITCREW_SRC_WATCH=()
  # Components pitcrew will never PROPOSE stopping (lib/19-diag.sh). Not a lock:
  # `pitcrew stop` still stops them, because a tool that refuses to do what you
  # explicitly asked is worse than one that never suggested it. Keyed by
  # component, so a project can protect a backend and not its frontend.
  declare -gA PITCREW_PROTECTED=()

  # ── the legacy shorthand, still supported ──
  declare -gA PITCREW_BE_CMD=() PITCREW_FE_CMD=()
  declare -gA PITCREW_BE_MAX_APP=() PITCREW_FE_MAX_APP=()   # per-app caps, if the config sets any
  declare -gA PITCREW_BE_PORT=() PITCREW_FE_PORT=()
  declare -gA PITCREW_BE_HEALTH_PATH=()

  PITCREW_DEPS=(); PITCREW_PROTECTED_DEPS=(); PITCREW_DEPS_READY_CMD=""
  PITCREW_BE_ENV=""; PITCREW_FE_ENV=""
  PITCREW_BE_MAX="${PITCREW_BE_MAX:-8G}"; PITCREW_FE_MAX="${PITCREW_FE_MAX:-10G}"
  PITCREW_WAIT_SECS="${PITCREW_WAIT:-240}"
  PITCREW_PROJECT_NAME=""; PITCREW_EMOJI=""
}

# Register a role on an app, keeping the order the config declared it in. The
# only place PITCREW_APP_ROLES grows, so "does this app have this role" and
# "in what order" have one answer.
config_add_role() { # $1 app, $2 role
  local app=$1 role=$2
  case " ${PITCREW_APP_ROLES[$app]:-} " in
    *" $role "*) return 0 ;;
  esac
  PITCREW_APP_ROLES[$app]="${PITCREW_APP_ROLES[$app]:+${PITCREW_APP_ROLES[$app]} }$role"
}

# A role name becomes half of a component id, a log filename and a CLI target,
# so it has to be a plain word. A dash would make "<role>-<app>" ambiguous —
# the one thing the whole id scheme rests on.
config_role_ok() { # $1 role
  case "$1" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

pitcrew_app() { # pitcrew_app <name> [--be-cmd CMD] [--fe-cmd CMD] [--be-port N] [--fe-port N]
                 #             [--url-path P] [--be-health PATH] [--watch-be DIRS] [--watch-fe DIRS]
                 #             [--be-max SIZE] [--fe-max SIZE] [--be-protected] [--fe-protected]
                 # One call per app instead of hand-editing 6+ parallel associative arrays.
                 # Purely a shorthand for the arrays below — mix and match with direct
                 # array assignment freely, e.g. for apps with no clean per-app pattern.
  local app=${1:?pitcrew_app needs an app name}; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --be-cmd)    [ $# -ge 2 ] || die "pitcrew_app $app: --be-cmd needs a value";    PITCREW_BE_CMD[$app]=$2; shift 2 ;;
      --fe-cmd)    [ $# -ge 2 ] || die "pitcrew_app $app: --fe-cmd needs a value";    PITCREW_FE_CMD[$app]=$2; shift 2 ;;
      --be-port)   [ $# -ge 2 ] || die "pitcrew_app $app: --be-port needs a value";   PITCREW_BE_PORT[$app]=$2; shift 2 ;;
      --fe-port)   [ $# -ge 2 ] || die "pitcrew_app $app: --fe-port needs a value";   PITCREW_FE_PORT[$app]=$2; shift 2 ;;
      --url-path)  [ $# -ge 2 ] || die "pitcrew_app $app: --url-path needs a value";  PITCREW_URL_PATH[$app]=$2; shift 2 ;;
      --be-health) [ $# -ge 2 ] || die "pitcrew_app $app: --be-health needs a value"; PITCREW_BE_HEALTH_PATH[$app]=$2; shift 2 ;;
      --watch-be)  [ $# -ge 2 ] || die "pitcrew_app $app: --watch-be needs a value";  PITCREW_WATCH_DIR[be-$app]=$2; shift 2 ;;
      --watch-fe)  [ $# -ge 2 ] || die "pitcrew_app $app: --watch-fe needs a value";  PITCREW_WATCH_DIR[fe-$app]=$2; shift 2 ;;
      --be-max)    [ $# -ge 2 ] || die "pitcrew_app $app: --be-max needs a value";    PITCREW_BE_MAX_APP[$app]=$2; shift 2 ;;
      --fe-max)    [ $# -ge 2 ] || die "pitcrew_app $app: --fe-max needs a value";    PITCREW_FE_MAX_APP[$app]=$2; shift 2 ;;
      --be-protected) PITCREW_PROTECTED[be-$app]=1; shift ;;
      --fe-protected) PITCREW_PROTECTED[fe-$app]=1; shift ;;
      *) die "pitcrew_app $app: unknown option '$1'" ;;
    esac
  done
}

# Fold the two-role shorthand into the component maps. Runs once, before
# anything reads them, so the rest of the tool never has to know a config was
# written the old way.
_config_fold_legacy() {
  local app
  for app in "${PITCREW_APPS[@]}"; do
    _config_fold_role "$app" be BE
    _config_fold_role "$app" fe FE
  done
}

_config_fold_role() { # $1 app, $2 role, $3 legacy prefix (BE|FE)
  local app=$1 role=$2 p=$3 comp="$2-$1" cmd port health max
  eval "cmd=\${PITCREW_${p}_CMD[\$app]:-}"
  eval "port=\${PITCREW_${p}_PORT[\$app]:-}"
  eval "max=\${PITCREW_${p}_MAX_APP[\$app]:-}"
  health=""
  [ "$role" = be ] && health=${PITCREW_BE_HEALTH_PATH[$app]:-}
  # The YAML loader has already written these when a project uses it; the
  # shorthand only fills what is still empty, so neither format can silently
  # overwrite the other.
  [ -n "$cmd" ]    && [ -z "${PITCREW_CMD[$comp]:-}" ]      && PITCREW_CMD[$comp]=$cmd
  [ -n "$port" ]   && [ -z "${PITCREW_PORT[$comp]:-}" ]     && PITCREW_PORT[$comp]=$port
  [ -n "$health" ] && [ -z "${PITCREW_HEALTH[$comp]:-}" ]   && PITCREW_HEALTH[$comp]=$health
  [ -n "$max" ]    && [ -z "${PITCREW_MAX_COMP[$comp]:-}" ] && PITCREW_MAX_COMP[$comp]=$max
  [ -n "${PITCREW_CMD[$comp]:-}" ] && config_add_role "$app" "$role"
  return 0
}

# Every role in use, be and fe first so the dashboard's role grouping and the
# `backends` / `frontends` targets keep the order people already read.
_config_collect_roles() {
  local app role
  PITCREW_ROLES=()
  for role in be fe; do
    for app in "${PITCREW_APPS[@]}"; do
      case " ${PITCREW_APP_ROLES[$app]:-} " in
        *" $role "*) PITCREW_ROLES+=("$role"); break ;;
      esac
    done
  done
  for app in "${PITCREW_APPS[@]}"; do
    for role in ${PITCREW_APP_ROLES[$app]:-}; do
      case " ${PITCREW_ROLES[*]} " in *" $role "*) ;; *) PITCREW_ROLES+=("$role") ;; esac
    done
  done
  # The two documented env vars are the be/fe entries of the role tables; a
  # config's own `env:` / `max:` blocks have already filled the rest.
  [ -n "${PITCREW_ROLE_ENV[be]:-}" ] || PITCREW_ROLE_ENV[be]=$PITCREW_BE_ENV
  [ -n "${PITCREW_ROLE_ENV[fe]:-}" ] || PITCREW_ROLE_ENV[fe]=$PITCREW_FE_ENV
  [ -n "${PITCREW_ROLE_MAX[be]:-}" ] || PITCREW_ROLE_MAX[be]=$PITCREW_BE_MAX
  [ -n "${PITCREW_ROLE_MAX[fe]:-}" ] || PITCREW_ROLE_MAX[fe]=$PITCREW_FE_MAX
  for role in "${PITCREW_ROLES[@]}"; do
    # A role nobody gave a budget gets the backend one. Better a cap that is
    # probably too generous than a meter with no scale to draw against.
    [ -n "${PITCREW_ROLE_MAX[$role]:-}" ] || PITCREW_ROLE_MAX[$role]=$PITCREW_BE_MAX
  done
}

config_finalize() { # $1 = path to the config file that was just sourced
  CONFIG_FILE=$1
  [ -n "${PITCREW_ROOT:-}" ] && ROOT="$PITCREW_ROOT"
  [ -d "$ROOT" ] || die "project root not found at $ROOT (set PITCREW_ROOT in $CONFIG_FILE)"
  if [ ${#PITCREW_APPS[@]} -eq 0 ]; then
    config_is_yaml "$CONFIG_FILE" \
      && die "$CONFIG_FILE defines no apps: — nothing to run" \
      || die "$CONFIG_FILE defines no PITCREW_APPS — nothing to run"
  fi

  [ -n "$PITCREW_PROJECT_NAME" ] || PITCREW_PROJECT_NAME=$(basename "$ROOT")
  SESSION=$(printf '%s' "$PITCREW_PROJECT_NAME" | tr -c 'A-Za-z0-9_-' '-' | tr 'A-Z' 'a-z')
  LOG_DIR="$ROOT/.pitcrew/logs"
  PROFILE_DIR="$HOME/.config/pitcrew/$SESSION/profiles"

  _config_fold_legacy
  _config_collect_roles

  # The component list can't change while we're running, so resolve it once
  # here instead of re-running all_components (a fork) inside every frame loop.
  mapfile -t PITCREW_COMPS < <(all_components)

  # The theme, colour depth and icon set are DERIVED values — escape sequences
  # and glyph tables built from settings. lib/01-core.sh builds them when it is
  # sourced, which is before this project's config has been read, so anything
  # the config set would otherwise be ignored. Rebuild now that all is known.
  [ -n "$PITCREW_ICONS_ENV" ] && PITCREW_ICONS=$PITCREW_ICONS_ENV
  icons_load
  theme_load

  # what each app is written in, guessed once from its start command
  declare -gA APP_ICON=()
  local _a _r _cmds
  for _a in "${PITCREW_APPS[@]}"; do
    _cmds=""
    for _r in ${PITCREW_APP_ROLES[$_a]:-}; do _cmds+="${PITCREW_CMD[$_r-$_a]:-}"; done
    app_icon_for "$_cmds"
    APP_ICON[$_a]=$ICON
  done

  # Same reason as the theme: a project may pin how it wants to be drawn, and
  # its config is read after lib/04-meters.sh resolved these from the
  # environment and the saved preference. Re-resolve now that it has had its say.
  render_resolve

  # RAM cap per component, pre-resolved to bytes. The dashboard divides by
  # this once per component per frame; parsing "8G" there would mean a fork.
  # Overrides first: comp_max reads them, and COMP_MAX_B is built from comp_max
  # so the meters, the preflight and systemd all see one number.
  limits_load

  declare -gA COMP_MAX_B=() COMP_MAX_LABEL=()
  local _c
  for _c in "${PITCREW_COMPS[@]}"; do cap_cache_set "$_c"; done
}

# A component id is "<role>-<app>", split on the FIRST dash. Both halves are
# read with plain parameter expansion everywhere, including inside the frame
# loop, because a fork per component per frame is the one thing the dashboard
# may not do:  role=${c%%-*}   app=${c#*-}
app_has_role() { # $1 app $2 role
  case " ${PITCREW_APP_ROLES[$1]:-} " in *" $2 "*) return 0 ;; esac
  return 1
}

app_roles() { # $1 app → its roles, one per line, in the order the config wrote them
  local role
  for role in ${PITCREW_APP_ROLES[$1]:-}; do echo "$role"; done
  return 0
}

comp_port() { echo "${PITCREW_PORT[$1]:-}"; }
comp_cmd()  { echo "${PITCREW_CMD[$1]:-}"; }
comp_env()  { echo "${PITCREW_ROLE_ENV[${1%%-*}]:-}"; }
comp_health() { echo "${PITCREW_HEALTH[$1]:-}"; }
comp_disabled() { [ -n "${PITCREW_DISABLED[$1]:-}" ]; }
comp_max()  { # machine-local override → per-component cap → role default (lib/17-limits.sh)
  local v=${COMP_MAX_OVERRIDE[$1]:-}
  [ -n "$v" ] && { echo "$v"; return; }
  echo "${PITCREW_MAX_COMP[$1]:-${PITCREW_ROLE_MAX[${1%%-*}]:-$PITCREW_BE_MAX}}"
}

# every configured component, stable order: each app's roles in config order.
# Disabled components ARE here — they are listed everywhere, just never started
# by a group target. Leaving them out would make an excluded service look like
# one somebody deleted.
all_components() {
  local app role
  for app in "${PITCREW_APPS[@]}"; do
    for role in ${PITCREW_APP_ROLES[$app]:-}; do echo "$role-$app"; done
  done
}

# Non-fatal sanity checks over the loaded config — catches typos and dead
# entries early with a specific message, instead of a confusing failure (or
# silent no-op) later during start/doctor/logs. Never dies: a warning here
# must not block someone from running a config that's merely unusual.
config_validate() {
  local -A known_app=()
  local app key comp port dep d2 has_known

  for app in "${PITCREW_APPS[@]}"; do known_app[$app]=1; done

  for key in "${!PITCREW_BE_CMD[@]}" "${!PITCREW_FE_CMD[@]}" "${!PITCREW_BE_PORT[@]}" \
             "${!PITCREW_FE_PORT[@]}" "${!PITCREW_URL_PATH[@]}" "${!PITCREW_BE_HEALTH_PATH[@]}"; do
    [ -n "${known_app[$key]:-}" ] || \
      warn "config: '$key' is set in a per-app array but isn't listed in PITCREW_APPS — typo?"
  done

  for app in "${PITCREW_APPS[@]}"; do
    if [ -z "${PITCREW_APP_ROLES[$app]:-}" ]; then
      config_is_yaml "$CONFIG_FILE" \
        && warn "config: app '$app' has no component with a cmd: — nothing will ever start for it" \
        || warn "config: app '$app' has no PITCREW_BE_CMD or PITCREW_FE_CMD — nothing will ever start for it"
    fi
  done

  # A role and an app that share a name make `pitcrew start worker` mean two
  # things. Targets resolve the app first, so the role becomes unreachable —
  # silently, which is the part worth a warning.
  local role
  for role in "${PITCREW_ROLES[@]}"; do
    [ -n "${known_app[$role]:-}" ] && \
      warn "config: '$role' is both a role and an app name — 'pitcrew start $role' will mean the app"
    case "$role" in
      all|deps|backends|frontends) warn "config: role '$role' is also a target keyword — name it something else" ;;
    esac
  done

  local -A port_owner=()
  for comp in $(all_components); do
    port=$(comp_port "$comp")
    [ -n "$port" ] || continue
    if [ -n "${port_owner[$port]:-}" ]; then
      warn "config: port $port is used by both ${port_owner[$port]} and $comp"
    else
      port_owner[$port]=$comp
    fi
  done

  for dep in "${PITCREW_PROTECTED_DEPS[@]:-}"; do
    [ -n "$dep" ] || continue
    has_known=""
    for d2 in "${PITCREW_DEPS[@]}"; do [ "$d2" = "$dep" ] && has_known=1; done
    [ -n "$has_known" ] || warn "config: PITCREW_PROTECTED_DEPS has '$dep' which isn't in PITCREW_DEPS"
  done
}
