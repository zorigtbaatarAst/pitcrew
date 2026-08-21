#!/usr/bin/env bash
# The YAML config front end: the parser subset, the schema it maps onto, and —
# most importantly — that it refuses what it does not implement instead of
# guessing. A partial YAML parser that silently misreads a start command is
# worse than no YAML support at all.
set -u
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_pitcrew

YFIX="$PITCREW_DIR/test/fixture-yaml/pitcrew.yaml"

_load() { # $1 = yaml text → loads it, warnings on stdout
  local dir; dir=$(mktemp -d)
  printf '%s\n' "$1" > "$dir/pitcrew.yaml"
  config_defaults
  ROOT=$dir
  YCFG="$dir/pitcrew.yaml"
  yaml_config_load "$YCFG" 2>&1
  rm -rf "$dir"
}

_warnings() { plain "$(_load "$1")"; }

# die() exits, so anything expected to be fatal has to run in a subshell —
# assert_fails already provides one.
_rejects() { # $1 yaml text
  local dir; dir=$(mktemp -d)
  printf '%s\n' "$1" > "$dir/pitcrew.yaml"
  ( config_defaults; ROOT=$dir; yaml_config_load "$dir/pitcrew.yaml" ) >/dev/null 2>&1
  local rc=$?
  rm -rf "$dir"
  return $rc
}

# ── the fixture, which is the schema exercised end to end ──────────────────
_load_fixture() {
  config_defaults
  ROOT=$PITCREW_DIR/test/fixture-yaml
  yaml_config_load "$YFIX" >/dev/null 2>&1
}

test_apps_keep_the_order_they_are_written_in() {
  _load_fixture
  assert_eq "${PITCREW_APPS[*]}" "both beonly feonly" "document order is app order"
}

test_a_role_exists_only_when_it_has_a_command() {
  _load_fixture
  assert_ok    app_has_role both   be
  assert_ok    app_has_role both   fe
  assert_ok    app_has_role beonly be
  assert_fails app_has_role beonly fe
  assert_fails app_has_role feonly be
}

test_ports_health_and_url_path_land_where_the_model_wants_them() {
  _load_fixture
  assert_eq "${PITCREW_BE_PORT[both]}"        19801     "backend port"
  assert_eq "${PITCREW_FE_PORT[both]}"        19802     "frontend port"
  assert_eq "${PITCREW_BE_HEALTH_PATH[both]}" "/health" "health path"
  assert_eq "${PITCREW_URL_PATH[both]}"       "/api"    "url path"
}

test_dir_becomes_a_cd_in_front_of_the_command() {
  # `dir:` exists because every hand-written config repeated the same
  # "cd there && run this" and got the quoting subtly wrong on paths with
  # spaces in them.
  _load_fixture
  assert_match "${PITCREW_BE_CMD[beonly]}" "^cd '.*/services/beonly' && true$" "dir folded in, quoted"
  assert_eq    "${PITCREW_BE_CMD[both]}"   "true" "no dir means no cd"
}

test_a_role_with_a_dir_and_no_watch_watches_where_it_runs() {
  _load_fixture
  assert_match "${PITCREW_WATCH_DIR[be-beonly]}" 'services/beonly$' "watch defaults to dir"
}

test_relative_watch_dirs_resolve_against_the_root() {
  # a config full of absolute paths is a config that only works on one laptop
  _load_fixture
  assert_eq "${PITCREW_WATCH_DIR[be-both]}" "$ROOT/src/be" "single dir"
  assert_eq "${PITCREW_WATCH_DIR[fe-both]}" "$ROOT/src/fe $ROOT/src/shared" "a list joins with spaces"
}

test_lists_work_in_both_block_and_flow_style() {
  _load_fixture
  assert_eq "${PITCREW_DEPS[*]}"           "fixture-db fixture-cache" "flow: [a, b]"
  assert_eq "${PITCREW_PROTECTED_DEPS[*]}" "fixture-db"               "block: - a"
}

test_a_folded_block_scalar_becomes_one_line() {
  _load_fixture
  assert_eq "${PITCREW_FE_CMD[feonly]}" "true --folded" ">- folds newlines into spaces"
}

test_an_inline_comment_after_a_quoted_value_is_not_part_of_it() {
  # `db: "echo db"   # a comment` used to become the whole tail — i.e. a
  # different command than the one written.
  _load_fixture
  assert_eq "${PITCREW_SHELLS[db]}" "echo db" "comment stripped, value intact"
}

test_display_settings_reach_the_dashboard_globals() {
  _load_fixture
  assert_eq "$PITCREW_THEME"         "mono"        "theme"
  assert_eq "$PITCREW_ERROR_PATTERN" "BOOM|KABOOM" "single-quoted pattern kept verbatim"
}

test_doctor_checks_become_the_hook_the_rest_of_the_tool_calls() {
  _load_fixture
  assert_ok declare -F pitcrew_doctor_extra
  assert_eq "${YAML_DOCTOR_NAME[0]}" "bash is present" "the label"
  assert_eq "${YAML_DOCTOR_CMD[0]}"  "command -v bash" "the command"
}

test_a_role_can_be_marked_protected() {
  _load 'apps:
  api:
    be:
      cmd: "true"
      port: 1
      protected: true
    fe:
      cmd: "true"
      port: 2' >/dev/null
  assert_eq "${PITCREW_PROTECTED[be-api]:-}" "1" "the backend is protected"
  assert_empty "${PITCREW_PROTECTED[fe-api]:-}" "the frontend is not — it is per role, not per app"
}

test_a_protected_value_that_is_not_a_yes_or_no_is_reported() {
  # A config that meant to protect something and quietly did not is the exact
  # failure this format exists to prevent.
  local out; out=$(_warnings 'apps:
  api:
    be:
      cmd: "true"
      protected: maybe')
  assert_match "$out" "is not a yes/no value" "says so"
  assert_empty "${PITCREW_PROTECTED[be-api]:-}" "and does not guess yes"
}

test_protected_accepts_the_spellings_people_actually_write() {
  local word
  for word in true yes on 1; do
    _load "apps:
  api:
    be:
      cmd: \"true\"
      protected: $word" >/dev/null
    assert_eq "${PITCREW_PROTECTED[be-api]:-}" "1" "$word means protected"
  done
  for word in false no off 0; do
    _load "apps:
  api:
    be:
      cmd: \"true\"
      protected: $word" >/dev/null
    assert_empty "${PITCREW_PROTECTED[be-api]:-}" "$word does not"
  done
}

# ── $ROOT expansion ────────────────────────────────────────────────────────
test_root_and_home_expand_and_nothing_else_does() {
  _load 'apps:
  a:
    be:
      cmd: cd $ROOT/x && JAVA=$JAVA_HOME ${NOT_ME} run
      port: 1' >/dev/null
  assert_match "${PITCREW_BE_CMD[a]}" "^cd $ROOT/x && " "\$ROOT expands at load time"
  assert_match "${PITCREW_BE_CMD[a]}" 'JAVA=\$JAVA_HOME' "other variables reach the shell untouched"
  assert_match "${PITCREW_BE_CMD[a]}" '\$\{NOT_ME\}' "including braced ones"
}

test_a_variable_that_merely_starts_with_root_is_left_alone() {
  _load 'apps:
  a:
    be:
      cmd: echo $ROOTLESS
      port: 1' >/dev/null
  assert_eq "${PITCREW_BE_CMD[a]}" 'echo $ROOTLESS' "prefix match is not a match"
}

# ── typos warn, they do not die ────────────────────────────────────────────
test_an_unknown_key_is_reported_with_its_path() {
  local out; out=$(_warnings 'apps:
  a:
    be:
      cmd: "true"
      prot: 8080')
  assert_match "$out" "unknown key 'apps.a.be.prot'" "the exact path, not just 'bad config'"
}

test_an_unknown_top_level_key_is_reported() {
  assert_match "$(_warnings 'wiat: 30')" "unknown key 'wiat'" "top-level typo"
}

test_an_unknown_dashboard_setting_is_reported() {
  assert_match "$(_warnings 'dashboard:
  thmee: mono')" "unknown dashboard setting 'thmee'" "allowlisted, so a typo is visible"
}

test_a_frontend_health_path_says_why_it_is_ignored() {
  assert_match "$(_warnings 'apps:
  a:
    fe:
      cmd: "true"
      health: /health')" 'backend-only' "explains rather than silently dropping it"
}

test_a_key_written_twice_says_which_one_wins() {
  assert_match "$(_warnings 'name: one
name: two')" "is set twice" "duplicate key"
}

# ── what it refuses ────────────────────────────────────────────────────────
test_tabs_for_indentation_are_rejected() {
  assert_fails _rejects "$(printf 'apps:\n\ta:\n\t  be:\n\t    cmd: x\n')"
}

test_flow_mappings_are_rejected_rather_than_half_parsed() {
  assert_fails _rejects 'apps:
  a:
    be: {cmd: "true", port: 8080}'
}

test_a_list_of_mappings_is_rejected() {
  assert_fails _rejects 'apps:
  - name: a
    cmd: "true"'
}

test_anchors_are_rejected() {
  assert_fails _rejects 'base: &b "true"
name: *b'
}

test_a_missing_space_after_the_colon_is_rejected() {
  assert_fails _rejects 'name:fixture'
}

test_an_app_name_with_a_dot_is_rejected() {
  # the parser addresses values by dotted path, and an app name is also a
  # component name, a log file name and a systemd unit name
  assert_fails _rejects 'apps:
  my.app:
    be:
      cmd: "true"'
}

test_an_unterminated_quote_is_rejected() {
  assert_fails _rejects 'name: "unclosed'
}

# ── include ────────────────────────────────────────────────────────────────
test_include_pulls_in_another_config_and_later_keys_override_it() {
  local dir; dir=$(mktemp -d)
  printf 'name: base\napps:\n  a:\n    be:\n      cmd: "true"\n      port: 1\n' > "$dir/base.yaml"
  printf 'include: base.yaml\nname: override\n' > "$dir/pitcrew.yaml"
  config_defaults
  ROOT=$dir
  yaml_config_load "$dir/pitcrew.yaml" >/dev/null 2>&1
  assert_eq "${PITCREW_APPS[*]}"        "a"        "the included app is there"
  assert_eq "${PITCREW_BE_PORT[a]}"     "1"        "with its values"
  assert_eq "$PITCREW_PROJECT_NAME"     "override" "and the includer wins on conflicts"
  rm -rf "$dir"
}

test_include_must_come_first() {
  local dir; dir=$(mktemp -d)
  printf 'name: base\n' > "$dir/base.yaml"
  printf 'name: x\ninclude: base.yaml\n' > "$dir/pitcrew.yaml"
  ( config_defaults; ROOT=$dir; yaml_config_load "$dir/pitcrew.yaml" ) >/dev/null 2>&1
  assert_ne "$?" "0" "a later include would silently reorder overrides"
  rm -rf "$dir"
}

# ── the two formats are one model ──────────────────────────────────────────
test_config_resolution_prefers_yaml_and_says_so() {
  local dir; dir=$(mktemp -d)
  printf 'name: y\n'          > "$dir/pitcrew.yaml"
  printf 'PITCREW_APPS=(a)\n' > "$dir/pitcrew.config.sh"
  local out; out=$(plain "$(_walk_up_for_config "$dir" 2>&1)")
  assert_match "$out" 'pitcrew.yaml' "yaml wins"
  assert_match "$out" 'ignoring pitcrew.config.sh' "and the other one is not silently dropped"
  rm -rf "$dir"
}

test_the_declared_root_is_readable_without_loading_the_file() {
  # ROOT has to be known BEFORE the config is read, in both formats
  local dir; dir=$(mktemp -d)
  mkdir -p "$dir/checkout"
  printf 'root: %s/checkout\nname: x\n' "$dir" > "$dir/pitcrew.yaml"
  assert_eq "$(config_declared_root "$dir/pitcrew.yaml")" "$dir/checkout" "absolute root"
  printf 'root: ./checkout\nname: x\n' > "$dir/pitcrew.yaml"
  assert_eq "$(config_declared_root "$dir/pitcrew.yaml")" "$dir/checkout" "relative to the config file"
  rm -rf "$dir"
}

run_tests
