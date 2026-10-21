#!/usr/bin/env bash
# Record demo/demo.cast and render demo/demo.gif: a script types into Vim in tmux.
# Needs: tmux, jq, asciinema 3 and agg. Usage: demo/record.sh (EDITOR_CMD=nvim to record Neovim)
set -euo pipefail
cd "$(dirname "$0")/.."

editor=${EDITOR_CMD:-vim}
[[ $editor == nvim ]] && editor='nvim --clean'
# A short, stable path: it shows in the [Shell] headers.
work=/tmp/shell.vim-demo
rm -rf "$work" && mkdir -p "$work/state"
cp demo/demo.sh "$work/demo.sh"
tmux=(tmux -L shell-vim-demo -f "$PWD/demo/tmux.conf")
trap '"${tmux[@]}" kill-server 2>/dev/null || true; rm -rf "$work"' EXIT

"${tmux[@]}" kill-server 2>/dev/null || true
"${tmux[@]}" new-session -d -s demo -x 140 -y 32 -c "$work" -e XDG_STATE_HOME="$work/state" \
  "$editor -Nu '$PWD/demo/vimrc' -i NONE demo.sh"

TERM=xterm-256color asciinema rec --headless --overwrite --window-size 140x32 --idle-time-limit 2 \
  --title shell.vim -c "${tmux[*]} attach -t demo" demo/demo.cast &
recording=$!

keys() { "${tmux[@]}" send-keys -t demo "$@"; }
typ() { # type text one character at a time
  local s=$1 i
  for ((i = 0; i < ${#s}; i++)); do
    keys -l -- "${s:i:1}"
    sleep 0.06
  done
}
pause() { sleep "${1:-1}"; }

pause 2
# Run the command under the cursor: the setup region above it is applied first
keys 9G; pause 1; typ ' rr'; pause 2.5
# Variables carry over between runs, ANSI colors are kept
keys 13G; pause 0.5; typ ' rr'; pause 1.5
keys j; typ ' rr'; pause 1.5
keys 2j; typ ' rr'; pause 2.5
# A failure: status, inline error, diagnostic; the session survives
keys 18G; pause 0.5; typ ' rr'; pause 3
# Output streams in while it runs
keys 20G; pause 0.5; typ ' rr'; pause 4.5
# Edit the setup region: it is re-applied on the next run
keys 6G; pause 0.5; keys 0 f 4 r 2; pause 2
keys 13G; typ ' rr'; pause 2.5
# Run a selection
keys 13G V 3j; pause 0.8; typ ' r'; pause 2.5
# A scratch buffer attached to the same session
typ ':Sh scratch'; keys Enter; pause 1
typ 'iecho "older: $older"'; keys Escape; pause 0.5; typ ' rr'; pause 3
keys ':q!' Enter; pause 0.5
# Everything that can be done at the cursor
keys 16G; typ ' rc'; pause 3; keys Escape; pause 1
typ ':qa!'; keys Enter

wait "$recording"
# Drop the recorded command: it contains local paths.
{ head -1 demo/demo.cast | jq -c 'del(.command)'; tail -n +2 demo/demo.cast; } >demo/demo.cast.tmp && mv demo/demo.cast.tmp demo/demo.cast
agg --theme monokai --font-size 16 demo/demo.cast demo/demo.gif
echo "Recorded demo/demo.cast and demo/demo.gif"
