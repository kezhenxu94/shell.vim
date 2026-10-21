#!/usr/bin/env bash
# Mirrors a library + dispatcher test script: defaults and helpers in a
# setup region, then `has_step x && step_x` lines.
set -euo pipefail

[ -z "${baseURL:-}" ] && { echo "usage: baseURL=... $0" >&2; exit 1; }

# @setup
STEPS=${STEPS:-me,nodes}
CALLS=${CALLS:-0}
log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
api() { CALLS=$((CALLS + 1)); RESPONSE="{\"path\":\"$2\",\"base\":\"$baseURL\"}"; }
has_step() { case ",$STEPS," in *",$1,"*) return 0 ;; esac; return 1; }
step_me() { log me; api GET /alliances/me; MY_ALLIANCE_ID=a-42; }
step_nodes() { log nodes; api GET /nodes; NODES_JSON='[1,2]'; }
# @end

has_step me && step_me
has_step nodes && step_nodes
echo "done: $MY_ALLIANCE_ID $NODES_JSON calls=$CALLS"
