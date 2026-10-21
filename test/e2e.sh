#!/usr/bin/env bash
# End-to-end tests: drive Vim and Neovim in tmux with the default mappings and
# check what is drawn on the screen. Usage: test/e2e.sh [vim|nvim]...
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD

work=$(mktemp -d)
tmux=(tmux -L shell-vim-e2e -f /dev/null)
trap '"${tmux[@]}" kill-server 2>/dev/null || true; rm -rf "$work"' EXIT

failed=0
screen() { "${tmux[@]}" capture-pane -p -t e2e; }
keys() { "${tmux[@]}" send-keys -t e2e "$@"; }

# expect <description> <pattern>: wait for an extended regex on the screen.
expect() {
  local i
  for ((i = 0; i < 100; i++)); do
    screen | grep -Eq -- "$2" && echo "ok   $1" && return
    sleep 0.1
  done
  echo "FAIL $1: /$2/ not on the screen:"
  screen | sed 's/^/     | /'
  failed=1
}

# reject <description> <pattern>: the pattern is not on the screen.
reject() {
  if screen | grep -Eq -- "$2"; then
    echo "FAIL $1: /$2/ is on the screen:"
    screen | sed 's/^/     | /'
    failed=1
  else
    echo "ok   $1"
  fi
}

start() {
  local editor=$1
  rm -rf "$work/state" "$work/project"
  mkdir -p "$work/project"
  cp test/fixtures/e2e.sh "$work/project/script.sh"
  case $editor in
    vim) cmd="vim -Nu '$root/demo/vimrc' -i NONE" ;;
    nvim) cmd="nvim --clean -u '$root/demo/vimrc' -i NONE" ;;
  esac
  "${tmux[@]}" kill-server 2>/dev/null || true
  "${tmux[@]}" new-session -d -s e2e -x 140 -y 40 -c "$work/project" \
    -e XDG_STATE_HOME="$work/state" -e TERM=xterm-256color "$cmd script.sh"
  expect "$editor starts" 'script\.sh'
}

(($#)) || set -- vim nvim
for editor in "$@"; do
  command -v "$editor" >/dev/null || continue
  echo "== $editor"
  start "$editor"

  # <LocalLeader>rr runs the command under the cursor; state carries over.
  keys 6G ' rr'
  expect 'inline status after a run' 'export NAME=world +✓ [0-9]+ms'
  expect 'preview split named after the script' '── L6 · exit 0'
  keys 7G ' rr'
  expect 'setup region applied before the run' '── setup L3-3 · exit 0'
  expect 'variables and setup functions carry over' 'hello world'
  expect 'setup region status' '# @setup +● setup applied'

  # A failure gets a status and the error; the session survives it.
  keys 8G ' rr'
  expect 'failed status' '✗ exit [12] · [0-9]+ms'
  expect 'stderr in the preview' "cannot access .*/nope"
  keys 7G ' rr'
  expect 'session survives a failure' '── L7 · exit 0'

  # Codelens from the history.
  expect 'codelens counts runs' '↺ 2 runs · last ✓'

  # Editing the setup region marks it changed, and the next run re-applies it.
  keys 3G 'A # edited' Escape
  expect 'changed setup region' '◐ setup changed'
  keys 7G ' rr'
  expect 'changed setup re-applied' '# @setup +● setup applied'

  # A visual selection, then everything up to the cursor.
  keys 9G V j ' r'
  expect 'visual selection run' '── L9-10 · exit 0'
  expect 'output of the selection' 'line two'
  keys 7G ' rtc'
  expect 'run up to the cursor' '── L1-7 · exit 0'

  # The saved file in a fresh process, with the session's exported variables.
  keys ':w' Enter
  keys ' rf'
  expect 'file run' '── file script\.sh · exit 0'

  # Streaming output, and <C-c> in the preview interrupts.
  keys 12G ' rr'
  expect 'output streams while running' '⟳ running'
  expect 'first line of a long run' 'tick 1'
  # Vim flushes typeahead on <C-c>: let it switch windows first.
  keys C-w l && sleep 0.3 && keys C-c
  expect 'interrupted from the preview' '── L12-1[0-9] · exit 143'
  reject 'no output after the interrupt' '[│|]never printed *$'

  # q closes the preview; the next run reopens it.
  keys q
  reject 'preview closed' '── L12'
  keys 7G ' rr'
  expect 'preview reopened' '── L7 · exit 0'

  # :Sh scratch shares the session.
  keys ':Sh scratch' Enter
  keys 'iecho "scratch sees $NAME"' Escape ' rr'
  expect 'scratch shares the session' 'scratch sees world'
  keys ':qa!' Enter
done

exit $failed
