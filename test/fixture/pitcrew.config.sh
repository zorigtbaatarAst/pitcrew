#!/usr/bin/env bash
# test/fixture/pitcrew.config.sh — the project the tests run against.
#
# Deliberately covers the awkward shapes, not the happy path: an app with both
# roles, a backend-only app, a frontend-only app, a health path on one backend
# but not the other, and both config styles (pitcrew_app shorthand and raw
# array assignment) in one file.
PITCREW_PROJECT_NAME="fixture"
PITCREW_EMOJI="🧪"

PITCREW_APPS=(both beonly feonly)

pitcrew_app both \
  --be-cmd "true" --be-port 19801 --be-health "/health" \
  --fe-cmd "true" --fe-port 19802 \
  --url-path "/api" --watch-be "src/be" --watch-fe "src/fe"

pitcrew_app beonly --be-cmd "true" --be-port 19803

# raw-array style for the last one, to keep both styles exercised
declare -A PITCREW_FE_CMD=([feonly]="true" [both]="true")
declare -A PITCREW_FE_PORT=([feonly]=19804 [both]=19802)

PITCREW_DEPS=(fixture-db fixture-cache)
PITCREW_PROTECTED_DEPS=(fixture-db)

PITCREW_BE_MAX="2G"
PITCREW_FE_MAX="4G"
