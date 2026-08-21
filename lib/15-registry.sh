#!/usr/bin/env bash
# lib/15-registry.sh — pitcrew's own project registry.
#
# Configs used to have to live in the project, as <project>/pitcrew.config.sh.
# That works for a repo whose team all use pitcrew, and badly for everything
# else: you cannot add a file to a repo you do not own, a config full of your
# local paths and ports does not belong in version control, and there was no
# way to see what pitcrew knows about without going and looking for it.
#
# So pitcrew keeps its own: ~/.config/pitcrew/projects/<name>.yaml (or .sh for
# entries written before YAML support, and for hand-written bash ones), each
# recording the root of the checkout it points at. An in-project config still
# works and still wins — a repo that ships one is making a deliberate statement
# about how it should be run.

PITCREW_HOME="${PITCREW_HOME:-$HOME/.config/pitcrew}"
PROJECTS_DIR="$PITCREW_HOME/projects"
CURRENT_FILE="$PITCREW_HOME/current"

project_slug() { # $1 → a name that is safe as a filename and a systemd unit
  # -E, not a BRE: BSD sed (macOS) does not understand \+ and would leave the
  # run of dashes in place, changing the slug — and with it the file name and
  # the systemd unit name — depending on which sed happened to be installed.
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | tr 'A-Z' 'a-z' | sed -E -e 's/-+/-/g' -e 's/^-//' -e 's/-$//'
}

# A registry entry is <name>.yaml (what `pitcrew init` writes) or <name>.sh
# (what it used to write, and what a hand-written one may still be). The name
# is the file's stem either way; only the loader differs.
PITCREW_REGISTRY_EXTS=(yaml yml sh)

project_file() { # $1 name → the file that exists, else the .yaml it would be
  local e f
  for e in "${PITCREW_REGISTRY_EXTS[@]}"; do
    f="$PROJECTS_DIR/$1.$e"
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  printf '%s/%s.yaml' "$PROJECTS_DIR" "$1"
}

project_list() {
  [ -d "$PROJECTS_DIR" ] || return 0
  local f n
  for f in "$PROJECTS_DIR"/*.yaml "$PROJECTS_DIR"/*.yml "$PROJECTS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    n=${f##*/}; printf '%s\n' "${n%.*}"
  done | sort -u
}

project_root_of() { # $1 name → the checkout it points at, without sourcing the file
  local f; f=$(project_file "$1")
  [ -r "$f" ] || return 1
  config_declared_root "$f"
}

project_current() {
  [ -r "$CURRENT_FILE" ] || return 1
  local n; read -r n < "$CURRENT_FILE"
  [ -n "$n" ] && [ -f "$(project_file "$n")" ] && printf '%s' "$n"
}

project_set_current() {
  mkdir -p "$PITCREW_HOME"
  printf '%s\n' "$1" > "$CURRENT_FILE"
}

# Which registered project owns this directory? The deepest matching root wins,
# so a project checked out inside another one still resolves to itself.
project_for_dir() { # $1 dir → name
  local dir=$1 n r best="" bestlen=0
  while IFS= read -r n; do
    r=$(project_root_of "$n") || continue
    [ -n "$r" ] || continue
    case "$dir/" in "$r"/*|"$r/") ;; *) continue ;; esac
    [ ${#r} -gt $bestlen ] && { best=$n; bestlen=${#r}; }
  done < <(project_list)
  [ -n "$best" ] && printf '%s' "$best"
}

# How many of a project's components are alive, without loading its config.
project_running_count() { # $1 root → count
  local root=$1 f pid n=0
  for f in "$root"/.pitcrew/logs/*.pid; do
    [ -r "$f" ] || continue
    read -r pid < "$f" 2>/dev/null
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && n=$((n + 1))
  done
  printf '%d' "$n"
}

# Everything about one project, for the picker's preview pane. The app list
# lives in the config, and for a pointer entry that config is the repository's
# own — so load it rather than grepping. A $( ) subshell is safe here in a way
# a function is not: a bare `declare -A` inside a sourced file is scoped to the
# running FUNCTION, not to a subshell.
project_info() { # $1 name
  local f root apps n live
  f=$(project_file "$1") || return 1
  [ -f "$f" ] || return 1
  root=$(config_declared_root "$f")
  apps=$( ROOT=$root; config_defaults 2>/dev/null
          # `source` stays at the subshell's top level on purpose: inside a
          # function a bare `declare -A` in the sourced file would be scoped to
          # that function and lost (see the note in lib/02-config.sh).
          if config_is_yaml "$f"; then yaml_config_load "$f" 2>/dev/null
          else source "$f" 2>/dev/null; fi
          printf '%s' "${PITCREW_APPS[*]:-}" )
  n=$(printf '%s' "$apps" | wc -w)
  live=$(project_running_count "$root")
  printf '  %b%s%b\n' "$C_ACCENT$BOLD" "$1" "$RESET"
  printf '  %b%s%b\n' "$C_MUTED" "$root" "$RESET"
  [ -d "$root" ] || printf '  %b✗ that directory is gone%b\n' "$C_CRIT" "$RESET"
  if [ "$live" -gt 0 ]; then
    printf '  %b%s apps%b · %b%s running%b\n' "$C_SUBTLE" "$n" "$RESET" "$C_OK" "$live" "$RESET"
  else
    printf '  %b%s apps · idle%b\n' "$C_SUBTLE" "$n" "$RESET"
  fi
  printf '  %b%s%b\n' "$C_FAINT" "$apps" "$RESET"
}

project_pick() { # → the chosen project name on stdout, nothing if cancelled
  command -v fzf >/dev/null 2>&1 || return 1
  local n; n=$(project_list | wc -l)
  [ "$n" -gt 0 ] || return 1
  project_list | fzf --height=45% --border=rounded --ansi \
    --prompt='project ❯ ' --pointer='▶' \
    --header='switch project · Enter opens it · Esc cancels' \
    --preview "'$SELF' projects --show {}" --preview-window='down:5' 2>/dev/null
}

# Switching project inside a running dashboard cannot be done by re-sourcing:
# a config's bare `declare -A` would be scoped to whatever function did the
# sourcing and silently discarded (see the note in lib/02-config.sh). Re-exec
# instead — it is one line, it cannot leave half-updated state behind, and the
# per-project history and error counters correctly start fresh.
switch_project() {
  local n
  tui_pause
  n=$(project_pick) || n=""
  if [ -z "$n" ]; then
    tui_resume
    declare -F toast >/dev/null && toast "${C_MUTED}no other project selected${RESET}"
    return 0
  fi
  project_set_current "$n"
  tui_leave
  exec "$SELF" -p "$n" "${PITCREW_CMD:-watch}"
}

# Every port a project claims, as "port comp" lines. Loading the config in a
# $( ) subshell is safe where doing it in a function is not — a bare
# `declare -A` is scoped to the running function, not to a subshell.
project_ports() { # $1 name
  local f root
  f=$(project_file "$1"); [ -f "$f" ] || return 0
  root=$(config_declared_root "$f")
  ( ROOT=$root
    config_defaults 2>/dev/null
    # shellcheck source=/dev/null
    if config_is_yaml "$f"; then yaml_config_load "$f" 2>/dev/null
    else source "$f" 2>/dev/null; fi
    local a
    for a in "${PITCREW_APPS[@]:-}"; do
      [ -n "${PITCREW_BE_PORT[$a]:-}" ] && printf '%s be-%s\n' "${PITCREW_BE_PORT[$a]}" "$a"
      [ -n "${PITCREW_FE_PORT[$a]:-}" ] && printf '%s fe-%s\n' "${PITCREW_FE_PORT[$a]}" "$a"
    done ) 2>/dev/null
  return 0
}

# Ports two registered projects both claim. This matters more than it sounds:
# pitcrew decides a component is up from its port, so overlapping projects each
# see the other's services and report them as their own. 8080 and 3000 are not
# exactly rare choices.
port_conflicts() { # $1 name → "port thisComp otherProject otherComp" lines
  local me=$1 other line port comp oport ocomp
  declare -A mine=()
  while read -r port comp; do [ -n "$port" ] && mine[$port]=$comp; done < <(project_ports "$me")
  while IFS= read -r other; do
    [ "$other" = "$me" ] && continue
    while read -r oport ocomp; do
      [ -n "$oport" ] || continue
      [ -n "${mine[$oport]:-}" ] && printf '%s %s %s %s\n' "$oport" "${mine[$oport]}" "$other" "$ocomp"
    done < <(project_ports "$other")
  done < <(project_list)
  return 0
}

cmd_ports() { # the whole port map across every registered project
  local n port comp cur
  cur=$(project_current || true)
  say ""
  while IFS= read -r n; do
    say "  ${BOLD}${n}${RESET}"
    while read -r port comp; do
      [ -n "$port" ] || continue
      printf '    %b%-6s%b %b%s%b\n' "$C_MUTED" "$port" "$RESET" "$C_SUBTLE" "$comp" "$RESET"
    done < <(project_ports "$n" | sort -n)
  done < <(project_list)
  say ""
  local any=0
  while IFS= read -r n; do
    while read -r port comp other ocomp; do
      [ -n "$port" ] || continue
      [ "$any" = 0 ] && { say "  ${C_WARN}⚠ ports claimed by more than one project${RESET}"; any=1; }
      printf '    %b%-6s%b %s/%s  %bvs%b  %s/%s\n' "$C_WARN" "$port" "$RESET" \
        "$n" "$comp" "$C_MUTED" "$RESET" "$other" "$ocomp"
    done < <(port_conflicts "$n")
    break                       # one direction is enough; the pairs are symmetric
  done < <(project_list)
  [ "$any" = 1 ] && say "  ${C_MUTED}running both at once makes each report the other's services as its own${RESET}"
  say ""
  return 0
}

# shellcheck disable=SC2120  # callers pass nothing; the args are for `pitcrew ls`
cmd_projects() {
  if [ "${1:-}" = --show ]; then
    [ -n "${2:-}" ] || die "usage: pitcrew projects --show <name>"
    project_info "$2"
    return 0
  fi
  local names; mapfile -t names < <(project_list)
  if [ ${#names[@]} -eq 0 ]; then
    say ""
    say "  ${C_MUTED}no projects registered yet${RESET}"
    say "  ${C_MUTED}add one with:${RESET} ${BOLD}pitcrew init <dir>${RESET}"
    say ""
    return 0
  fi
  local cur n r live mark
  cur=$(project_current || true)
  say ""
  for n in "${names[@]}"; do
    r=$(project_root_of "$n" || echo "?")
    live=$(project_running_count "$r")
    if [ "$n" = "$cur" ]; then mark="${C_ACCENT}●${RESET}"; else mark="${C_MUTED}○${RESET}"; fi
    if [ "$live" -gt 0 ]; then
      printf '  %b %b%-24.24s%b %b%s running%b  %b%s%b\n' "$mark" "$BOLD" "$n" "$RESET" \
        "$C_OK" "$live" "$RESET" "$C_MUTED" "$r" "$RESET"
    else
      printf '  %b %b%-24.24s%b %b%-11s%b  %b%s%b\n' "$mark" "$C_SUBTLE" "$n" "$RESET" \
        "$C_FAINT" "idle" "$RESET" "$C_MUTED" "$r" "$RESET"
    fi
    [ -d "$r" ] || say "      ${C_CRIT}✗ that directory is gone${RESET}"
  done
  say ""
  say "  ${C_MUTED}pitcrew use <name>   ·   pitcrew -p <name> <command>   ·   pitcrew forget <name>${RESET}"
  say ""
}

cmd_use() {
  [ -n "${1:-}" ] || { cmd_projects; return 0; }
  [ -f "$(project_file "$1")" ] || die "no project '$1' — see: pitcrew projects"
  project_set_current "$1"
  ok "now working on ${BOLD}$1${RESET} ${C_MUTED}($(project_root_of "$1"))${RESET}"
}

cmd_forget() {
  [ -n "${1:-}" ] || die "usage: pitcrew forget <name>"
  local f; f=$(project_file "$1")
  [ -f "$f" ] || die "no project '$1' — see: pitcrew projects"
  local e
  for e in "${PITCREW_REGISTRY_EXTS[@]}"; do rm -f "$PROJECTS_DIR/$1.$e"; done
  [ "$(project_current || true)" = "$1" ] && rm -f "$CURRENT_FILE"
  ok "forgot ${BOLD}$1${RESET} ${C_MUTED}(the checkout itself is untouched)${RESET}"
}

# The file that actually holds a project's config. A registry entry for a repo
# that ships its own only records the root and points at it — `source` in the
# bash format, `include:` in YAML — so opening the stub would put you in a
# two-line file, let you edit it, and change nothing the tool reads. The
# desktop app has always followed this indirection; the CLI did not.
project_content_file() { # $1 name → the file worth editing
  local f root inc
  f=$(project_file "$1")
  [ -f "$f" ] || return 1
  root=$(config_declared_root "$f")
  [ -n "$root" ] && [ -d "$root" ] || { printf '%s' "$f"; return 0; }
  if config_is_yaml "$f"; then
    inc=$(sed -n 's/^include:[[:space:]]*//p' "$f" | head -1)
    inc=${inc%%[[:space:]]#*}; inc=${inc%"${inc##*[![:space:]]}"}
    inc=${inc#\"}; inc=${inc%\"}; inc=${inc#\'}; inc=${inc%\'}
    if [ -n "$inc" ]; then
      case "$inc" in /*) ;; *) inc="$root/$inc" ;; esac
      [ -f "$inc" ] && { printf '%s' "$inc"; return 0; }
    fi
  elif grep -qE '^[[:space:]]*(\.|source)[[:space:]]+.*pitcrew\.config\.sh' "$f" 2>/dev/null \
       && [ -f "$root/pitcrew.config.sh" ]; then
    printf '%s' "$root/pitcrew.config.sh"; return 0
  fi
  printf '%s' "$f"
}

cmd_edit() {
  local n=${1:-}
  [ -n "$n" ] || n=$(project_current || true)
  [ -n "$n" ] || die "no current project — pitcrew use <name>, or pitcrew edit <name>"
  local f; f=$(project_content_file "$n") || die "no project '$n' — see: pitcrew projects"
  "${EDITOR:-vi}" "$f"
}
