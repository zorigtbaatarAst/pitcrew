#!/usr/bin/env bash
# lib/18-yaml.sh — the YAML config front end.
#
# pitcrew's internal model is, and stays, the set of PITCREW_* bash variables
# described in lib/02-config.sh. This file is a *front end* onto that model: it
# reads a `pitcrew.yaml` and fills exactly the same variables a hand-written
# `pitcrew.config.sh` would have set. Nothing downstream — start, meters,
# dashboard, doctor, json — knows which format it came from.
#
# Why a second format at all:
#
#   * a config is data. Sourcing one means every `cd`, `pitcrew status` or
#     `pitcrew ps` executes whatever is in a repo you just cloned.
#   * six parallel associative arrays keyed by app name is a shape you have to
#     hold in your head. `apps: → api: → be: → cmd:` is the shape of the thing
#     being described.
#   * a typo in a bash config is silence. Here every key is checked against a
#     known schema and an unknown one is reported with its line number.
#
# Why a hand-written parser rather than python/yq: pitcrew's whole promise is
# that it runs on a box where you cannot install anything. A config format that
# needs a package is a config format that fails at `pitcrew doctor` time. The
# subset below is small, documented, and refuses — loudly, with a line number —
# anything it does not implement, which is the one behaviour a partial parser
# must never get wrong.
#
# The supported subset:
#   block mappings, nested by indentation (spaces only)
#   block sequences of scalars, `- item`, at or below the parent's indent
#   flow sequences of scalars, `[a, b, c]`
#   flow mappings of scalars, `{a: b, c: d}` — one line per component
#   quoted scalars ('single' with '' escapes, "double" with \" \\ \n \t)
#   block scalars: | and > (with the -/+ chomping indicators accepted)
#   `#` comments, on their own line or after a value
#   `include: <file>`, which pulls in another config the way `source` did
#
# Deliberately NOT supported, each rejected with a message: tabs for indent,
# anchors/aliases/merge keys, tags, sequences of mappings, nested flow
# collections, multiple documents.

# ── parser ────────────────────────────────────────────────────────────────

# Filled by yaml_parse: two parallel arrays, in document order. Order matters —
# it is where the app ordering in PITCREW_APPS comes from.
declare -ga YAML_KEYS=() YAML_VALS=()

_yaml_die() { die "${YAML_FILE:-config}:$1: $2"; }

_yaml_unescape() { # $1 body of a double-quoted scalar → YV
  local s=$1 out="" c
  while [ -n "$s" ]; do
    c=${s:0:1}; s=${s:1}
    if [ "$c" = '\' ] && [ -n "$s" ]; then
      c=${s:0:1}; s=${s:1}
      case "$c" in
        n) out+=$'\n' ;; t) out+=$'\t' ;; r) out+=$'\r' ;; 0) out+=$'\0' ;;
        *) out+=$c ;;
      esac
    else
      out+=$c
    fi
  done
  YV=$out
}

_yaml_scalar() { # $1 raw text after "key:" → YV, quotes resolved, comment stripped
  local v=$1 q body rest c
  # rtrim first so a quoted scalar with trailing spaces still matches below
  v=${v%"${v##*[![:space:]]}"}
  case "$v" in
    '"'*|"'"*)
      # Scan to the closing quote rather than assuming it is the last character:
      # `db: "echo db"   # a comment` is a quoted scalar with a comment after it,
      # and treating the whole tail as the value is how a config silently starts
      # running the wrong command.
      q=${v:0:1}; body=""; rest=${v:1}
      while :; do
        [ -n "$rest" ] || _yaml_die "$YAML_LINE" "unterminated quoted value"
        c=${rest:0:1}; rest=${rest:1}
        if [ "$c" = '\' ] && [ "$q" = '"' ] && [ -n "$rest" ]; then
          body+="$c${rest:0:1}"; rest=${rest:1}; continue      # keep the escape for _yaml_unescape
        fi
        if [ "$c" = "$q" ]; then
          # '' inside a single-quoted scalar is an escaped quote, not the end
          [ "$q" = "'" ] && [ "${rest:0:1}" = "'" ] && { body+="'"; rest=${rest:1}; continue; }
          break
        fi
        body+=$c
      done
      rest=${rest#"${rest%%[![:space:]]*}"}
      case "$rest" in ''|'#'*) ;; *) _yaml_die "$YAML_LINE" "unexpected text after a quoted value: $rest" ;; esac
      if [ "$q" = '"' ]; then _yaml_unescape "$body"; else YV=$body; fi
      return 0 ;;
    '&'*|'*'*) _yaml_die "$YAML_LINE" "anchors and aliases are not supported — write the value out" ;;
    '!'*)      _yaml_die "$YAML_LINE" "tags are not supported" ;;
    '{'*)      _yaml_die "$YAML_LINE" "a flow mapping cannot be nested inside another value" ;;
  esac
  # unquoted: an inline comment starts at " #"
  case "$v" in *' #'*) v=${v%% #*}; v=${v%"${v##*[![:space:]]}"} ;; esac
  case "$v" in '~'|null|Null|NULL) v='' ;; esac
  YV=$v
}

_yaml_flow_seq() { # $1 path, $2 "[a, b]" — emits path.0, path.1, ...
  local path=$1 body=$2 item n=0
  body=${body#\[}; body=${body%\]}
  case "$body" in *'['*|*']'*|*'{'*) _yaml_die "$YAML_LINE" "nested flow collections are not supported" ;; esac
  # An empty list is a legitimate thing to write; it simply contributes nothing.
  case "$body" in *[![:space:]]*) ;; *) return 0 ;; esac
  local IFS=,
  for item in $body; do
    item=${item#"${item%%[![:space:]]*}"}
    _yaml_scalar "$item"
    YAML_KEYS+=("$path.$n"); YAML_VALS+=("$YV"); n=$((n + 1))
  done
  return 0
}

# A one-line component: `be: { dir: api, cmd: npm run dev, port: 3000 }` says
# the same thing as five indented lines. An app is a group of components now,
# and a group with four roles reads far better as four lines than as twenty —
# which is the whole reason this stopped being a rejection.
#
# Scalars only; a collection inside one is refused exactly as it is inside a
# flow sequence. Commas separate the pairs, so a comma INSIDE a value has to be
# quoted — YAML itself requires that in flow context, and the split below
# honours quotes rather than truncating a command at the first comma.
_yaml_flow_map() { # $1 path, $2 "{a: b, c: d}" — emits path.a, path.c
  local path=$1 body=$2 item k v ch q="" cur="" i=0 n
  body=${body#\{}
  case "$body" in *\}) body=${body%\}} ;;
    *) _yaml_die "$YAML_LINE" "unterminated flow mapping — no closing }" ;;
  esac
  case "$body" in *'['*|*']'*|*'{'*|*'}'*) _yaml_die "$YAML_LINE" "nested flow collections are not supported" ;; esac
  case "$body" in *[![:space:]]*) ;; *) return 0 ;; esac

  local -a pairs=()
  n=${#body}
  while [ "$i" -lt "$n" ]; do
    ch=${body:i:1}
    if [ -n "$q" ]; then
      cur+=$ch; [ "$ch" = "$q" ] && q=""
    else
      case "$ch" in
        \'|\") q=$ch; cur+=$ch ;;
        ,)       pairs+=("$cur"); cur="" ;;
        *)       cur+=$ch ;;
      esac
    fi
    i=$((i + 1))
  done
  [ -n "$q" ] && _yaml_die "$YAML_LINE" "unterminated quote inside a flow mapping"
  pairs+=("$cur")

  for item in "${pairs[@]}"; do
    item=${item#"${item%%[![:space:]]*}"}
    item=${item%"${item##*[![:space:]]}"}
    [ -n "$item" ] || continue
    case "$item" in
      *:*) ;;
      *) _yaml_die "$YAML_LINE" "'$item' is not a 'key: value' pair — a comma inside a value needs quoting" ;;
    esac
    k=${item%%:*}; v=${item#*:}
    k=${k%"${k##*[![:space:]]}"}
    v=${v#"${v%%[![:space:]]*}"}
    [ -n "$k" ] || _yaml_die "$YAML_LINE" "a flow mapping entry has no key"
    _yaml_scalar "$v"
    _yaml_emit "$path.$k" "$YV"
  done
  return 0
}

_yaml_emit() { # $1 path, $2 value
  local i
  for i in "${!YAML_KEYS[@]}"; do
    [ "${YAML_KEYS[i]}" = "$1" ] && { warn "config: ${YAML_FILE##*/}:$YAML_LINE: '$1' is set twice — the later value wins"; break; }
  done
  YAML_KEYS+=("$1"); YAML_VALS+=("$2")
}

# Reads $1 into YAML_KEYS/YAML_VALS as dotted paths: "apps.api.be.port" → "8080".
# Sequence items become numeric path segments: "deps.0" → "postgres".
yaml_parse() { # $1 file
  YAML_FILE=$1
  YAML_KEYS=(); YAML_VALS=()
  local -a L=()
  mapfile -t L < "$1"

  local n=${#L[@]} i j line stripped indent key val path parent lead
  local -a st_ind=() st_path=()
  local -A seq_n=()
  local depth=0

  for ((i = 0; i < n; i++)); do
    YAML_LINE=$((i + 1))
    line=${L[i]%$'\r'}
    stripped=${line#"${line%%[![:space:]]*}"}
    [ -n "$stripped" ] || continue
    case "$stripped" in '#'*) continue ;; esac
    indent=$(( ${#line} - ${#stripped} ))
    lead=${line:0:indent}
    case "$lead" in *$'\t'*) _yaml_die "$YAML_LINE" "tabs cannot be used to indent YAML — use spaces" ;; esac
    case "$stripped" in
      '---'|'---'[[:space:]]*|'...'|'...'[[:space:]]*) continue ;;
      '<<:'*) _yaml_die "$YAML_LINE" "merge keys (<<:) are not supported" ;;
    esac

    # ── a sequence item ──────────────────────────────────────────────────
    if [ "${stripped:0:1}" = '-' ] && { [ ${#stripped} -eq 1 ] || [ "${stripped:1:1}" = ' ' ]; }; then
      # A `- ` may sit at the same indent as the key that owns it, so pop on
      # strictly-less rather than less-or-equal.
      while [ $depth -gt 0 ] && [ "$indent" -lt "${st_ind[depth-1]}" ]; do depth=$((depth - 1)); done
      [ $depth -gt 0 ] || _yaml_die "$YAML_LINE" "list item outside of any key"
      path=${st_path[depth-1]}
      val=${stripped#-}; val=${val# }
      case "$val" in
        [A-Za-z0-9_-]*:|[A-Za-z0-9_-]*:' '*)
          _yaml_die "$YAML_LINE" "a list of mappings is not supported here — every list in a pitcrew config is a list of plain values" ;;
      esac
      _yaml_scalar "$val"
      j=${seq_n[$path]:-0}; seq_n[$path]=$((j + 1))
      _yaml_emit "$path.$j" "$YV"
      continue
    fi

    # ── key: [value] ─────────────────────────────────────────────────────
    case "${stripped:0:1}" in
      '"'|"'")
        local q=${stripped:0:1} rest=${stripped:1}
        key=${rest%%"$q"*}
        [ "$key" != "$rest" ] || _yaml_die "$YAML_LINE" "unterminated quoted key"
        rest=${rest#*"$q"}
        case "$rest" in
          ':') val='' ;;
          ':'*) val=${rest#:}; val=${val# } ;;
          *) _yaml_die "$YAML_LINE" "expected ':' after a quoted key" ;;
        esac ;;
      *)
        case "$stripped" in
          *': '*) key=${stripped%%': '*}; val=${stripped#*': '} ;;
          *':')   key=${stripped%:}; val='' ;;
          *':'*)  _yaml_die "$YAML_LINE" "a key needs a space after its colon — write 'key: value', not '${stripped%%:*}:${stripped#*:}'" ;;
          *)      _yaml_die "$YAML_LINE" "expected 'key: value' — got: $stripped" ;;
        esac ;;
    esac
    [ -n "$key" ] || _yaml_die "$YAML_LINE" "empty key"
    # `key:` followed by more than one space left the extra whitespace on the
    # front of the value, so `be:      { … }` did not look like a flow mapping
    # and `deps:   [a, b]` did not look like a flow sequence — both were read
    # as ordinary scalars and quietly did nothing. Aligning your values is not
    # a syntax error in any other YAML.
    val=${val#"${val%%[![:space:]]*}"}

    while [ $depth -gt 0 ] && [ "$indent" -le "${st_ind[depth-1]}" ]; do depth=$((depth - 1)); done
    if [ $depth -gt 0 ]; then parent=${st_path[depth-1]}; path="$parent.$key"; else parent=""; path=$key; fi

    # App names become component names, log file names and systemd unit names,
    # and this parser splits its own paths on dots. Both reasons point the same
    # way, so say it once, here, rather than misparsing quietly.
    if [ "$parent" = apps ]; then
      case "$key" in *.*|*/*|*' '*) _yaml_die "$YAML_LINE" "app name '$key' cannot contain '.', '/' or a space" ;; esac
    fi

    # ── block scalar: consume the indented body ──────────────────────────
    case "$val" in
      '|'|'|-'|'|+'|'>'|'>-'|'>+')
        local style=${val:0:1} chomp=${val:1:1} body="" bind=-1 bl bstripped bindent
        for ((j = i + 1; j < n; j++)); do
          bl=${L[j]%$'\r'}
          bstripped=${bl#"${bl%%[![:space:]]*}"}
          if [ -z "$bstripped" ]; then body+=$'\n'; continue; fi
          bindent=$(( ${#bl} - ${#bstripped} ))
          [ "$bindent" -le "$indent" ] && break
          [ "$bind" -lt 0 ] && bind=$bindent
          [ "$bindent" -lt "$bind" ] && break
          if [ "$style" = '|' ]; then body+="${bl:bind}"$'\n'
          else                        body+="${bl:bind} "; fi
        done
        i=$((j - 1))
        # Chomp. Folded scalars join with spaces, so trim the trailing one too.
        body=${body%"${body##*[!$'\n']}"}
        [ "$style" = '>' ] && body=${body% }
        [ "$chomp" = '+' ] && body+=$'\n'
        _yaml_emit "$path" "$body"
        continue ;;
      '['*) _yaml_flow_seq "$path" "$val"; continue ;;
      '{'*) _yaml_flow_map "$path" "$val"; continue ;;
    esac

    if [ -z "$val" ]; then
      st_ind[depth]=$indent; st_path[depth]=$path; depth=$((depth + 1))
    else
      _yaml_scalar "$val"
      _yaml_emit "$path" "$YV"
    fi
  done
  return 0
}

# ── schema ────────────────────────────────────────────────────────────────

# $ROOT and $HOME are the two things a config genuinely cannot write out (one
# is not known until load time, the other is not the same on two machines), so
# they are expanded here. Everything else is left exactly as written: start
# commands are handed to a shell, and expanding $JAVA_HOME or $PWD here instead
# of there would be both surprising and wrong.
_yaml_expand() { # $1 → YV
  local s=$1 out=""
  s=${s//'${ROOT}'/$ROOT}
  s=${s//'${HOME}'/$HOME}
  while [[ $s == *'$'* ]]; do
    out+=${s%%'$'*}; s=${s#*'$'}
    case "$s" in
      ROOT)                out+=$ROOT; s='' ;;
      ROOT[!A-Za-z0-9_]*)  out+=$ROOT; s=${s#ROOT} ;;
      HOME)                out+=$HOME; s='' ;;
      HOME[!A-Za-z0-9_]*)  out+=$HOME; s=${s#HOME} ;;
      *)                   out+='$' ;;
    esac
  done
  YV=$out$s
}

# YAML has a generous idea of what "true" is; pitcrew has a narrow one, and
# says so rather than treating an unrecognised word as false. A config that
# meant to protect something and quietly did not is the failure that matters.
_yaml_bool() { # $1 key path, $2 value → YV (1 or "")
  case "$1" in *) : ;; esac
  case "$2" in
    true|True|TRUE|yes|Yes|YES|on|On|ON|1)     YV=1 ;;
    false|False|FALSE|no|No|NO|off|Off|OFF|0|'') YV="" ;;
    *) warn "config: ${YAML_FILE##*/}: $1: '$2' is not a yes/no value — treating it as no"; YV="" ;;
  esac
}

# $1 → YV. Absolute stays as it is; `~` is the home directory; anything else
# is relative to $2, defaulting to the project root.
#
# `~` used to be the one path spelling that did NOT work here. `$HOME` expanded
# and `~` did not, so `dir: ~/work/api` resolved to "$ROOT/~/work/api" — a
# directory that cannot exist, which `pitcrew check` reported as loading clean
# and which then failed at start time with a path nobody could parse.
# A variable, not a literal, purely so shellcheck can tell a `~` being MATCHED
# from a `~` someone forgot to let the shell expand.
_YAML_TILDE='~'

_yaml_path() { # $1 path, $2 base (default $ROOT) → YV
  local base=${2:-$ROOT}
  case "$1" in
    '')    YV=$1 ;;
    /*)    YV=$1 ;;
    "$_YAML_TILDE")    YV=$HOME ;;
    "$_YAML_TILDE"/*)  YV="$HOME/${1#*/}" ;;
    *)     YV="$base/$1" ;;
  esac
}

# Display settings a config may pin, each becoming PITCREW_<NAME>. An allowlist
# rather than "anything under dashboard:" so that a typo is still an error.
_YAML_DASHBOARD_KEYS=" theme color icons refresh graph graph_scale gauge ram_cell\
 history mouse narrow_at compact_at micro_at xl_at error_pattern error_scan_max\
 health_interval health_timeout dep_interval log_keep restart restart_backoff restart_max\
 restart_reset start_concurrency start_slot_secs "

# Ordered project doctor checks declared in YAML, consumed by lib/12-doctor.sh.
declare -ga YAML_DOCTOR_NAME=() YAML_DOCTOR_CMD=()
YAML_DEPTH=0

# One component of one app. The role is whatever the config called it — `be`
# and `fe` are two ordinary names with no special handling left in here, which
# is what makes `worker:` or a second `web:` cost nothing to add.
_yaml_role_key() { # $1 app, $2 role, $3 key, $4 value
  local app=$1 role=$2 key=$3 v=$4 comp="$2-$1"
  case "$key" in
    # PITCREW_SRC_CMD keeps what the FILE says. PITCREW_CMD gains a `cd` in
    # front of it below, and an editor showing that back to you would be
    # showing you something you never wrote.
    cmd)    PITCREW_CMD[$comp]=$v; PITCREW_SRC_CMD[$comp]=$v; config_add_role "$app" "$role" ;;
    port)   PITCREW_PORT[$comp]=$v ;;
    health) PITCREW_HEALTH[$comp]=$v ;;
    max)    PITCREW_MAX_COMP[$comp]=$v ;;
    protected)
      _yaml_bool "apps.$app.$role.protected" "$v"
      if [ -n "$YV" ]; then PITCREW_PROTECTED[$comp]=1
      else unset "PITCREW_PROTECTED[$comp]"; fi ;;
    enabled)
      # The exclusion switch. Recorded as DISABLED rather than as "absent", so
      # the component keeps its row, its port and its cap and simply says off.
      _yaml_bool "apps.$app.$role.enabled" "$v"
      if [ -n "$YV" ]; then unset "PITCREW_DISABLED[$comp]"
      else PITCREW_DISABLED[$comp]=1; fi ;;
    root)
      # This component's own checkout. A backend and a frontend are frequently
      # two repositories, and before this the only way to say so was to repeat
      # an absolute path in front of every `dir:` and every `watch:`.
      _yaml_path "$v"; YAML_ROOT[$comp]=$YV; PITCREW_SRC_ROOT[$comp]=$v ;;
    dir)
      # `dir` is the boilerplate every hand-written config repeats: the command
      # is almost always "go to this directory, then run this". Recorded here
      # and folded into the command once the whole app has been read, because
      # cmd, dir and root can appear in any order.
      YAML_DIR_RAW[$comp]=$v; PITCREW_SRC_DIR[$comp]=$v ;;
    watch)
      YAML_WATCH_RAW[$comp]="${YAML_WATCH_RAW[$comp]:+${YAML_WATCH_RAW[$comp]}$'\n'}$v"
      PITCREW_SRC_WATCH[$comp]="${PITCREW_SRC_WATCH[$comp]:+${PITCREW_SRC_WATCH[$comp]} }$v" ;;
    *) warn "config: ${YAML_FILE##*/}: unknown key 'apps.$app.$role.$key'" ;;
  esac
}

_yaml_app_key() { # $1 = path under "apps.", $2 value
  local rest=$1 v=$2 app key role sub
  app=${rest%%.*}
  [ "$app" != "$rest" ] || { warn "config: apps.$app must be a block of settings, not a value"; return 0; }
  key=${rest#*.}

  # remember the order apps appear in — that is PITCREW_APPS
  case " ${PITCREW_APPS[*]:-} " in *" $app "*) ;; *) PITCREW_APPS+=("$app") ;; esac

  case "$key" in
    url_path) PITCREW_URL_PATH[$app]=$v ;;
    enabled)
      # Switching off a whole group: every role it has, and every role it
      # gains later in the file, which is why it is remembered per app rather
      # than applied to the components that happen to exist right now.
      _yaml_bool "apps.$app.enabled" "$v"
      if [ -n "$YV" ]; then unset "YAML_APP_OFF[$app]"; else YAML_APP_OFF[$app]=1; fi ;;
    root)
      # A default checkout for every role in the group. A per-role `root:`
      # still wins — one repo for the app and one component living elsewhere is
      # the common shape, not the exception.
      _yaml_path "$v"; YAML_ROOT[$app]=$YV; PITCREW_SRC_ROOT[$app]=$v ;;
    *.*)
      # Anything else with a dot under it is a COMPONENT: `be.cmd`, `fe.port`,
      # `worker.dir`. No allowlist of role names, which is the whole point.
      role=${key%%.*}; sub=${key#*.}
      case "$sub" in
        watch.[0-9]*) sub=watch ;;      # a list of watch dirs, one path per index
      esac
      if config_role_ok "$role"; then _yaml_role_key "$app" "$role" "$sub" "$v"
      else warn "config: apps.$app.$role: a role name must be letters, digits or _ — it becomes half of a component id"; fi ;;
    *)
      # A bare key with a scalar under it that is not one of ours. If it looks
      # like a role someone forgot to indent, say so in those words.
      if config_role_ok "$key"; then
        warn "config: apps.$app.$key must be a block of settings (cmd:, port:, …), not a value"
      else
        warn "config: ${YAML_FILE##*/}: unknown key 'apps.$app.$key'"
      fi ;;
  esac
}

# Reads a pitcrew.yaml into the same variables a pitcrew.config.sh would set.
# Safe to call from inside a function: every array it touches was created with
# `declare -gA` by config_defaults, so an assignment here lands on the global
# (which is exactly what a bare `declare -A` in a sourced .sh file does not do
# — see the note atop lib/02-config.sh).
yaml_config_load() { # $1 file
  yaml_parse "$1"
  # An included file adds to what its includer has read, so only the outermost
  # load starts from empty.
  if [ "$YAML_DEPTH" -eq 0 ]; then
    declare -gA YAML_DIR_RAW=() YAML_WATCH_RAW=() YAML_ROOT=() YAML_APP_OFF=()
    YAML_DOCTOR_NAME=(); YAML_DOCTOR_CMD=()
  fi

  local k path raw v key inc sf
  local -a sk=() sv=()
  for ((k = 0; k < ${#YAML_KEYS[@]}; k++)); do
    path=${YAML_KEYS[k]}; raw=${YAML_VALS[k]}
    _yaml_expand "$raw"; v=$YV
    case "$path" in
      include)
        # What `source` does for the .sh format, and needed for the same one
        # reason: a registry entry for a repo that ships its own config is a
        # pointer at that config, not a copy of it. Keys after the include
        # override what it set.
        [ "$k" -eq 0 ] || die "${YAML_FILE}: include: must be the first key in the file"
        _yaml_path "$v"; inc=$YV
        [ -f "$inc" ] || die "${YAML_FILE}: include: $inc does not exist"
        YAML_DEPTH=$((YAML_DEPTH + 1))
        [ "$YAML_DEPTH" -le 4 ] || die "${YAML_FILE}: include: nested more than 4 deep — a loop?"
        sk=("${YAML_KEYS[@]}"); sv=("${YAML_VALS[@]}"); sf=$YAML_FILE
        yaml_config_load "$inc"
        YAML_KEYS=("${sk[@]}"); YAML_VALS=("${sv[@]}"); YAML_FILE=$sf
        YAML_DEPTH=$((YAML_DEPTH - 1)) ;;
      name)            PITCREW_PROJECT_NAME=$v ;;
      emoji)           PITCREW_EMOJI=$v ;;
      root)            PITCREW_ROOT=$ROOT ;;      # already resolved before load
      wait)            PITCREW_WAIT_SECS=$v ;;
      deps.[0-9]*)          PITCREW_DEPS+=("$v") ;;
      protected_deps.[0-9]*) PITCREW_PROTECTED_DEPS+=("$v") ;;
      deps_ready)      PITCREW_DEPS_READY_CMD=$v ;;
      env.*)           PITCREW_ROLE_ENV[${path#env.}]=$v ;;
      max.*)           PITCREW_ROLE_MAX[${path#max.}]=$v ;;
      shells.*)        PITCREW_SHELLS[${path#shells.}]=$v ;;
      doctor.*)        YAML_DOCTOR_NAME+=("${path#doctor.}"); YAML_DOCTOR_CMD+=("$v") ;;
      dashboard.*)
        key=${path#dashboard.}
        case "$_YAML_DASHBOARD_KEYS" in
          *" $key "*) printf -v "PITCREW_${key^^}" '%s' "$v" ;;
          *) warn "config: ${YAML_FILE##*/}: unknown dashboard setting '$key'" ;;
        esac ;;
      apps.*)          _yaml_app_key "${path#apps.}" "$v" ;;
      deps|protected_deps|env|max|apps|shells|doctor|dashboard)
        warn "config: ${YAML_FILE##*/}: '$path' has no value under it" ;;
      *)               warn "config: ${YAML_FILE##*/}: unknown key '$path'" ;;
    esac
  done

  # ── resolve where each component lives, then fold it into the command ──
  #
  # Deferred to here because `root:`, `dir:`, `cmd:` and `watch:` may appear in
  # any order, and a path resolved before its root has been read would be
  # resolved against the wrong thing. Three layers, most specific first:
  # the component's own root, the app's root, the project root.
  local c app role base w dir
  local -a wlist
  for c in "${!PITCREW_CMD[@]}"; do
    app=${c#*-}
    base=${YAML_ROOT[$c]:-${YAML_ROOT[$app]:-$ROOT}}
    dir=$base
    if [ -n "${YAML_DIR_RAW[$c]:-}" ]; then
      _yaml_path "${YAML_DIR_RAW[$c]}" "$base"; dir=$YV
    fi
    # `cd` into it only when the config actually said where — an app with no
    # dir and no root has always run from wherever pitcrew was invoked.
    if [ -n "${YAML_DIR_RAW[$c]:-}" ] || [ -n "${YAML_ROOT[$c]:-}" ] || [ -n "${YAML_ROOT[$app]:-}" ]; then
      PITCREW_CMD[$c]="cd ${dir@Q} && ${PITCREW_CMD[$c]}"
      # a component with a dir and no watch dir watches the dir it runs in
      [ -n "${YAML_WATCH_RAW[$c]:-}" ] || PITCREW_WATCH_DIR[$c]=$dir
    fi
  done
  # Watch dirs resolve against the same base, and only now is that base known.
  for c in "${!YAML_WATCH_RAW[@]}"; do
    app=${c#*-}
    base=${YAML_ROOT[$c]:-${YAML_ROOT[$app]:-$ROOT}}
    wlist=(); PITCREW_WATCH_DIR[$c]=""
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      _yaml_path "$w" "$base"; wlist+=("$YV")
    done <<< "${YAML_WATCH_RAW[$c]}"
    PITCREW_WATCH_DIR[$c]="${wlist[*]}"
  done
  # An app switched off switches off everything in the group — including roles
  # declared after the `enabled: false` line.
  for app in "${!YAML_APP_OFF[@]}"; do
    for role in ${PITCREW_APP_ROLES[$app]:-}; do PITCREW_DISABLED[$role-$app]=1; done
  done
  YAML_DIR_RAW=(); YAML_WATCH_RAW=(); YAML_ROOT=(); YAML_APP_OFF=()

  # ── the doctor checks, as the function the rest of the tool already calls ──
  if [ ${#YAML_DOCTOR_CMD[@]} -gt 0 ]; then
    pitcrew_doctor_extra() {
      local i
      for i in "${!YAML_DOCTOR_CMD[@]}"; do
        if bash -c "${YAML_DOCTOR_CMD[i]}" >/dev/null 2>&1
        then ok   "${YAML_DOCTOR_NAME[i]}"
        else bad  "${YAML_DOCTOR_NAME[i]} ${GREY}(${YAML_DOCTOR_CMD[i]})${RESET}"; fi
      done
    }
  fi
  return 0
}

# PITCREW_ROOT out of a YAML config, without loading it — the mirror of
# config_declared_root for the .sh format, and needed for the same reason: a
# config's paths are resolved against ROOT, so ROOT has to be known first.
# A relative `root:` is relative to the config file, which is what lets a
# registry entry say `root: ../checkout` and a shipped one say nothing at all.
yaml_declared_root() { # $1 file → the declared root, or nothing
  [ -r "$1" ] || return 0
  local v
  v=$(sed -n 's/^root:[[:space:]]*//p' "$1" | head -1)
  v=${v%%[[:space:]]#*}
  v=${v%"${v##*[![:space:]]}"}
  v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
  [ -n "$v" ] || return 0
  # shellcheck disable=SC2088  # comparing against a literal ~, not expanding one
  [ "${v:0:2}" = '~/' ] && { printf '%s' "$HOME/${v:2}"; return 0; }
  case "$v" in
    /*) printf '%s' "$v" ;;
    *)  ( cd "$(dirname "$1")" && cd "$v" 2>/dev/null && pwd ) ;;
  esac
}

# ── `pitcrew check` ────────────────────────────────────────────────────────
#
# Runs before config resolution (see bin/pitcrew), because the file it is being
# asked about is exactly the one that may be too broken to resolve. Loading in
# a subshell is what makes that safe: die() exits, and here that exit is a
# result rather than the end of the session.
cmd_check() { # [<file>]
  local f=${1:-} out rc=0
  if [ -n "$f" ]; then
    [ -d "$f" ] && f=$(_walk_up_for_config "$(cd "$f" && pwd)")
    [ -f "$f" ] || die "no such config: ${1}"
  else
    f=$(find_config) || die "no config here — write a pitcrew.yaml, or: pitcrew init <dir>"
  fi

  if config_is_yaml "$f"; then
    out=$( {
      ROOT=$(config_declared_root "$f")
      [ -n "$ROOT" ] || ROOT=$(cd "$(dirname "$f")" && pwd)
      config_defaults
      yaml_config_load "$f"
      CONFIG_FILE=$f
      [ ${#PITCREW_APPS[@]} -gt 0 ] || warn "config: no apps: — nothing would ever start"
      config_validate
    } 2>&1 ) || rc=$?
  else
    out=$(bash -n "$f" 2>&1) || rc=$?
  fi

  out=$(printf '%s' "$out" | sed -e $'s/\x1b\[[0-9;]*m//g' -e '/^[[:space:]]*$/d')
  if [ "$rc" != 0 ]; then
    say ""
    say "  ${C_MUTED}${f}${RESET}"
    [ -n "$out" ] && say "$out"
    bad "not loadable"
    say ""
    return 1
  fi
  say ""
  say "  ${C_MUTED}${f}${RESET}"
  if [ -n "$out" ]; then
    say "$out"
    say ""
    ok "loads — with the warnings above"
  else
    ok "loads clean"
  fi
  say ""
  return 0
}
