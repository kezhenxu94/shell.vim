# shell.vim

Run parts of a plain `.sh`/`.zsh` file in a persistent shell session, from Vim 9 or Neovim. There are no dependencies.

![shell.vim demo](demo/demo.gif)

Use it with scripts that are already checked into your repo. Load the helpers once, then run one step at a time. Variables, functions and `cd` carry over between runs, and `exit`, `die` or `set -e` can't kill the session.

## Why not slime, iron, sniprun, molten…?

Other plugins give you some of these features, but none gives you all of them together:

| | Persistent state | Per-run output in a window | Exit code | Plain `.sh` | Vim 9 |
|---|---|---|---|---|---|
| vim-slime, vimux, iron, yarepl, toggleterm | yes (terminal or tmux pane) | no, mixed into the terminal with prompt and echo noise | no | yes | slime and vimux only |
| sniprun | no, re-runs earlier snippets | yes | errors only | yes | no |
| molten + bash_kernel | yes (Jupyter kernel) | yes | yes | cells only | no, needs Python and Jupyter |
| runme | exported env only | no, a shared terminal | yes | Markdown only | no |
| vim-medieval | no, re-runs earlier blocks | yes | no | Markdown only | yes |
| **shell.vim** | **yes, survives `exit` and `set -e`** | **yes, one header per run** | **yes, as a diagnostic** | **yes** | **yes** |

What sets it apart:

- **A real session that can't die.** Each run is forked from the session shell, and its final state is written back: variables, arrays, functions, aliases, shell options, `$1…` and `cd`. A guard's `exit 1`, `die`, a `set -euo pipefail` failure or `<C-c>` ends only that run.
- **Your script stays a script.** It works on ordinary `.sh`/`.zsh` files, not notebooks, cells, Markdown or a custom file type. The session follows the file's shebang, so a bash script gets bash and a zsh script gets zsh.
- **Definitions are always in place.** Put `# @setup` … `# @end` comments around your defaults and helpers. Before a run below that region, shell.vim applies the region if this session hasn't applied it yet or if its text has changed. If neither is true, it leaves the region alone, so the state your runs collected is kept. When you run the file as a script, the markers are just comments.
- **Clean, per-run output.** A pipe, not a pty, so there's no prompt, echo or OSC noise. Each run gets its own header with exit code, duration and directory, and ANSI colors are rendered. stdin is `/dev/null`, so commands like `cat` and `ssh` can't hang the session.
- **Results in the editor, not in your script.** Status, signs, diagnostics and history are shown as virtual text, and the buffer is never modified.

## Features

- Run the command under the cursor (`<LocalLeader>rr`), a selection, a range, everything up to the cursor line (`:Sh tocursor`, `<LocalLeader>rtc`), the whole buffer (`<LocalLeader>ral`), or the saved file in a fresh process (`<LocalLeader>rf`).
- Output streams into a preview split named after the script (`[Shell] tests/alliance.sh`). Each run gets a header (`── L12-15 · exit 0 · 230ms · ~/proj`), then the code that ran, then its output.
- A failed run becomes a diagnostic on its first line, so `]d` jumps between failures.
- Results appear in the script as virtual text: an inline status (`✓ 230ms`, `✗ exit 1`), a sign on lines that ran, the status of each setup region, optional inline output, and a codelens with each command's history.
- `:Sh scratch` opens a scratch buffer attached to the session, for ad-hoc commands that shouldn't go into the script.
- Every execution is saved to a history file in the state directory. You can review it from the codelens, `:Sh history`, the `:Sh actions` menu (`<LocalLeader>rc`) or the right-click menu.

See `:help shell.vim`.

## Install

Add it as a package, for example under `pack/vendor/start/shell.vim`.

## Tests

```sh
make test       # headless, in Vim and Neovim
make test-e2e   # Vim and Neovim in tmux, driven with the default mappings, checking the screen
```

Both take the editors to run as arguments, e.g. `test/e2e.sh nvim`. `make demo` regenerates the GIF above with tmux, [asciinema](https://asciinema.org) and [agg](https://github.com/asciinema/agg).
