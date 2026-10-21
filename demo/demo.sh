#!/usr/bin/env bash
# Run the command under the cursor with <Space>rr

# @setup
set -euo pipefail
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
# @end

for i in 1 2 3; do
  echo "{\"name\": \"user$i\", \"age\": $((20 + i * 7))}" >"user$i.json"
done

log "users older than 30"
older=$(jq -rs 'map(select(.age > 30).name) | join(", ")' user*.json)

echo "$older"

jq .name missing.json

for step in build test deploy; do
  log "$step"; sleep 1
done
