#!/usr/bin/env bash
# Project detection and the registry.
#
# The promise of `pitcrew init` is a config that RUNS. Testing that it wrote
# some file is nearly worthless; what matters is that loading the generated
# config produces the components you would have written by hand. So these
# tests build a repository, init it, then source the result and inspect the
# model it produced.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

FIX=$(mktemp -d)

# a monorepo with the two shapes that actually occur: <app>/{backend,frontend}
# at the top level, and a group directory of backend-only services
mk() { mkdir -p "$(dirname "$1")"; printf '%s' "${2:-}" > "$1"; }
mkdir -p "$FIX/repo" && ROOTFIX="$FIX/repo"
: > "$ROOTFIX/gradlew"; chmod +x "$ROOTFIX/gradlew"
mk "$ROOTFIX/settings.gradle" "include 'sales:backend'"
mk "$ROOTFIX/sales/backend/build.gradle" "plugins { id 'org.springframework.boot' }
dependencies { implementation 'org.springframework.boot:spring-boot-starter-web' }"
mk "$ROOTFIX/sales/backend/src/main/resources/application.properties" "server.port=8111"
mk "$ROOTFIX/sales/frontend/package.json" '{"scripts":{"dev":"next dev -p 3111"},"dependencies":{"next":"14"}}'
mk "$ROOTFIX/sales/frontend/package-lock.json" "{}"
mk "$ROOTFIX/apis/report-api/build.gradle" "plugins { id 'org.springframework.boot' }"
# a library module: it DEPENDS on spring-boot but has no boot plugin, so it is
# not something you can start
mk "$ROOTFIX/apis/report-model/build.gradle" "dependencies { api 'org.springframework.boot:spring-boot-starter-data-mongodb' }"
# a node package with no runnable script is likewise a library
mk "$ROOTFIX/packages/ui-kit/package.json" '{"scripts":{"build":"tsc"},"name":"ui-kit"}'
# an app nested one level deeper than any hardcoded group name would reach
mk "$ROOTFIX/sso/sso-api/build.gradle" "plugins { id 'org.springframework.boot' }"
mk "$ROOTFIX/worker/go.mod" "module worker"
mk "$ROOTFIX/worker/main.go" "package main
func main() {}"
# a go module with no main package is a library, not a service
mk "$ROOTFIX/pkg/util/go.mod" "module util"
mk "$ROOTFIX/pkg/util/util.go" "package util"
# noise that must be ignored
mkdir -p "$ROOTFIX/node_modules/foo" "$ROOTFIX/build" "$ROOTFIX/docker" "$ROOTFIX/shared"
mk "$ROOTFIX/node_modules/foo/package.json" '{}'
mk "$ROOTFIX/shared/build.gradle" ""

_init_repo() { # → INITOUT, and the generated config path in GENCFG
  INITOUT=$(cmd_init --force --name fixrepo "$ROOTFIX" 2>&1)
  GENCFG=$(project_file fixrepo)
}

_load_generated() { # source the generated config the way bin/pitcrew does
  config_defaults
  ROOT=$(config_declared_root "$GENCFG")
  source "$GENCFG"
  config_finalize "$GENCFG"
}

test_detects_apps_and_ignores_noise() {
  DET_APPS=(); detect_scan "$ROOTFIX"
  local apps=" ${DET_APPS[*]} "
  assert_match "$apps" 'sales'      "app with backend+frontend"
  assert_match "$apps" 'report-api' "app inside a group directory"
  assert_match "$apps" 'worker'     "standalone app"
  assert_not_match "$apps" 'node_modules' "node_modules is not an app"
  assert_not_match "$apps" 'build'        "build output is not an app"
  assert_not_match "$apps" 'shared'       "a shared library is not an app"
  assert_match     "$apps" 'sso-api'      "an app nested deeper than any group name"
  assert_eq "${#DET_APPS[@]}" 4 "exactly four apps"
}

test_library_modules_are_not_mistaken_for_services() {
  # A Gradle monorepo has far more library modules than services. Reporting
  # every jar as an app took one real project from 7 apps to 34. The signal is
  # the boot PLUGIN — a library merely depends on spring-boot.
  DET_APPS=(); detect_scan "$ROOTFIX"
  local apps=" ${DET_APPS[*]} "
  assert_match     "$apps" 'report-api'    "the service is detected"
  assert_not_match "$apps" 'report-model'  "the library it depends on is not"
  assert_not_match "$apps" 'ui-kit'        "a node package with no run script is not"
  assert_not_match "$apps" 'util'          "a go module with no main package is not"
}

test_runnability_is_judged_per_toolchain() {
  assert_ok    _detect_runnable "$ROOTFIX/apis/report-api"   gradle
  assert_fails _detect_runnable "$ROOTFIX/apis/report-model" gradle
  assert_ok    _detect_runnable "$ROOTFIX/sales/frontend"    node
  assert_fails _detect_runnable "$ROOTFIX/packages/ui-kit"   node
}

test_roles_come_from_the_directory_layout() {
  DET_APPS=(); detect_scan "$ROOTFIX"
  assert_match "${DET_DIR[sales.be]}" 'sales/backend'  "backend role"
  assert_match "${DET_DIR[sales.fe]}" 'sales/frontend' "frontend role"
  assert_empty "${DET_DIR[report-api.fe]:-}" "a backend-only service has no frontend"
}

test_ports_are_read_from_the_project_not_invented() {
  DET_APPS=(); detect_scan "$ROOTFIX"
  _detect_kind "${DET_DIR[sales.be]}"; _detect_port "${DET_DIR[sales.be]}" "$KIND"
  assert_eq "$PORT" 8111 "spring server.port"
  _detect_kind "${DET_DIR[sales.fe]}"; _node_flavour "${DET_DIR[sales.fe]}"
  _detect_port "${DET_DIR[sales.fe]}" "$KIND"
  assert_eq "$PORT" 3111 "port pinned in the dev script"
}

test_gradle_modules_use_their_project_path() {
  DET_APPS=(); detect_scan "$ROOTFIX"
  _detect_cmd "$ROOTFIX" "${DET_DIR[sales.be]}" gradle 8111
  assert_eq "$CMD" './gradlew :sales:backend:bootRun' "gradle project path"
  _detect_cmd "$ROOTFIX" "${DET_DIR[report-api.be]}" gradle 8085
  assert_eq "$CMD" './gradlew :apis:report-api:bootRun' "nested module path"
}

test_node_commands_use_the_right_package_manager_and_script() {
  DET_APPS=(); detect_scan "$ROOTFIX"
  _node_flavour "${DET_DIR[sales.fe]}"
  _detect_cmd "$ROOTFIX" "${DET_DIR[sales.fe]}" node 3111
  assert_match "$CMD" 'npm run dev'  "picks the dev script"
  assert_match "$CMD" 'node_modules' "installs on first run"
}

test_the_generated_config_actually_loads() {
  # the whole point: init must produce something that works, not a template
  _init_repo
  _load_generated
  assert_eq "$PITCREW_PROJECT_NAME" "fixrepo" "project name"
  assert_eq "$ROOT" "$ROOTFIX" "root points at the checkout, not at the config"
  local comps=" ${PITCREW_COMPS[*]} "
  assert_match "$comps" 'be-sales'      "backend component"
  assert_match "$comps" 'fe-sales'      "frontend component"
  assert_match "$comps" 'be-report-api' "grouped service"
  assert_eq "${PITCREW_BE_PORT[sales]}" 8111 "detected port survived into the model"
  assert_eq "${PITCREW_BE_HEALTH_PATH[sales]}" "/actuator/health" "spring health path"
}

test_generated_commands_reference_the_checkout_not_the_config_dir() {
  # commands are written in terms of $ROOT and expand when the config is
  # sourced — if ROOT were the config's own directory they would all point at
  # ~/.config/pitcrew and silently run in the wrong place
  _init_repo; _load_generated
  assert_match "${PITCREW_FE_CMD[sales]}" "$ROOTFIX" "frontend command targets the checkout"
  assert_not_match "${PITCREW_FE_CMD[sales]}" 'projects' "not the config directory"
}

test_generated_ports_never_collide() {
  # pitcrew validates ports at load time, so a colliding config warns on every
  # single run. It happened because the port allocator reserved its answer
  # inside a $( ) — i.e. in a subshell, where the reservation was discarded.
  _init_repo; _load_generated
  local c port seen=" " dupes=""
  for c in "${PITCREW_COMPS[@]}"; do
    local app=${c#??-} role=${c:0:2}
    if [ "$role" = be ]; then port=${PITCREW_BE_PORT[$app]:-}; else port=${PITCREW_FE_PORT[$app]:-}; fi
    [ -n "$port" ] || continue
    case "$seen" in *" $port "*) dupes+="$port " ;; *) seen+="$port " ;; esac
  done
  assert_empty "$dupes" "ports handed out twice"
  # and loading it must produce no warnings at all
  local warn; warn=$(plain "$(config_validate 2>&1)")
  assert_empty "$warn" "config_validate is silent on a generated config"
}

test_a_project_is_registered_and_becomes_current() {
  _init_repo
  assert_match "$(project_list | tr '\n' ' ')" 'fixrepo' "listed"
  assert_eq "$(project_current)" "fixrepo" "made current"
  assert_eq "$(project_root_of fixrepo)" "$ROOTFIX" "root recorded"
}

test_a_directory_resolves_to_the_project_that_contains_it() {
  _init_repo
  assert_eq "$(project_for_dir "$ROOTFIX/sales/backend")" "fixrepo" "deep inside the checkout"
  assert_empty "$(project_for_dir /nowhere-at-all)" "outside any project"
}

test_forget_removes_the_registration_but_not_the_checkout() {
  _init_repo
  cmd_forget fixrepo >/dev/null 2>&1
  assert_empty "$(project_list | tr '\n' ' ')" "unregistered"
  assert_ok test -d "$ROOTFIX"          # the checkout itself is untouched
}

test_init_refuses_to_clobber_without_force() {
  _init_repo
  assert_fails cmd_init --name fixrepo "$ROOTFIX"
  assert_ok    cmd_init --force --name fixrepo "$ROOTFIX"
}

test_init_says_so_when_it_recognises_nothing() {
  local empty; empty=$(mktemp -d)
  local out; out=$(plain "$(cmd_init --name nothinghere "$empty" 2>&1)") || true
  assert_match "$out" 'nothing recognisable' "explains rather than writing a broken config"
  assert_fails test -f "$(project_file nothinghere)"
  rm -rf "$empty"
}

trap 'rm -rf "$FIX"' EXIT
run_tests
