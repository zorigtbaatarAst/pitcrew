#!/usr/bin/env bash
# `pitcrew migrate` — a pitcrew.config.sh, rewritten as the YAML that means the
# same thing.
#
# The bash format is not deprecated and never will be: a config that has to
# branch on the machine it runs on needs a shell. But the ones people actually
# have look like
#
#   for _app in "${PITCREW_APPS[@]}"; do pitcrew_app "$_app" --be-port … ; done
#
# which is compact to write, unreadable to anyone asking what port sales is on,
# and impossible to edit as a form. By the time this runs pitcrew has already
# executed that loop, so the conversion is a matter of writing out the model.
#
# The property that matters most is the CHECK: the generated file is loaded and
# its model compared, field by field, against the one in memory. A migration
# that silently changed a port would be worse than not offering one.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

# A project with a config in the shape real ones take: a loop, per-app port
# maps, $ROOT in the paths, and settings scattered across the globals.
_looped_project() {
  PROJ=$(mktemp -d)
  cat > "$PROJ/pitcrew.config.sh" <<'SH'
PITCREW_PROJECT_NAME="Autoland"
PITCREW_EMOJI="🚗"
PITCREW_APPS=(sales finance)
declare -A _BE=([sales]=8082 [finance]=8083)
declare -A _FE=([sales]=3002 [finance]=3003)
for _app in "${PITCREW_APPS[@]}"; do
  pitcrew_app "$_app" \
    --be-cmd    "./gradlew :$_app:backend:bootRun" \
    --fe-cmd    "cd $ROOT/$_app/frontend && npm run dev" \
    --be-port   "${_BE[$_app]}" \
    --fe-port   "${_FE[$_app]}" \
    --url-path  "/$_app-api" \
    --be-health "/$_app-api/actuator/health" \
    --watch-be  "$ROOT/$_app/backend/src $ROOT/shared"
done
PITCREW_DEPS=(autoland-db autoland-redis)
PITCREW_PROTECTED_DEPS=(autoland-db)
PITCREW_BE_ENV="JAVA_HOME=$HOME/.sdkman/candidates/java/current"
PITCREW_BE_MAX=6G
PITCREW_SHELLS=([db]="docker exec -it autoland-db psql -U postgres autoland")
SH
  _load_project "$PROJ/pitcrew.config.sh"
}

_load_project() { # $1 config file — the same sequence bin/pitcrew uses
  config_defaults
  ROOT=$(dirname "$1"); PITCREW_ROOT=$ROOT
  if config_is_yaml "$1"; then yaml_config_load "$1" >/dev/null 2>&1
  else source "$1"; fi
  config_finalize "$1" >/dev/null 2>&1
}

_cleanup() { [ -n "${PROJ:-}" ] && rm -rf "$PROJ"; PROJ=""; }

# ── what it writes ──────────────────────────────────────────────────────────

test_a_loop_becomes_one_block_per_app() {
  _looped_project
  local out; out=$(cmd_migrate --print)
  # (^|\n) rather than ^ — bash's =~ has no multiline flag, so ^ anchors to
  # the start of the whole string and would only ever match the first line.
  assert_match "$out" $'(^|\n)  sales:'   "the loop is gone and the apps are written out"
  assert_match "$out" $'(^|\n)  finance:' "all of them"
  assert_match "$out" 'port: 8082'  "with the values it computed"
  assert_match "$out" 'port: 3003'
  assert_not_match "$out" 'for _app' "no shell survives into the YAML"
  _cleanup
}

test_a_cd_in_front_of_a_command_becomes_a_dir() {
  # That is what `dir:` is for, and pulling it back out is most of what makes
  # the result readable — one line instead of an absolute path in front of
  # every command.
  _looped_project
  local out; out=$(cmd_migrate --print)
  assert_match "$out" $'(^|\n)      dir: sales/frontend' "the directory, relative to the root"
  assert_match "$out" $'(^|\n)      cmd: npm run dev'       "and the command without it"
  _cleanup
}

test_one_laptops_absolute_paths_do_not_end_up_in_the_file() {
  # A .sh config expands "$ROOT/x" when it is sourced, so the model holds
  # absolute paths. A config full of those is not one you can commit.
  _looped_project
  local out; out=$(cmd_migrate --print)
  assert_not_match "$out" "$PROJ" "no trace of where this checkout happens to be"
  assert_match "$out" 'JAVA_HOME=\$HOME/' "\$HOME is written back as \$HOME"
  assert_match "$out" 'watch: \[sales/backend/src, shared\]' "watch dirs are relative again"
  _cleanup
}

test_values_are_quoted_only_where_leaving_them_bare_would_change_them() {
  # A generated config is one somebody has to read. `name: "Autoland"`,
  # `max: "6G"`, `port: "8082"` are quotes nobody would have typed.
  _looped_project
  local out; out=$(cmd_migrate --print)
  assert_match "$out" $'(^|\n)name: Autoland(\n|$)'  "a plain name stays plain"
  assert_match "$out" $'(^|\n)  be: 6G(\n|$)'        "and so does a size"
  assert_match "$out" 'deps: \[autoland-db, autoland-redis\]' "a list reads as a list"
  _cleanup
}

# ── the check ───────────────────────────────────────────────────────────────

test_the_result_is_loaded_and_compared_before_anything_is_written() {
  _looped_project
  local before; before=$(migrate_fingerprint)
  cmd_migrate >/dev/null 2>&1

  # Load what it wrote, in this shell, and compare what it MEANS.
  _load_project "$PROJ/pitcrew.yaml"
  local after; after=$(migrate_fingerprint)
  assert_eq "$after" "$before" "the YAML means exactly what the .sh meant"
  _cleanup
}

test_a_difference_stops_the_write_rather_than_being_reported_afterwards() {
  # The whole value of the check is that it happens BEFORE the file exists.
  _looped_project
  local out
  out=$( migrate_render() { printf 'apps:\n  wrong:\n    be:\n      cmd: "true"\n'; }
         cmd_migrate 2>&1 )
  assert_match "$(plain "$out")" 'does not mean the same thing' "it says so"
  assert_match "$(plain "$out")" 'nothing was written'          "and stops"
  [ -e "$PROJ/pitcrew.yaml" ] && _t_bad "a file was written despite the mismatch"
  _cleanup
}

test_the_watch_default_the_conversion_adds_is_reported_not_swallowed() {
  # A .sh config open-codes `cd <dir> && …` and watches only what --watch-be
  # named. In YAML that `cd` becomes `dir:`, and a component with a dir and no
  # watch of its own watches where it runs — so a frontend that watched nothing
  # now watches its own folder. Better, and still a change to what
  # `pitcrew stale` reports, so it has to be said rather than either swallowed
  # or treated as a corrupted conversion.
  _looped_project
  local out; out=$(cmd_migrate 2>&1)
  assert_match "$(plain "$out")" 'will watch a little more' "the change is named"
  assert_match "$(plain "$out")" 'fe-sales'                 "and so is what changed"
  assert_match "$(plain "$out")" 'wrote '                   "and it still converts"
  _cleanup
}

test_the_cd_quoting_the_two_loaders_use_is_not_treated_as_a_difference() {
  # A .sh config produces `cd /path && …` and the YAML loader produces
  # `cd '/path' && …`. They run identically. A check that failed on two quotes
  # would only teach people to pass --force.
  _looped_project
  local out; out=$(cmd_migrate 2>&1)
  assert_match "$(plain "$out")" 'exactly the same model' "it converts cleanly"
  _cleanup
}

# ── the pointer at the config ───────────────────────────────────────────────
#
# Converting the file is half the job. `pitcrew -p demo` resolves through the
# registry, and the entry `pitcrew init` writes for a repo that ships its own
# config names pitcrew.config.sh in a `source` line — so a conversion that
# left it alone wrote a file that nothing, including the desktop app, ever
# read again.

_registered_pointer() { # the entry `pitcrew init` writes for a repo with its own config
  mkdir -p "$PROJECTS_DIR"
  {
    printf 'PITCREW_ROOT=%s\n' "$PROJ"
    printf '# shellcheck source=/dev/null\n'
    printf 'source "$PITCREW_ROOT/pitcrew.config.sh"\n'
  } > "$PROJECTS_DIR/demo.sh"
}

test_the_registry_entry_moves_with_the_file_it_points_at() {
  _looped_project
  _registered_pointer
  local out; out=$(cmd_migrate 2>&1)
  assert_match "$(plain "$out")" 'points at it now' "the repoint is said, not done quietly"
  assert_match "$(cat "$PROJECTS_DIR/demo.yaml" 2>/dev/null)" 'include: pitcrew.yaml' \
    "the entry points at what was written"
  assert_match "$(cat "$PROJECTS_DIR/demo.yaml" 2>/dev/null)" "root: $PROJ" \
    "at the same checkout as before"
  [ -e "$PROJECTS_DIR/demo.sh" ] && _t_bad "the old pointer was left behind to be edited"
  # The whole point: the file worth editing is the new one, which is what
  # `pitcrew edit` opens and what the desktop app resolves.
  assert_eq "$(project_content_file demo)" "$PROJ/pitcrew.yaml" \
    "and -p demo reads the YAML now"
  rm -f "$PROJECTS_DIR"/demo.*
  _cleanup
}

test_a_registry_entry_that_is_itself_a_config_is_reported_not_rewritten() {
  # An entry that HOLDS a config rather than pointing at one is somebody's own
  # file. migrate leaves those alone — and says which file is still being read,
  # because the alternative is a conversion that looks like it worked.
  _looped_project
  mkdir -p "$PROJECTS_DIR"
  {
    printf 'PITCREW_ROOT=%s\n' "$PROJ"
    printf 'PITCREW_APPS=(sales)\n'
  } > "$PROJECTS_DIR/demo.sh"
  local out; out=$(cmd_migrate 2>&1)
  assert_match "$(plain "$out")" 'still loads that one' "what is still read is named"
  assert_match "$(plain "$out")" 'pitcrew init'         "and how to change that"
  [ -e "$PROJECTS_DIR/demo.yaml" ] && _t_bad "an entry that was not a pointer was rewritten"
  assert_match "$(cat "$PROJECTS_DIR/demo.sh")" 'PITCREW_APPS' "the entry is untouched"
  rm -f "$PROJECTS_DIR"/demo.*
  _cleanup
}

test_an_unregistered_project_is_converted_without_inventing_an_entry() {
  # A config found by walking up from a directory is not registered at all,
  # and pitcrew already prefers the YAML there. Nothing to repoint.
  _looped_project
  cmd_migrate >/dev/null 2>&1
  assert_empty "$(ls "$PROJECTS_DIR" 2>/dev/null)" "the registry is left alone"
  _cleanup
}

# ── the edges ───────────────────────────────────────────────────────────────

test_it_refuses_to_convert_a_config_that_is_already_yaml() {
  PROJ=$(mktemp -d)
  printf 'apps:\n  a:\n    be:\n      cmd: "true"\n' > "$PROJ/pitcrew.yaml"
  _load_project "$PROJ/pitcrew.yaml"
  assert_fails cmd_migrate
  _cleanup
}

test_it_will_not_overwrite_without_being_told_to() {
  _looped_project
  printf '# mine\n' > "$PROJ/pitcrew.yaml"
  assert_fails cmd_migrate
  assert_eq "$(cat "$PROJ/pitcrew.yaml")" "# mine" "the existing file is untouched"
  cmd_migrate --force >/dev/null 2>&1
  assert_match "$(cat "$PROJ/pitcrew.yaml")" 'sales' "--force is how you say yes"
  _cleanup
}

test_what_yaml_cannot_carry_is_said_before_anything_is_written() {
  # A doctor hook is a shell FUNCTION. There is no YAML for that, and the
  # honest answer is to name it rather than drop it quietly.
  _looped_project
  pitcrew_doctor_extra() { :; }
  local out; out=$(migrate_warnings)
  assert_match "$out" 'pitcrew_doctor_extra' "the function is named"
  assert_match "$out" 'doctor:' "and so is what to replace it with"
  unset -f pitcrew_doctor_extra
  _cleanup
}

test_both_formats_in_one_directory_do_not_break_every_command() {
  # migrate leaves the .sh in place, so this is the state every converted
  # project sits in until somebody deletes it. The "reading one, ignoring the
  # other" warning used to go to STDOUT — which is where the caller reads the
  # config PATH from, so the warning became part of the filename and pitcrew
  # died on a path with a ⚠ in it.
  _looped_project
  cmd_migrate >/dev/null 2>&1
  local found; found=$(_walk_up_for_config "$PROJ" 2>/dev/null)
  assert_eq "$found" "$PROJ/pitcrew.yaml" "the path is a path, and the YAML wins"
  _cleanup
}

run_tests
