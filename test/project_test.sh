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

# A Gradle build that uses a VERSION CATALOG, which is what a repo generated in
# the last few years looks like: the module says `alias(libs.plugins.spring.boot)`
# and the plugin id it stands for is declared somewhere else entirely. Both
# places are covered — a versionCatalogs block in settings.gradle.kts, and a
# gradle/libs.versions.toml.
mkdir -p "$FIX/cat" && CATFIX="$FIX/cat"
: > "$CATFIX/gradlew"; chmod +x "$CATFIX/gradlew"
mk "$CATFIX/settings.gradle.kts" 'rootProject.name = "issues"
include("backend")
dependencyResolutionManagement {
  versionCatalogs {
    create("libs") {
      plugin("kotlin-jvm", "org.jetbrains.kotlin.jvm").versionRef("kotlin")
      plugin("spring-boot", "org.springframework.boot").versionRef("spring-boot")
      plugin("jib", "com.google.cloud.tools.jib").versionRef("jib")
    }
  }
}'
# the root build file declares every plugin for its subprojects to apply, and
# applies none of them itself
mk "$CATFIX/build.gradle.kts" 'plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.spring.boot) apply false
}'
mk "$CATFIX/backend/build.gradle.kts" 'plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.spring.boot)
    alias(libs.plugins.jib)
}
dependencies {
    implementation(libs.bundles.spring.boot.starters)
}'
mk "$CATFIX/backend/src/main/resources/application.yml" 'server:
  port: 8444'
# a library module in the same build: it uses the catalog too, and applies
# nothing that could start it
mk "$CATFIX/shared-model/build.gradle.kts" 'plugins {
    alias(libs.plugins.kotlin.jvm)
}
dependencies {
    implementation(libs.bundles.spring.boot.starters)
}'

# the same thing again, with the catalog in the file Gradle documents
mkdir -p "$FIX/toml" && TOMLFIX="$FIX/toml"
: > "$TOMLFIX/gradlew"; chmod +x "$TOMLFIX/gradlew"
mk "$TOMLFIX/settings.gradle.kts" 'include("api")'
mk "$TOMLFIX/gradle/libs.versions.toml" '[versions]
boot = "3.4.1"

[plugins]
spring-boot = { id = "org.springframework.boot", version.ref = "boot" }
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }'
mk "$TOMLFIX/api/build.gradle.kts" 'plugins {
    alias(libs.plugins.spring.boot)
}'
mk "$TOMLFIX/model/build.gradle.kts" 'plugins {
    alias(libs.plugins.kotlin.jvm)
}'

_init_repo() { # → INITOUT, and the generated config path in GENCFG
  INITOUT=$(cmd_init --force --name fixrepo "$ROOTFIX" 2>&1)
  GENCFG=$(project_file fixrepo)
}

_load_generated_from() { # load a config the way bin/pitcrew does
  config_defaults
  ROOT=$(config_declared_root "$1")
  if config_is_yaml "$1"; then yaml_config_load "$1"; else source "$1"; fi
  config_finalize "$1"
}
_load_generated() { _load_generated_from "$GENCFG"; }

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

test_a_module_that_applies_its_plugins_through_a_catalog_is_still_a_service() {
  # `alias(libs.plugins.spring.boot)` is all a modern Gradle module says; the
  # id lives in the catalog. Reading only the module meant a Kotlin/Spring
  # backend was invisible — `pitcrew init` wrote a config with the frontend in
  # it and nothing to talk to, and the answer looked like "pitcrew does not
  # know what my backend is".
  DET_APPS=(); detect_scan "$CATFIX"
  local apps=" ${DET_APPS[*]} "
  assert_match     "$apps" 'backend'      "the module that applies the boot plugin"
  assert_not_match "$apps" 'shared-model' "not the library beside it"
  assert_eq "${#DET_APPS[@]}" 1 "and nothing else in the build"
}

test_a_plugin_declared_for_the_subprojects_is_not_applied_here() {
  # `apply false` in a root build file declares a plugin for the subprojects to
  # apply. The root is not a service, and a build that names every plugin that
  # way would otherwise look like the biggest one.
  assert_fails _detect_runnable "$CATFIX" gradle
  assert_ok    _detect_runnable "$CATFIX/backend" gradle
}

test_the_catalog_is_read_from_the_toml_as_well_as_the_settings_file() {
  assert_ok    _detect_runnable "$TOMLFIX/api"   gradle
  assert_fails _detect_runnable "$TOMLFIX/model" gradle
  _gradle_catalog_dir "$TOMLFIX/api"
  assert_eq "$CATDIR" "$TOMLFIX" "the catalog is found by walking up"
  _gradle_plugin_id "$TOMLFIX" "spring.boot"
  assert_eq "$PID" "org.springframework.boot" "and the alias resolves to an id"
}

test_a_catalog_spelling_of_spring_boot_still_gets_a_health_check() {
  # Through a catalog the dependency reads `libs.bundles.spring.boot.starters`,
  # so a grep for `spring-boot` found nothing and the backend lost the one
  # thing that says it is UP rather than merely running.
  _detect_health "$CATFIX/backend" gradle
  assert_eq "$HEALTH" "/actuator/health" "spelled with dots, it is still Spring Boot"
}

test_a_context_path_moves_the_health_endpoint_with_it() {
  # `server.servlet.context-path` moves every mapping the app has, the actuator
  # with them — so /actuator/health is a 404 and the real endpoint is
  # /<ctx>/actuator/health. A generated config that probed the bare path could
  # never come back UP, and the component read "starting" for as long as it was
  # left running. Both spellings, because a monorepo has both.
  local d="$FIX/ctx-props"
  mkdir -p "$d/src/main/resources"
  mk "$d/build.gradle" "dependencies { implementation 'org.springframework.boot:spring-boot-starter-web' }"
  mk "$d/src/main/resources/application.properties" 'server.port=8087
server.servlet.context-path=/report-api'
  _detect_health "$d" gradle
  assert_eq "$HEALTH" "/report-api/actuator/health" "properties form"

  local y="$FIX/ctx-yaml"
  mkdir -p "$y/src/main/resources"
  mk "$y/build.gradle" "dependencies { implementation 'org.springframework.boot:spring-boot-starter-web' }"
  mk "$y/src/main/resources/application.yml" 'server:
  port: 8082
  servlet:
    context-path: /backoffice-api   # trailing comments are not part of it

spring:
  application:
    name: backoffice'
  _detect_health "$y" gradle
  assert_eq "$HEALTH" "/backoffice-api/actuator/health" "yaml form"

  # A placeholder is resolved at runtime out of an env var we cannot read. In
  # the face of ambiguity, no health path: an open port is then what makes it
  # up, which is true, where a guessed path would be permanently false.
  local u="$FIX/ctx-unknown"
  mkdir -p "$u/src/main/resources"
  mk "$u/build.gradle" "dependencies { implementation 'org.springframework.boot:spring-boot-starter-web' }"
  mk "$u/src/main/resources/application.properties" 'server.servlet.context-path=${CTX:/api}'
  _detect_health "$u" gradle
  assert_empty "$HEALTH" "a path we cannot know is not guessed at"
}

test_a_catalog_module_keeps_its_port_and_its_gradle_path() {
  DET_APPS=(); detect_scan "$CATFIX"
  _detect_port "${DET_DIR[backend.be]}" gradle
  assert_eq "$PORT" 8444 "server.port out of application.yml"
  _detect_cmd "$CATFIX" "${DET_DIR[backend.be]}" gradle 8444
  assert_eq "$CMD" './gradlew :backend:bootRun' "and the module's project path"
}

test_detect_prints_the_guess_and_writes_nothing() {
  # `pitcrew detect` is init's first half without its second. It exists for
  # somebody deciding whether init would get their project right — and for the
  # desktop app, whose "add an app" list is this JSON. One guess, one place.
  local out; out=$(cmd_detect --json "$CATFIX")
  assert_match "$out" '"name":"backend"'                        "the app"
  assert_match "$out" '"cmd":"\./gradlew :backend:bootRun"'      "with the command it would write"
  assert_match "$out" '"port":8444'                             "the port it found"
  assert_match "$out" '"health":"/actuator/health"'             "and the health path"
  [ -e "$CATFIX/pitcrew.yaml" ] && _t_bad "detect wrote a config"
  if command -v python3 >/dev/null 2>&1; then
    assert_ok python3 -c 'import json,sys; json.load(sys.stdin)' <<< "$out"
  fi
}

test_detect_says_so_when_it_recognises_nothing() {
  local empty; empty=$(mktemp -d)
  assert_fails cmd_detect "$empty"
  rm -rf "$empty"
}

test_detect_and_init_agree_about_a_project() {
  # Two code paths that guess differently would be worse than no detect
  # command at all: the app would offer a component that init never writes.
  local json; json=$(cmd_detect --json "$ROOTFIX")
  _init_repo
  local generated; generated=$(cat "$GENCFG")
  assert_match "$json"      'gradlew :sales:backend:bootRun' "detect says the gradle path"
  assert_match "$generated" 'gradlew :sales:backend:bootRun' "and so does the file init writes"
  assert_match "$json"      '"port":8111' "detect reads the pinned port"
  assert_match "$generated" '8111'        "and init writes it"
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
  assert_eq "${PITCREW_PORT[be-sales]}" 8111 "detected port survived into the model"
  assert_eq "${PITCREW_HEALTH[be-sales]}" "/actuator/health" "spring health path"
}

test_generated_commands_reference_the_checkout_not_the_config_dir() {
  # commands are written in terms of $ROOT and expand when the config is
  # sourced — if ROOT were the config's own directory they would all point at
  # ~/.config/pitcrew and silently run in the wrong place
  _init_repo; _load_generated
  assert_match "${PITCREW_CMD[fe-sales]}" "$ROOTFIX" "frontend command targets the checkout"
  assert_not_match "${PITCREW_CMD[fe-sales]}" 'projects' "not the config directory"
}

test_generated_ports_never_collide() {
  # pitcrew validates ports at load time, so a colliding config warns on every
  # single run. It happened because the port allocator reserved its answer
  # inside a $( ) — i.e. in a subshell, where the reservation was discarded.
  _init_repo; _load_generated
  local c port seen=" " dupes=""
  for c in "${PITCREW_COMPS[@]}"; do
    local app=${c#*-} role=${c%%-*}
    port=${PITCREW_PORT[$c]:-}
    [ -n "$port" ] || continue
    case "$seen" in *" $port "*) dupes+="$port " ;; *) seen+="$port " ;; esac
  done
  assert_empty "$dupes" "ports handed out twice"
  # and loading it must produce no warnings at all
  local warn; warn=$(plain "$(config_validate 2>&1)")
  assert_empty "$warn" "config_validate is silent on a generated config"
}

test_a_repo_with_its_own_config_is_registered_as_a_pointer() {
  # Re-detecting a repo that already ships a config would produce a second,
  # worse copy that drifts from the real one — and the in-project file wins at
  # resolution time anyway, so the copy would never even be read.
  mk "$ROOTFIX/pitcrew.config.sh" 'PITCREW_PROJECT_NAME="handwritten"
PITCREW_APPS=(only)
pitcrew_app only --be-cmd "true" --be-port 19999'
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  local gen; gen=$(project_file fixrepo)
  assert_match "$(cat "$gen")" 'source "\$PITCREW_ROOT/pitcrew.config.sh"' "points at the repo's own config"
  assert_not_match "$(cat "$gen")" 'pitcrew_app' "does not copy the model"

  # and resolving through the registry entry yields the repo's model
  _load_generated_from "$gen"
  assert_eq "$PITCREW_PROJECT_NAME" "handwritten" "the repo's config is what loads"
  assert_eq "${PITCREW_PORT[be-only]}" 19999 "with its own values"

  # --detect overrides, for when you do want a fresh look. It writes the
  # current format, and replaces the pointer entry rather than sitting next to
  # it — two registry files for one project means editing the wrong one.
  cmd_init --force --detect --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  gen=$(project_file fixrepo)
  assert_match "$gen" '\.yaml$' "--detect writes the YAML format"
  assert_match "$(cat "$gen")" 'apps:' "--detect regenerates instead"
  assert_eq "$(project_list | tr '\n' ' ')" "fixrepo " "one registry entry, not two"
  rm -f "$ROOTFIX/pitcrew.config.sh"
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1
}

test_a_repo_shipping_a_yaml_config_is_registered_as_a_working_pointer() {
  # The stub used to be written with `root:` before `include:`, which the loader
  # refuses (include has to be the first key) — so every YAML pointer entry
  # pitcrew wrote was unloadable. Checking the file's CONTENT missed it
  # entirely; only loading it finds this class of bug.
  mk "$ROOTFIX/pitcrew.yaml" 'name: shipped
apps:
  only:
    be:
      cmd: "true"
      port: 19998'
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  local gen; gen=$(project_file fixrepo)
  assert_match "$gen" '\.yaml$' "a yaml repo gets a yaml entry"
  _load_generated_from "$gen"
  assert_eq "$PITCREW_PROJECT_NAME" "shipped" "and it resolves into the repo's own config"
  assert_eq "${PITCREW_PORT[be-only]}" 19998 "with its values"
  assert_eq "$ROOT" "$ROOTFIX" "and the right root"
  rm -f "$ROOTFIX/pitcrew.yaml"
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1
}

test_edit_opens_the_file_that_actually_holds_the_config() {
  # A registry entry for a repo that ships its own config only records the root
  # and points at it. Opening the stub would put you in a two-line file, let you
  # edit it, and change nothing the tool reads. The GUI has always followed this
  # indirection; the CLI opened the stub.
  mk "$ROOTFIX/pitcrew.config.sh" 'PITCREW_APPS=(only)
pitcrew_app only --be-cmd "true"'
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  assert_eq "$(project_content_file fixrepo)" "$ROOTFIX/pitcrew.config.sh" "bash: through the source"
  rm -f "$ROOTFIX/pitcrew.config.sh"

  mk "$ROOTFIX/pitcrew.yaml" 'name: shipped
apps:
  only:
    be:
      cmd: "true"'
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  assert_eq "$(project_content_file fixrepo)" "$ROOTFIX/pitcrew.yaml" "yaml: through the include"
  rm -f "$ROOTFIX/pitcrew.yaml"

  # A self-contained entry is edited where it lives, not chased anywhere.
  cmd_init --force --detect --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  assert_eq "$(project_content_file fixrepo)" "$(project_file fixrepo)" "detected: itself"
}

test_switching_project_re_execs_into_the_same_view() {
  # It cannot be done by re-sourcing: a config's bare `declare -A` would be
  # scoped to the function that sourced it and silently discarded, leaving the
  # dashboard showing one project's components with another's ports.
  ( SELF=/bin/echo
    PITCREW_CMD=logs
    printf 'root: /tmp\n' > "$PROJECTS_DIR/other.yaml"
    fzf() { echo other; }
    local out; out=$(switch_project)
    assert_match "$out" '\-p other logs' "re-execs into the picked project, same view"
    assert_eq "$(project_current)" "other" "and the choice persists"
    rm -f "$PROJECTS_DIR/other.yaml" )
}

test_cancelling_the_project_picker_switches_nothing() {
  ( SELF=/bin/echo
    printf 'root: /tmp\n' > "$PROJECTS_DIR/other.yaml"
    local before; before=$(project_current || echo none)
    fzf() { return 1; }
    local out; out=$(switch_project)
    assert_not_match "$out" '\-p other' "no re-exec"
    assert_eq "$(project_current || echo none)" "$before" "current project unchanged"
    rm -f "$PROJECTS_DIR/other.yaml" )
}

test_the_picker_preview_describes_a_project() {
  _init_repo
  local info; info=$(plain "$(project_info fixrepo)")
  assert_match "$info" 'fixrepo'  "names it"
  assert_match "$info" "$ROOTFIX" "shows where it lives"
  assert_match "$info" 'apps'     "and how many apps it has"
}

test_port_clashes_between_projects_are_found() {
  _init_repo                                     # fixrepo: sales be 8111, fe 3111
  # deliberately the OLD bash format: the two must interoperate in one registry
  local other="$PROJECTS_DIR/rival.sh"
  printf 'PITCREW_ROOT=%s\nPITCREW_APPS=(thing)\npitcrew_app thing --be-cmd "true" --be-port 8111\n' \
    "$ROOTFIX" > "$other"
  local hits; hits=$(port_conflicts fixrepo)
  assert_match "$hits" '8111'   "the shared port"
  assert_match "$hits" 'rival'  "and who else claims it"
  assert_not_match "$hits" '3111' "a port only one project uses is not a clash"
  rm -f "$other"
  assert_empty "$(port_conflicts fixrepo)" "no clash once the other project is gone"
}

test_a_project_is_registered_and_becomes_current() {
  _init_repo
  assert_match "$(project_list | tr '\n' ' ')" 'fixrepo' "listed"
  assert_eq "$(project_current)" "fixrepo" "made current"
  assert_eq "$(project_root_of fixrepo)" "$ROOTFIX" "root recorded"
}

test_the_registry_can_be_read_as_data() {
  command -v python3 >/dev/null 2>&1 || return 0
  # The desktop app was showing a name and a path while `pitcrew projects`
  # already knew how much was running and `pitcrew ports` knew about clashes.
  # There was no structured way to ask, so the GUI was worse than the CLI at
  # the one thing the tool sells: several projects on one machine.
  _init_repo
  local rival="$PROJECTS_DIR/rival.sh"
  printf 'PITCREW_ROOT=%s\nPITCREW_APPS=(thing)\npitcrew_app thing --be-cmd "true" --be-port 8111\n' \
    "$ROOTFIX" > "$rival"

  local out; out=$(cmd_projects --json)
  printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    || { _t_bad "projects --json is not valid JSON"; rm -f "$rival"; return; }

  local got; got=$(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
p = {x["name"]: x for x in d["projects"]}
f = p["fixrepo"]
print(" ".join(sorted(p)))
print(" ".join(sorted(f)))
print(f["exists"], f["current"])
print(sorted(x["port"] for x in f["ports"]))
print([c["project"] for c in f["clashes"]])')
  assert_eq "$(printf '%s' "$got" | sed -n 1p)" "fixrepo rival" "every registered project"
  assert_eq "$(printf '%s' "$got" | sed -n 2p)" \
    "clashes current exists name ports root running" "the fields a UI needs"
  assert_eq "$(printf '%s' "$got" | sed -n 3p)" "True True" "the checkout is there, and it is current"
  assert_match "$(printf '%s' "$got" | sed -n 4p)" '8111' "the ports it claims"
  assert_match "$(printf '%s' "$got" | sed -n 5p)" 'rival' "and who else claims one of them"
  rm -f "$rival"
}

test_a_registry_entry_pointing_at_a_deleted_checkout_says_so() {
  command -v python3 >/dev/null 2>&1 || return 0
  # A path that is gone is the commonest stale-registry state, and a UI that
  # renders it like any other project sends you hunting.
  local gone; gone=$(mktemp -d); rmdir "$gone"
  printf 'root: %s\nname: ghost\n' "$gone" > "$PROJECTS_DIR/ghost.yaml"
  local got; got=$(cmd_projects --json | python3 -c '
import json, sys
g = {x["name"]: x for x in json.load(sys.stdin)["projects"]}["ghost"]
print(g["exists"], g["running"])')
  assert_eq "$got" "False 0" "reported as missing, not as idle"
  rm -f "$PROJECTS_DIR/ghost.yaml"
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

test_init_writes_yaml_by_default_and_bash_when_asked() {
  _init_repo
  assert_match "$GENCFG" '\.yaml$' "the default format"
  assert_match "$(cat "$GENCFG")" 'apps:' "and it is YAML"
  cmd_init --force --sh --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  local gen; gen=$(project_file fixrepo)
  assert_match "$gen" '\.sh$' "--sh still writes the bash format"
  assert_match "$(cat "$gen")" 'pitcrew_app' "and it is bash"
  _load_generated_from "$gen"
  assert_eq "${PITCREW_PORT[be-sales]}" 8111 "which still loads"
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1   # back to the default
}

test_the_two_formats_describe_the_same_project() {
  # The YAML front end is not a second model, it is a second way of writing the
  # one model. If the two ever disagree, everything downstream is a coin-flip.
  _init_repo; _load_generated
  local yaml_comps="${PITCREW_COMPS[*]}" yaml_port="${PITCREW_PORT[be-sales]}"
  local yaml_health="${PITCREW_HEALTH[be-sales]}"
  cmd_init --force --sh --name fixrepo "$ROOTFIX" >/dev/null 2>&1
  _load_generated_from "$(project_file fixrepo)"
  assert_eq "${PITCREW_COMPS[*]}"              "$yaml_comps"  "same components"
  assert_eq "${PITCREW_PORT[be-sales]}"        "$yaml_port"   "same ports"
  assert_eq "${PITCREW_HEALTH[be-sales]}" "$yaml_health" "same health path"
  cmd_init --force --name fixrepo "$ROOTFIX" >/dev/null 2>&1
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
