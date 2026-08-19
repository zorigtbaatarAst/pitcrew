#!/usr/bin/env bash
# lib/15-registry.sh — pitcrew's own project registry.
#
# Configs used to have to live in the project, as <project>/pitcrew.config.sh.
# That works for a repo whose team all use pitcrew, and badly for everything
# else: you cannot add a file to a repo you do not own, a config full of your
# local paths and ports does not belong in version control, and there was no
# way to see what pitcrew knows about without going and looking for it.
#
# So pitcrew keeps its own: ~/.config/pitcrew/projects/<name>.sh, each holding
# a PITCREW_ROOT pointing at the checkout. An in-project pitcrew.config.sh
# still works and still wins — a repo that ships one is making a deliberate
# statement about how it should be run.

PITCREW_HOME="${PITCREW_HOME:-$HOME/.config/pitcrew}"
PROJECTS_DIR="$PITCREW_HOME/projects"
CURRENT_FILE="$PITCREW_HOME/current"

project_slug() { # $1 → a name that is safe as a filename and a systemd unit
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-' | tr 'A-Z' 'a-z' | sed -e 's/-\+/-/g' -e 's/^-//' -e 's/-$//'
}

project_file() { printf '%s/%s.sh' "$PROJECTS_DIR" "$1"; }

project_list() {
  [ -d "$PROJECTS_DIR" ] || return 0
  local f n
  for f in "$PROJECTS_DIR"/*.sh; do
    [ -f "$f" ] || continue
    n=${f##*/}; printf '%s\n' "${n%.sh}"
  done
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

cmd_projects() {
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
  rm -f "$f"
  [ "$(project_current || true)" = "$1" ] && rm -f "$CURRENT_FILE"
  ok "forgot ${BOLD}$1${RESET} ${C_MUTED}(the checkout itself is untouched)${RESET}"
}

cmd_edit() {
  local n=${1:-}
  [ -n "$n" ] || n=$(project_current || true)
  [ -n "$n" ] || die "no current project — pitcrew use <name>, or pitcrew edit <name>"
  local f; f=$(project_file "$n")
  [ -f "$f" ] || die "no project '$n' — see: pitcrew projects"
  "${EDITOR:-vi}" "$f"
}
