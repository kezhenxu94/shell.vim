# shell.vim

Run parts of a plain `.sh`/`.zsh` file in a persistent shell session, from Vim 9 or Neovim. There are no dependencies.

- Run the command under the cursor (`<LocalLeader>rr`), a selection, a range, everything up to the cursor line (`:Sh tocursor`, `<LocalLeader>rtc`), the whole buffer (`<LocalLeader>ral`), or the saved file in a fresh process (`<LocalLeader>rf`).
- Variables, arrays, functions, aliases, `set -euo pipefail`, `$1…` and `cd` carry over between runs.
- `exit`, `die` and `set -e` failures end only that run. The session survives.
- Output streams into a preview split named after the script (`[Shell] tests/alliance.sh`). Each run gets a header (`── L12-15 · exit 0 · 230ms · ~/proj`), then the code that ran, then its output, with ANSI colors.
- A failed run becomes a diagnostic on its first line.
- `# @setup` … `# @end` comments mark definitions. They are applied automatically before runs below them, and re-applied when edited.
- `:Sh scratch` opens a scratch buffer attached to the session, for ad-hoc commands that shouldn't go into the script.
- Results show up in the script as virtual text, without changing it: an inline status (`✓ 230ms`, `✗ exit 1`), a ran sign, setup-region status, optional inline output, and a codelens with each command's history.
- Every execution is saved to a history file in the state directory. You can review it from the codelens, `:Sh history`, the `:Sh actions` menu (`<LocalLeader>rc`) or the right-click menu.

Each run is forked from the session shell, and its final state is written back. See `:help shell.vim`.

## Install

Add it as a package, for example under `pack/vendor/start/shell.vim`.

## Tests

```sh
test/run.sh   # headless, in Vim and Neovim
```
