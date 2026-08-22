#!/usr/bin/env bash
# An app is a GROUP of components, and the group is open.
#
# It used to be a fixed pair: PITCREW_BE_CMD[app] and PITCREW_FE_CMD[app], with
# `${c:0:2}` to read a role and `${c#??-}` to read an app, all the way down to
# the JSON writer. A monorepo with a worker, a scheduler or a second frontend
# had nowhere to put them, and a backend and frontend living in two different
# checkouts meant repeating an absolute path in front of every command.
#
# What this file pins:
#   * a role is whatever the config called it, and it reaches the component
#     list, the targets, the caps, the env and the JSON
#   * `root:` per component (and per app), so two repos are two lines
#   * `enabled: false` excludes from a GROUP target without hiding the row
#   * the two-role shorthand a hand-written pitcrew.config.sh uses still loads
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

# A config loaded the way bin/pitcrew loads one: defaults, parse, finalize.
# finalize is what folds the shorthand and collects the role list, so a test
# that skipped it would be testing half the model.
_project() { # $1 = yaml text → PROJ (the directory), config loaded
  PROJ=$(mktemp -d)
  printf '%s\n' "$1" > "$PROJ/pitcrew.yaml"
  config_defaults
  ROOT=$PROJ; PITCREW_ROOT=$PROJ
  yaml_config_load "$PROJ/pitcrew.yaml" >/dev/null 2>&1
  config_finalize "$PROJ/pitcrew.yaml" >/dev/null 2>&1
}

_cleanup() { [ -n "${PROJ:-}" ] && rm -rf "$PROJ"; PROJ=""; }

_GROUP='apps:
  shop:
    url_path: /api
    be:      { root: ~/api, dir: services/orders, cmd: gradlew bootRun, port: 4000, health: /health }
    fe:      { root: ~/web, dir: apps/shop,       cmd: npm run dev,     port: 3000 }
    worker:  { root: ~/api, cmd: gradlew worker }
    scheduler:
      root: ~/api
      cmd: gradlew scheduler
      enabled: false
  legacy:
    enabled: false
    be: { cmd: make run, port: 9999 }
env:
  be: JAVA_HOME=/opt/jdk
  worker: WORKER_MODE=local
max:
  be: 4G
  worker: 1G'

# ── an app is a group of however many components it has ────────────────────

test_a_role_is_whatever_the_config_called_it() {
  _project "$_GROUP"
  assert_eq "${PITCREW_APP_ROLES[shop]}" "be fe worker scheduler" \
    "in the order the file declares them, not an order this tool imposes"
  assert_match "${PITCREW_COMPS[*]}" 'worker-shop'    "a worker is a component"
  assert_match "${PITCREW_COMPS[*]}" 'scheduler-shop' "so is a scheduler"
  _cleanup
}

test_the_role_list_puts_the_two_familiar_ones_first() {
  # `backends` and `frontends` are still the targets people type, and the
  # dashboard groups by role. A worker appearing above the backend because it
  # happened to be declared first would be a gratuitous reshuffle.
  _project "$_GROUP"
  assert_eq "${PITCREW_ROLES[0]}" be "backends first"
  assert_eq "${PITCREW_ROLES[1]}" fe "then frontends"
  assert_match "${PITCREW_ROLES[*]}" 'worker'    "then whatever else exists"
  _cleanup
}

test_a_role_name_that_cannot_be_half_of_a_component_id_is_refused() {
  # "<role>-<app>" splits on the FIRST dash, so a dash in a role name makes
  # every component id ambiguous — including the log and pid filenames.
  _project 'apps:
  a:
    my-worker: { cmd: "true" }'
  assert_empty "${PITCREW_APP_ROLES[a]:-}" "the bad role registers nothing"
  _cleanup
}

test_an_app_name_may_still_contain_a_dash() {
  # report-api is a real service name; splitting on the LAST dash would break
  # it, which is why the split is on the first.
  _project 'apps:
  report-api:
    be: { cmd: "true", port: 1 }'
  assert_eq "${PITCREW_COMPS[*]}" "be-report-api" "role be, app report-api"
  assert_eq "${PITCREW_PORT[be-report-api]}" 1    "and the port lands on it"
  _cleanup
}

# ── two checkouts, two lines ────────────────────────────────────────────────

test_each_component_can_live_in_its_own_checkout() {
  _project "$_GROUP"
  assert_match "${PITCREW_CMD[be-shop]}" "^cd '$HOME/api/services/orders' && " \
    "the backend runs in its own repo"
  assert_match "${PITCREW_CMD[fe-shop]}" "^cd '$HOME/web/apps/shop' && " \
    "the frontend in a different one"
  assert_match "${PITCREW_CMD[worker-shop]}" "^cd '$HOME/api' && " \
    "root with no dir is the root itself"
  _cleanup
}

test_a_tilde_is_a_home_directory_and_not_a_folder_called_tilde() {
  # This was the one path spelling that did not work: $HOME expanded and ~ did
  # not, so `dir: ~/work/api` resolved to "$ROOT/~/work/api" — a directory that
  # cannot exist. `pitcrew check` called it clean and it failed at start time.
  _project 'apps:
  a:
    be: { dir: ~/work/api, cmd: "true" }
    fe: { root: "~", dir: web, cmd: "true" }'
  assert_match "${PITCREW_CMD[be-a]}" "^cd '$HOME/work/api' && " "~/ is the home directory"
  assert_match "${PITCREW_CMD[fe-a]}" "^cd '$HOME/web' && "      "a bare ~ is too"
  assert_not_match "${PITCREW_CMD[be-a]}" '~' "and no tilde survives into the command"
  _cleanup
}

test_an_app_root_covers_its_group_and_a_component_may_still_differ() {
  _project 'apps:
  a:
    root: ~/mono
    be: { dir: api, cmd: "true" }
    fe: { root: ~/elsewhere, cmd: "true" }'
  assert_match "${PITCREW_CMD[be-a]}" "^cd '$HOME/mono/api' && " "the group root, plus a dir"
  assert_match "${PITCREW_CMD[fe-a]}" "^cd '$HOME/elsewhere' && " "a component overrides it"
  _cleanup
}

test_watch_dirs_resolve_against_the_same_root_as_the_command() {
  # Otherwise `pitcrew stale` watches a path in the project directory while the
  # service runs somewhere else entirely, and reports nothing, forever.
  _project 'apps:
  a:
    be:
      root: ~/api
      dir: services/orders
      cmd: "true"
      watch: [src, ../shared]'
  assert_match "${PITCREW_WATCH_DIR[be-a]}" "$HOME/api/src"       "relative to the component root"
  assert_match "${PITCREW_WATCH_DIR[be-a]}" "$HOME/api/../shared" "including one that climbs out"
  _cleanup
}

test_a_component_with_a_dir_and_no_watch_watches_where_it_runs() {
  _project 'apps:
  a:
    be: { root: ~/api, dir: services/orders, cmd: "true" }'
  assert_eq "${PITCREW_WATCH_DIR[be-a]}" "$HOME/api/services/orders" "the resolved dir, not the raw one"
  _cleanup
}

# ── exclusion ───────────────────────────────────────────────────────────────

test_a_disabled_component_is_listed_but_not_in_a_group_target() {
  _project "$_GROUP"
  assert_match "${PITCREW_COMPS[*]}" 'scheduler-shop' "still listed — an excluded service that vanishes is one you hunt for"
  comp_disabled scheduler-shop || _t_bad "scheduler-shop should report as disabled"

  local all; all=$(resolve_targets all | tr '\n' ' ')
  assert_not_match "$all" 'scheduler-shop' "start all skips it"
  assert_match     "$all" 'worker-shop'    "and takes the rest of the group"

  local grp; grp=$(resolve_targets shop | tr '\n' ' ')
  assert_not_match "$grp" 'scheduler-shop' "naming the app skips it too"
  _cleanup
}

test_naming_a_disabled_component_still_starts_it() {
  # `enabled: false` is a default, not a lock. A switch you cannot override
  # from the command line is a trap, and pitcrew already made that call once
  # for `protected:`.
  _project "$_GROUP"
  assert_eq "$(resolve_targets scheduler-shop)" "scheduler-shop" "named outright, it resolves"
  _cleanup
}

test_switching_off_a_whole_app_switches_off_every_role_in_it() {
  _project "$_GROUP"
  comp_disabled be-legacy || _t_bad "an app-level enabled:false must reach its components"
  local all; all=$(resolve_targets all | tr '\n' ' ')
  assert_not_match "$all" 'be-legacy' "and keep them out of start all"
  _cleanup
}

test_an_app_switched_off_before_its_roles_are_declared_still_switches_them_off() {
  # `enabled:` may sit above the roles it governs — which it does, because that
  # is where a reader looks for it. Applying it as it is read would miss them.
  _project 'apps:
  a:
    enabled: false
    be: { cmd: "true" }
    worker: { cmd: "true" }'
  comp_disabled be-a     || _t_bad "be-a should be off"
  comp_disabled worker-a || _t_bad "worker-a should be off"
  _cleanup
}

# ── targets ─────────────────────────────────────────────────────────────────

test_a_role_is_a_target_across_every_app_that_has_one() {
  _project 'apps:
  a:
    be: { cmd: "true" }
    worker: { cmd: "true" }
  b:
    worker: { cmd: "true" }'
  local t; t=$(resolve_targets worker | tr '\n' ' ')
  assert_match "$t" 'worker-a' "one app"
  assert_match "$t" 'worker-b' "and the other"
  assert_not_match "$t" 'be-a' "and nothing else"
  _cleanup
}

test_an_app_wins_a_name_clash_with_a_role_and_the_config_is_told() {
  # _project OUTSIDE the substitution: run inside one it would load the config
  # into a subshell and the assertions below would read an empty model.
  _project 'apps:
  worker:
    be: { cmd: "true" }
  b:
    worker: { cmd: "true" }'
  local out; out=$(config_validate 2>&1)
  assert_match "$(plain "$out")" "both a role and an app name" "the clash is reported"
  assert_eq "$(resolve_targets worker | tr '\n' ' ')" "be-worker " "and the app is what the word means"
  _cleanup
}

test_a_role_named_after_a_target_keyword_is_reported() {
  _project 'apps:
  a:
    all: { cmd: "true" }'
  local out; out=$(config_validate 2>&1)
  assert_match "$(plain "$out")" "also a target keyword" "'all' can never be reached as a role"
  _cleanup
}

# ── caps and env are per role ───────────────────────────────────────────────

test_a_new_role_gets_its_own_env_and_cap() {
  _project "$_GROUP"
  assert_eq "$(comp_env worker-shop)" "WORKER_MODE=local" "env: is keyed by role, not by be/fe"
  assert_eq "$(comp_max worker-shop)" "1G"                "and so is max:"
  assert_eq "$(comp_env be-shop)"     "JAVA_HOME=/opt/jdk" "the familiar two still work"
  assert_eq "$(comp_max be-shop)"     "4G"
  _cleanup
}

test_a_role_nobody_budgeted_still_has_a_cap_to_measure_against() {
  # A meter with no scale draws nothing. Better a cap that is probably too
  # generous than a component whose RAM bar cannot be drawn at all.
  _project "$_GROUP"
  assert_ne "$(comp_max scheduler-shop)" "" "an unbudgeted role falls back"
  _cleanup
}

test_a_health_path_is_a_per_component_question() {
  _project "$_GROUP"
  assert_eq "$(comp_health be-shop)" "/health" "where it is set"
  assert_empty "$(comp_health worker-shop)" "and absent where it is not"
  _cleanup
}

# ── the shorthand a hand-written config still uses ──────────────────────────

test_the_two_role_shorthand_still_loads() {
  # A pitcrew.config.sh assigning PITCREW_BE_CMD[sales] directly is documented,
  # and every existing installation has one. It is an INPUT now — folded into
  # the component maps at finalize — and nothing reads it afterwards.
  local d; d=$(mktemp -d)
  cat > "$d/pitcrew.config.sh" <<'SH'
PITCREW_APPS=(sales)
PITCREW_BE_CMD[sales]="true"
PITCREW_BE_PORT[sales]=8111
PITCREW_BE_HEALTH_PATH[sales]="/actuator/health"
PITCREW_BE_MAX_APP[sales]="512M"
PITCREW_FE_CMD[sales]="true"
PITCREW_FE_PORT[sales]=3111
SH
  config_defaults
  ROOT=$d; PITCREW_ROOT=$d
  # shellcheck source=/dev/null
  source "$d/pitcrew.config.sh"
  config_finalize "$d/pitcrew.config.sh" >/dev/null 2>&1

  assert_eq "${PITCREW_APP_ROLES[sales]}" "be fe"  "both roles registered"
  assert_eq "${PITCREW_CMD[be-sales]}"    "true"   "command folded in"
  assert_eq "${PITCREW_PORT[fe-sales]}"   3111     "and the frontend port"
  assert_eq "${PITCREW_HEALTH[be-sales]}" "/actuator/health" "and the health path"
  assert_eq "$(comp_max be-sales)"        "512M"   "and the per-app cap"
  rm -rf "$d"
}

test_nothing_outside_the_config_module_reads_the_shorthand() {
  # The fold has one job and one place. A second reader would be a second
  # source of truth for what a component's port is.
  local strays
  # 14-init.sh and 14-detect.sh WRITE the shorthand — they generate a
  # pitcrew.config.sh for people who ask for one — and 15-registry.sh folds it
  # explicitly. Reading it anywhere else is the drift this guards against.
  strays=$(grep -rln 'PITCREW_BE_CMD\[\|PITCREW_FE_CMD\[\|PITCREW_BE_PORT\[\|PITCREW_FE_PORT\[\|PITCREW_BE_HEALTH_PATH\[\|PITCREW_BE_MAX_APP\[\|PITCREW_FE_MAX_APP\[' \
             "$PITCREW_DIR/lib" | grep -vE '(02-config|14-init|14-detect)\.sh$' | tr '\n' ' ')
  assert_empty "$strays" "lib files still reading the two-role arrays"
}

# ── the JSON contract ───────────────────────────────────────────────────────

test_the_stream_reports_the_role_and_whether_it_is_enabled() {
  # The GUI draws from this and nothing else. A component it never saw could
  # not be told from one somebody deleted.
  _project "$_GROUP"
  local out; out=$(cmd_json 2>/dev/null)
  assert_match "$out" '"role":"worker"'    "a role it has never heard of arrives as data"
  assert_match "$out" '"enabled":false'    "and an excluded component says so"
  assert_match "$out" '"name":"scheduler-shop"' "by name"
  _cleanup
}

run_tests
