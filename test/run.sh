#!/usr/bin/env bash
# Run the test suite in Vim and Neovim.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
export TEST_RESULT
TEST_RESULT=$(mktemp)
for editor in vim nvim; do
  command -v "$editor" >/dev/null || continue
  echo "== $editor"
  if [[ $editor == vim ]]; then
    cmd=(vim -Nu NONE -i NONE -es)
  else
    cmd=(nvim --headless -u NONE -i NONE)
  fi
  : >"$TEST_RESULT"
  "${cmd[@]}" --cmd 'set rtp^=.' -c 'filetype plugin on | syntax on' -S test/test_shell.vim </dev/null || status=1
  cat "$TEST_RESULT"
done
rm -f "$TEST_RESULT"
exit $status
