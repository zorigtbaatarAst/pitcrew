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

config_finalize() { # $1 = path to the config file that was just sourced
  CONFIG_FILE=$1
  [ -n "${PITCREW_ROOT:-}" ] && ROOT="$PITCREW_ROOT"
  [ -d "$ROOT" ] || die "project root not found at $ROOT (set PITCREW_ROOT in $CONFIG_FILE)"
  [ ${#PITCREW_APPS[@]} -gt 0 ] || die "$CONFIG_FILE defines no PITCREW_APPS — nothing to run"

  [ -n "$PITCREW_PROJECT_NAME" ] || PITCREW_PROJECT_NAME=$(basename "$ROOT")
  SESSION=$(printf '%s' "$PITCREW_PROJECT_NAME" | tr -c 'A-Za-z0-9_-' '-' | tr 'A-Z' 'a-z')
  LOG_DIR="$ROOT/.pitcrew/logs"
  PROFILE_DIR="$HOME/.config/pitcrew/$SESSION/profiles"
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
