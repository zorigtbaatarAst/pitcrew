#!/usr/bin/env bash
# lib/14-detect.sh — work out what a project actually is.
#
# `pitcrew init` used to write a file full of `echo '>> set PITCREW_BE_CMD'`
# placeholders, which meant the first thing a new project did was fail. This
# reads the repository instead: which directories are apps, what each one is
# built with, how to start it, and which port it will land on.
#
# It is a best guess, and it says so — the generated config is a normal bash
# file meant to be read and corrected. But a guess that runs beats a blank that
# does not.
#
# None of this is on any hot path; it runs once, per project, at init time, so
# it uses grep and awk freely.

# Directories that are never an app, in any project. Keep this list
# UNIVERSAL — build output, dependencies, docs, conventional library folders.
# An earlier version also skipped names lifted from one particular repo
# (`manage`, `aws`, `cdn`, ...), which silently lost real apps in the next one.
# Wrongly skipping a directory loses a service with no warning; wrongly
# including one just adds a line the user deletes. The costs are not symmetric.
_DETECT_SKIP='node_modules|build|dist|out|target|obj|vendor|gradle|docker|docs|doc|logs|log|tmp|temp|scripts|script|assets|public|static|coverage|venv|__pycache__|shared|common|lib|libs|bin|test|tests|e2e'

# Subdirectory names that name a role rather than an app.
_role_of_dir() { # $1 basename → ROLE ("" when it is not a role directory)
  case "$1" in
    backend|server|api|be)    ROLE=be ;;
    frontend|web|client|ui|fe) ROLE=fe ;;
    *)                         ROLE="" ;;
  esac
}

_detect_kind() { # $1 dir → KIND
  local d=$1
  if   [ -f "$d/build.gradle" ] || [ -f "$d/build.gradle.kts" ]; then KIND=gradle
  elif [ -f "$d/pom.xml" ];                                      then KIND=maven
  elif [ -f "$d/package.json" ];                                 then KIND=node
  elif [ -f "$d/go.mod" ];                                       then KIND=go
  elif [ -f "$d/Cargo.toml" ];                                   then KIND=rust
  elif [ -f "$d/manage.py" ];                                    then KIND=django
  elif [ -f "$d/pyproject.toml" ] || [ -f "$d/requirements.txt" ]; then KIND=python
  elif [ -f "$d/Gemfile" ];                                      then KIND=ruby
  else KIND=""
  fi
}

# Can this module actually be STARTED, or is it a library the services depend
# on? Without this a Gradle monorepo reports every shared module as an app —
# immigration went from 7 to 34 "apps", nearly all of them jars.
#
# The distinguishing signal is the PLUGIN, not a mention of spring-boot: a
# library has `implementation "org.springframework.boot:spring-boot-starter-*"`
# in its dependencies and no boot plugin. Matching on the quote that follows
# `boot` separates the plugin id from a dependency coordinate, which always has
# a colon there.
_detect_runnable() { # $1 dir, $2 kind → 0 when it can be started
  local d=$1 f
  case "$2" in
    gradle)
      for f in "$d"/build.gradle "$d"/build.gradle.kts; do
        [ -f "$f" ] || continue
        grep -qE "org\.springframework\.boot[\"')]" "$f" && return 0
        grep -qE "(id[[:space:]]*[(\"']+application|apply plugin:[[:space:]]*[\"']application)" "$f" && return 0
        grep -qE "^[[:space:]]*(bootRun|application)[[:space:]]*\{" "$f" && return 0
      done
      return 1 ;;
    maven)
      grep -qs 'spring-boot-maven-plugin\|exec-maven-plugin' "$d/pom.xml" && return 0
      return 1 ;;
    node)
      # a package with no way to run it is a library
      _node_script "$d"; [ -n "$NSCRIPT" ] && return 0
      return 1 ;;
    go)
      grep -rqs --include='*.go' '^package main' "$d" && return 0
      return 1 ;;
    *) return 0 ;;
  esac
}

_node_flavour() { # $1 dir → NFLAV, which decides both the default port and the role
  local pj="$1/package.json"
  NFLAV=node
  grep -qs '"react-scripts"' "$pj" && NFLAV=react
  grep -qs '"vite"'          "$pj" && NFLAV=vite
  grep -qs '"nuxt"'          "$pj" && NFLAV=nuxt
  grep -qs '"@angular/core"' "$pj" && NFLAV=angular
  grep -qs '"next"'          "$pj" && NFLAV=next
  grep -qs '"nest"'          "$pj" && NFLAV=nest      # a node BACKEND
  return 0
}

_node_pm() { # $1 dir → NPM, from whichever lockfile is present
  if   [ -f "$1/pnpm-lock.yaml" ]; then NPM=pnpm
  elif [ -f "$1/yarn.lock" ];      then NPM=yarn
  elif [ -f "$1/bun.lockb" ];      then NPM=bun
  else                                  NPM=npm
  fi
}

_node_script() { # $1 dir → NSCRIPT, the first plausible "run it" script
  local pj="$1/package.json" s
  NSCRIPT=""
  for s in dev develop start serve; do
    grep -qsE "\"$s\"[[:space:]]*:" "$pj" && { NSCRIPT=$s; return 0; }
  done
  return 0
}

_detect_port() { # $1 dir, $2 kind → PORT ("" when it cannot be known)
  PORT=""
  case "$2" in
    gradle|maven)
      PORT=$(grep -rhsoE '^[[:space:]]*server\.port[[:space:]]*[=:][[:space:]]*[0-9]+' \
               "$1"/src/main/resources/application*.properties 2>/dev/null \
             | grep -oE '[0-9]+$' | head -1)
      [ -n "$PORT" ] && return 0
      # yaml form:  server:\n  port: 8080
      PORT=$(awk '/^server:/{f=1;next} f&&/^[[:space:]]+port:/{gsub(/[^0-9]/,"",$2);print $2;exit} /^[^[:space:]#]/{f=0}' \
               "$1"/src/main/resources/application*.y*ml 2>/dev/null | head -1)
      ;;
    node)
      # a dev script usually pins it: "next dev -p 3002"
      PORT=$(grep -oE '(--port|-p)[= ]+[0-9]{2,5}' "$1/package.json" 2>/dev/null | grep -oE '[0-9]{2,5}' | head -1)
      [ -n "$PORT" ] && return 0
      case "${NFLAV:-node}" in
        next|react|nuxt) PORT=3000 ;;
        vite)            PORT=5173 ;;
        angular)         PORT=4200 ;;
        nest)            PORT=3000 ;;
      esac
      ;;
    django) PORT=8000 ;;
  esac
  return 0
}

_detect_health() { # $1 dir, $2 kind → HEALTH ("" unless it is clearly Spring Boot)
  HEALTH=""
  case "$2" in
    gradle) grep -qs 'spring-boot' "$1"/build.gradle* && HEALTH=/actuator/health ;;
    maven)  grep -qs 'spring-boot' "$1/pom.xml"       && HEALTH=/actuator/health ;;
  esac
  return 0
}

_detect_cmd() { # $1 root, $2 dir, $3 kind, $4 port → CMD
  local root=$1 d=$2 kind=$3 port=$4 rel=${2#"$1"}
  rel=${rel#/}
  CMD=""
  case "$kind" in
    gradle)
      # A module inside a Gradle build is addressed by its project path, which
      # is just its directory path with colons — sales/backend → :sales:backend
      if [ -n "$rel" ] && [ -x "$root/gradlew" ]; then CMD="./gradlew :${rel//\//:}:bootRun"
      elif [ -x "$root/gradlew" ];                then CMD="./gradlew bootRun"
      else                                             CMD="cd \$ROOT${rel:+/$rel} && gradle bootRun"
      fi ;;
    maven)
      if [ -n "$rel" ] && [ -x "$root/mvnw" ]; then CMD="./mvnw -pl $rel spring-boot:run"
      elif [ -x "$root/mvnw" ];                then CMD="./mvnw spring-boot:run"
      else                                          CMD="cd \$ROOT${rel:+/$rel} && mvn spring-boot:run"
      fi ;;
    node)
      _node_pm "$d"; _node_script "$d"
      if [ -n "$NSCRIPT" ]; then
        CMD="cd \$ROOT${rel:+/$rel} && { [ -d node_modules ] || $NPM install; } && $NPM run $NSCRIPT"
      else
        CMD="cd \$ROOT${rel:+/$rel} && { [ -d node_modules ] || $NPM install; } && $NPM start"
      fi ;;
    go)     CMD="cd \$ROOT${rel:+/$rel} && go run ./..." ;;
    rust)   CMD="cd \$ROOT${rel:+/$rel} && cargo run" ;;
    django) CMD="cd \$ROOT${rel:+/$rel} && python3 manage.py runserver 0.0.0.0:${port:-8000}" ;;
    python)
      if   grep -qsi 'fastapi' "$d/requirements.txt" "$d/pyproject.toml"; then
        CMD="cd \$ROOT${rel:+/$rel} && python3 -m uvicorn main:app --reload --port ${port:-8000}"
      elif grep -qsi 'flask' "$d/requirements.txt" "$d/pyproject.toml"; then
        CMD="cd \$ROOT${rel:+/$rel} && python3 -m flask run --port ${port:-8000}"
      elif [ -f "$d/main.py" ]; then CMD="cd \$ROOT${rel:+/$rel} && python3 main.py"
      elif [ -f "$d/app.py" ];  then CMD="cd \$ROOT${rel:+/$rel} && python3 app.py"
      fi ;;
    ruby)
      if [ -f "$d/config.ru" ]; then CMD="cd \$ROOT${rel:+/$rel} && bundle exec rails s -p ${port:-3000}"
      else                           CMD="cd \$ROOT${rel:+/$rel} && bundle exec ruby main.rb"; fi ;;
  esac
  return 0
}

_role_of_kind() { # $1 kind, $2 node flavour → ROLE, when the directory name did not say
  case "$1" in
    node) case "$2" in next|react|vite|nuxt|angular) ROLE=fe ;; *) ROLE=be ;; esac ;;
    *)    ROLE=be ;;
  esac
}

# ── the scan ────────────────────────────────────────────────────────────────
# Fills DET_APPS (ordered names) and DET_DIR[app.role] → absolute directory.
_det_add() { # $1 app, $2 role, $3 dir
  [ -n "${DET_DIR[$1.$2]:-}" ] && return 0
  case " ${DET_APPS[*]} " in *" $1 "*) ;; *) DET_APPS+=("$1") ;; esac
  DET_DIR[$1.$2]=$3
  return 0
}

_det_walk() { # $1 base dir, $2 depth budget
  local base=$1 budget=$2 sub name found role
  [ "$budget" -le 0 ] && return 0
  for sub in "$base"/*/; do
    [ -d "$sub" ] || continue
    sub=${sub%/}; name=${sub##*/}
    [[ $name =~ ^(${_DETECT_SKIP})$ ]] && continue
    [[ $name == .* ]] && continue

    # does it hold role directories? then it is an app, and they are its roles
    found=0
    local rsub rname
    for rsub in "$sub"/*/; do
      [ -d "$rsub" ] || continue
      rsub=${rsub%/}; rname=${rsub##*/}
      _role_of_dir "$rname"
      [ -n "$ROLE" ] || continue
      _detect_kind "$rsub"; [ -n "$KIND" ] || continue
      _det_add "$name" "$ROLE" "$rsub"; found=1
    done
    [ "$found" = 1 ] && continue

    # is this directory itself a startable app?
    _detect_kind "$sub"
    if [ -n "$KIND" ] && _detect_runnable "$sub" "$KIND"; then
      _node_flavour "$sub"
      _role_of_kind "$KIND" "$NFLAV"
      _det_add "$name" "$ROLE" "$sub"
      continue
    fi

    # Not an app and not a set of roles — so it may be a directory that merely
    # GROUPS apps: apis/, apps/, packages/, services/, sso/sso-api. Rather than
    # matching a list of names it might be called, just look inside. A name
    # list only ever knows about the repositories it was written against.
    _det_walk "$sub" $((budget - 1))
  done
  return 0
}

detect_scan() { # $1 root → DET_APPS, DET_DIR
  local root=$1
  declare -gA DET_DIR=()
  DET_APPS=()
  _det_walk "$root" 2
  # nothing below it: the project itself is the app
  if [ ${#DET_APPS[@]} -eq 0 ]; then
    _detect_kind "$root"
    if [ -n "$KIND" ] && _detect_runnable "$root" "$KIND"; then
      _node_flavour "$root"; _role_of_kind "$KIND" "$NFLAV"
      _det_add "${root##*/}" "$ROLE" "$root"
    fi
  fi
  return 0
}

detect_deps() { # $1 root → DET_DEPS, docker services worth declaring
  DET_DEPS=()
  local f
  for f in "$1/docker-compose.yml" "$1/docker-compose.yaml" "$1/compose.yml" "$1/compose.yaml" \
           "$1/docker/docker-compose.yml" "$1/docker/docker-compose.yaml"; do
    [ -f "$f" ] || continue
    while IFS= read -r s; do [ -n "$s" ] && DET_DEPS+=("$s"); done < <(
      awk '/^services:/{f=1;next} f&&/^[a-zA-Z_-]/{exit} f&&/^  [a-zA-Z0-9._-]+:/{gsub(/[ :]/,"");print}' "$f")
    break
  done
  return 0
}
