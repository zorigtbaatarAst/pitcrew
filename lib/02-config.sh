#!/usr/bin/env bash
# lib/01-config.sh — locate + load a project's pitcrew.config.sh, fill in
# defaults, and expose small helpers over the resulting app/role model.
#
# A project is: a list of named "apps" (PITCREW_APPS), each with up to two
# roles — "be" (backend) and "fe" (frontend) — a role only exists for an app
# if the config sets a start command for it (PITCREW_BE_CMD[app] /
# PITCREW_FE_CMD[app]). Everything else (ports, health checks, env, deps) is
# optional and keyed the same way. See examples/pitcrew.config.example.sh for
# the full schema with comments.

find_config() {
  # -C/--project (bin/pitcrew sets PITCREW_PROJECT_DIR) wins over everything —
  # it's an explicit ask, not a fallback.
  if [ -n "${PITCREW_PROJECT_DIR:-}" ]; then
    [ -f "$PITCREW_PROJECT_DIR" ] && { echo "$PITCREW_PROJECT_DIR"; return; }
    [ -d "$PITCREW_PROJECT_DIR" ] || die "--project $PITCREW_PROJECT_DIR: no such file or directory"
    local dir
    dir=$(cd "$PITCREW_PROJECT_DIR" && pwd)
    while [ "$dir" != "/" ]; do
      if [ -f "$dir/pitcrew.config.sh" ]; then echo "$dir/pitcrew.config.sh"; return; fi
      dir=$(dirname "$dir")
    done
    die "no pitcrew.config.sh found in $PITCREW_PROJECT_DIR or any parent directory"
  fi
  if [ -n "${PITCREW_CONFIG:-}" ]; then
    [ -f "$PITCREW_CONFIG" ] && { echo "$PITCREW_CONFIG"; return; }
    die "PITCREW_CONFIG=$PITCREW_CONFIG does not exist"
  fi
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/pitcrew.config.sh" ]; then echo "$dir/pitcrew.config.sh"; return; fi
    dir=$(dirname "$dir")
  done
  return 1
}

# NOTE: config_defaults/config_finalize are functions (fine — they only touch
# scalars, or arrays declared with explicit `-g`, so they're safely global
# either way). The config file itself must NOT be `source`d from inside a
# function: bash scopes a bare `declare -A` in a sourced file to whatever
# function is currently running, so a project's own `declare -A PITCREW_BE_CMD=(...)`
# would silently shadow-and-discard the real global. bin/pitcrew sources it at
# the script's top level instead — see there for the load sequence.

config_defaults() {
  # defaults — a config file only needs to set what it wants to change
  PITCREW_APPS=()
  declare -gA PITCREW_BE_CMD=() PITCREW_FE_CMD=()
  declare -gA PITCREW_BE_PORT=() PITCREW_FE_PORT=()
  declare -gA PITCREW_BE_HEALTH_PATH=() PITCREW_URL_PATH=() PITCREW_WATCH_DIR=() PITCREW_SHELLS=()
  PITCREW_DEPS=(); PITCREW_PROTECTED_DEPS=(); PITCREW_DEPS_READY_CMD=""
  PITCREW_BE_ENV=""; PITCREW_FE_ENV=""
  PITCREW_BE_MAX="${PITCREW_BE_MAX:-8G}"; PITCREW_FE_MAX="${PITCREW_FE_MAX:-10G}"
  PITCREW_WAIT_SECS="${PITCREW_WAIT:-240}"
  PITCREW_PROJECT_NAME=""; PITCREW_EMOJI=""
}

pitcrew_app() { # pitcrew_app <name> [--be-cmd CMD] [--fe-cmd CMD] [--be-port N] [--fe-port N]
                 #             [--url-path P] [--be-health PATH] [--watch-be DIRS] [--watch-fe DIRS]
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
      *) die "pitcrew_app $app: unknown option '$1'" ;;
    esac
  done
}

config_finalize() { # $1 = path to the config file that was just sourced
  CONFIG_FILE=$1
  [ -n "${PITCREW_ROOT:-}" ] && ROOT="$PITCREW_ROOT"
  [ -d "$ROOT" ] || die "project root not found at $ROOT (set PITCREW_ROOT in $CONFIG_FILE)"
  [ ${#PITCREW_APPS[@]} -gt 0 ] || die "$CONFIG_FILE defines no PITCREW_APPS — nothing to run"

  [ -n "$PITCREW_PROJECT_NAME" ] || PITCREW_PROJECT_NAME=$(basename "$ROOT")
  SESSION=$(printf '%s' "$PITCREW_PROJECT_NAME" | tr -c 'A-Za-z0-9_-' '-' | tr 'A-Z' 'a-z')
  LOG_DIR="$ROOT/.pitcrew/logs"
  PROFILE_DIR="$HOME/.config/pitcrew/$SESSION/profiles"

  # The component list can't change while we're running, so resolve it once
  # here instead of re-running all_components (a fork) inside every frame loop.
  mapfile -t PITCREW_COMPS < <(all_components)

  # RAM cap per component, pre-resolved to bytes. The dashboard divides by
  # this once per component per frame; parsing "8G" there would mean a fork.
  declare -gA COMP_MAX_B=()
  local _c _m
  for _c in "${PITCREW_COMPS[@]}"; do
    [ "${_c:0:2}" = be ] && _m=$PITCREW_BE_MAX || _m=$PITCREW_FE_MAX
    COMP_MAX_B[$_c]=$(to_bytes "$_m")
  done
}

app_has_role() { # $1 app $2 role(be|fe)
  local app=$1 role=$2
  if [ "$role" = be ]; then [ -n "${PITCREW_BE_CMD[$app]:-}" ]
  else [ -n "${PITCREW_FE_CMD[$app]:-}" ]; fi
}

app_roles() { # $1 app → "be", "fe", "be fe", or "" (config error — caught elsewhere)
  local app=$1 out=()
  app_has_role "$app" be && out+=(be)
  app_has_role "$app" fe && out+=(fe)
  printf '%s\n' "${out[@]}"
}

comp_port() { local app=${1#??-}; [ "${1:0:2}" = be ] && echo "${PITCREW_BE_PORT[$app]:-}" || echo "${PITCREW_FE_PORT[$app]:-}"; }
comp_cmd()  { local app=${1#??-}; [ "${1:0:2}" = be ] && echo "${PITCREW_BE_CMD[$app]:-}" || echo "${PITCREW_FE_CMD[$app]:-}"; }
comp_env()  { [ "${1:0:2}" = be ] && echo "$PITCREW_BE_ENV" || echo "$PITCREW_FE_ENV"; }
comp_max()  { [ "${1:0:2}" = be ] && echo "$PITCREW_BE_MAX" || echo "$PITCREW_FE_MAX"; }

# every configured component, stable order: be then fe per app, only roles that exist
all_components() {
  local app role
  for app in "${PITCREW_APPS[@]}"; do
    for role in $(app_roles "$app"); do echo "$role-$app"; done
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
    app_has_role "$app" be || app_has_role "$app" fe || \
      warn "config: app '$app' has no PITCREW_BE_CMD or PITCREW_FE_CMD — nothing will ever start for it"
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
