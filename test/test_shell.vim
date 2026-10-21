" Headless tests for Vim and Neovim. Run via test/run.sh.

set virtualedit=onemore hidden
let g:shell_init = ''
runtime plugin/shell.vim
let s:fixtures = fnamemodify('test/fixtures', ':p')
let s:tmp = fnamemodify(tempname(), ':p')
call mkdir(s:tmp, 'p')
let g:shell_history_dir = s:tmp . '/history'

" ------------------------------------------------------------------ helpers

" Edit a fresh buffer named name (in a temp dir) holding lines.
function! s:buf(name, lines, ...) abort
  execute 'edit! ' . fnameescape(s:tmp . '/' . a:name)
  silent %delete _
  call setline(1, a:lines)
  if a:0
    execute 'setfiletype ' . a:1
  endif
endfunction

function! s:wait(...) abort
  let start = reltime()
  while shell#busy() && reltimefloat(reltime(start)) < get(a:, 1, 10)
    sleep 20m
  endwhile
  call assert_false(shell#busy(), 'timed out waiting for the run')
endfunction

function! s:preview() abort
  return getbufline(shell#preview#bufnr(), 1, '$')
endfunction

" Run lines l1..l2 of the current buffer and return the preview.
function! s:run(l1, ...) abort
  execute a:l1 . ',' . get(a:, 1, a:l1) . 'Sh'
  call s:wait()
  return s:preview()
endfunction

" Output lines of the preview (headers and echoed code dropped).
function! s:out() abort
  return filter(s:preview(), 'v:val !~# "^\\%(── \\|[$>] \\)"')
endfunction

" Run lines l1..l2 and return their output.
function! s:run_out(l1, ...) abort
  call s:run(a:l1, get(a:, 1, a:l1))
  return s:out()
endfunction

function! s:reset() abort
  call shell#stop_all()
  let g:shell_inline_output = 0
  unlet! g:shell_setup_markers
  let g:shell_session = 'buffer'
  let g:shell_init = ''
  silent! %bwipe!
endfunction

" ------------------------------------------------------------------ parsing

function! Test_parse_statements() abort
  let lines = [
        \ '# comment {',
        \ 'echo one; echo two',
        \ '',
        \ 'curl -s \',
        \ '  -H "a: b" \',
        \ '  https://x',
        \ 'if [ -n "$x" ]; then',
        \ '  echo "fi done esac }"',
        \ 'fi',
        \ 'for i in 1 2; do',
        \ '  case $i in',
        \ '    1) echo one ;;',
        \ '    (2) echo $(date) ;;',
        \ '  esac',
        \ 'done',
        \ 'cat <<-EOF | jq .',
        \ '	{"if": "("}',
        \ '	EOF',
        \ 'f() {',
        \ '  echo "${x:-}" # }',
        \ '}',
        \ 'function g {',
        \ '  echo '' unbalanced ( ''',
        \ '}',
        \ 'x="multi',
        \ 'line"',
        \ 'false &&',
        \ '  true ||',
        \ '  echo no',
        \ 'echo $((1 + (2)))',
        \ 'echo done',
        \ 'while true; do break; done',
        \ '{ echo a; echo b; }',
        \ 'echo $x#notcomment',
        \ 'r=$(curl -s \',
        \ '  x)',
        \ 'cat <<< "here"',
        \ 'sleep 1 &',
        \ ]
  let got = map(shell#parse#statements(lines), '[v:val.start, v:val.end]')
  call assert_equal([[2, 2], [4, 6], [7, 9], [10, 15], [16, 18], [19, 21], [22, 24], [25, 26],
        \ [27, 29], [30, 30], [31, 31], [32, 32], [33, 33], [34, 34], [35, 36], [37, 37], [38, 38]], got)
endfunction

function! Test_parse_regions() abort
  let lines = ['a', '# @setup', 'x=1', 'f() { :; }', '  # @end  ', '# @setup', '# @end', '# @setup', 'unterminated']
  let regions = shell#parse#regions(lines)
  call assert_equal([[3, 4], [7, 6]], map(copy(regions), '[v:val.start, v:val.end]'))
  call assert_equal(sha256("x=1\nf() { :; }"), regions[0].hash)
  let g:shell_setup_markers = ['# region setup', '# endregion']
  call assert_equal([[3, 3]], map(shell#parse#regions(['a', '# region setup', 'b', '# endregion']), '[v:val.start, v:val.end]'))
  unlet g:shell_setup_markers
endfunction

function! Test_statement_range() abort
  call s:reset()
  call s:buf('range.sh', readfile(s:fixtures . 'alliance.sh'), 'sh')
  call assert_equal([4, 4], shell#statement_range(4))
  call assert_equal([], shell#statement_range(2))
  call assert_equal([], shell#statement_range(5))
  call assert_equal([14, 14], shell#statement_range(14))
  call setline(14, ['step_me() {', '  log me', '}'])
  call assert_equal([14, 16], shell#statement_range(15))
endfunction

function! Test_treesitter_range() abort
  if !has('nvim') || !luaeval('require("shell.ts").available()')
    return
  endif
  call s:reset()
  call s:buf('ts.sh', ['echo a; echo b', 'cat <<EOF', 'body', 'EOF', '# c', 'if true', 'then :', 'fi'], 'sh')
  let R = {l -> luaeval('require("shell.ts").range(0, _A)', l)}
  call assert_equal([1, 1], R(1))
  call assert_equal([2, 4], R(3))
  call assert_equal(v:null, R(5))
  call assert_equal([6, 8], R(7))
  " zsh-only syntax the bash parser rejects falls back to the scanner.
  call s:buf('ts.zsh', ['parts=(${(s.:.)res})', 'echo'], 'zsh')
  call assert_equal([1, 1], shell#statement_range(1))
endfunction

function! Test_shell_for() abort
  call s:reset()
  call s:buf('a.sh', ['#!/usr/bin/env bash'], 'sh')
  call assert_equal('bash', shell#shell_for(bufnr('%')))
  call s:buf('b.sh', ['#!/bin/zsh'], 'sh')
  call assert_equal('zsh', shell#shell_for(bufnr('%')))
  call s:buf('c.sh', ['#!/bin/sh'], 'sh')
  call assert_equal('bash', shell#shell_for(bufnr('%')))
  call s:buf('d.zsh', ['echo'], 'zsh')
  call assert_equal('zsh', shell#shell_for(bufnr('%')))
  let shell = $SHELL
  let $SHELL = '/bin/fish'
  call s:buf('e.sh', ['echo'], 'sh')
  call assert_equal('bash', shell#shell_for(bufnr('%')))
  let $SHELL = '/usr/bin/zsh'
  call assert_equal('zsh', shell#shell_for(bufnr('%')))
  let $SHELL = shell
endfunction

function! Test_ansi() abort
  let state = {}
  let [text, spans] = shell#preview#ansi("\e[1;34m==> me\e[0m plain \e[31mred", state)
  call assert_equal('==> me plain red', text)
  call assert_equal([[0, 6, 'ShellAnsi4Bold'], [13, 3, 'ShellAnsi1']], spans)
  " SGR state carries to the next line of the run.
  call assert_equal(['more', [[0, 4, 'ShellAnsi1']]], shell#preview#ansi('more', state))
  call assert_equal(['done', []], shell#preview#ansi("10%\r50%\rdone\r", {}))
  call assert_equal(['title x', []], shell#preview#ansi("\e]0;t\x07title \e[2Kx\e[?25l", {}))
  call assert_equal(['b', [[0, 1, 'ShellAnsi9']]], shell#preview#ansi("\e[38;5;9mb\e[38;2;1;2;3m", {}))
endfunction

function! Test_complete() abort
  call assert_equal(['run', 'restart'], shell#complete('r', 'Sh r', 4))
  call assert_equal([], shell#complete('', 'Sh file ', 8))
  call assert_equal(['tocursor'], getcompletion('Sh to', 'cmdline'))
endfunction

" ------------------------------------------------------------------ engine

function! s:check_state(shell) abort
  call s:reset()
  call s:buf('state.' . a:shell, ['#!/bin/' . a:shell,
        \ 'export A=1; arr=(x "y z"); greet() { echo "hi $1"; }',
        \ 'cd /tmp',
        \ 'echo "A=$A pwd=$(pwd -P) arr=${arr[@]}"; greet you',
        \ 'set -- p1 "p 2"',
        \ 'echo "$# $2"',
        \ 'unset A; alias hey="echo alias-ok"',
        \ 'echo "A=${A-unset}"; hey'])
  call s:run(2)
  call s:run(3)
  call s:run(4)
  call assert_equal(['A=1 pwd=' . resolve('/tmp') . ' arr=x y z', 'hi you'], s:out())
  call assert_match('^── L4 · exit 0 · \d\+ms · /tmp$', s:preview()[0])
  call s:run(5)
  call s:run(6)
  call assert_equal(['2 p 2'], s:out())
  call s:run(7)
  call s:run(8)
  call assert_equal(['A=unset', 'alias-ok'], s:out())
endfunction

function! Test_state_bash() abort
  call s:check_state('bash')
endfunction

function! Test_state_zsh() abort
  call s:check_state('zsh')
endfunction

function! s:check_strict(shell) abort
  call s:reset()
  call s:buf('strict.' . a:shell, ['#!/bin/' . a:shell, 'set -euo pipefail', 'false; echo after', 'echo ok', 'exit 3', 'set +e', 'false; echo reached'])
  call s:run(2)
  call assert_equal([], s:run_out(3))
  call assert_match('^── L3 · exit 1 ·', s:preview()[0])
  call assert_equal(['ok'], s:run_out(4))
  call assert_match('exit 3', s:run(5)[0])
  " set -e from L2 still applies after runs that died from it.
  call assert_equal([], s:run_out(3))
  call s:run(6)
  call assert_equal(['reached'], s:run_out(7))
endfunction

function! Test_strict_bash() abort
  call s:check_strict('bash')
endfunction

function! Test_strict_zsh() abort
  call s:check_strict('zsh')
endfunction

function! Test_stdin_is_null() abort
  call s:reset()
  call s:buf('stdin.sh', ['cat; echo after-cat'], 'sh')
  call assert_equal(['after-cat'], s:run_out(1, 1))
endfunction

function! Test_dollar_zero_and_cwd() abort
  call s:reset()
  let repo = s:tmp . '/repo'
  call mkdir(repo . '/tests', 'p')
  call system('git -C ' . shellescape(repo) . ' init -q')
  for shell in ['bash', 'zsh']
    execute 'edit! ' . fnameescape(repo . '/tests/x.sh')
    silent %delete _
    call setline(1, ['#!/bin/' . shell, 'echo "$0"; pwd -P'])
    call assert_equal([fnamemodify(repo . '/tests/x.sh', ':p'), resolve(repo)], s:run_out(2))
    call s:reset()
  endfor
  " Outside a repository the session starts in the file's directory.
  call s:buf('nogit.sh', ['pwd -P'], 'sh')
  call assert_equal([resolve(s:tmp)], s:run_out(1))
endfunction

function! Test_streaming() abort
  call s:reset()
  call s:buf('stream.sh', ['echo first; sleep 1; echo second'], 'sh')
  1Sh
  let start = reltime()
  while index(s:preview(), 'first') < 0 && reltimefloat(reltime(start)) < 5
    sleep 20m
  endwhile
  call assert_true(shell#busy(), 'output should arrive before the run ends')
  call assert_equal(['first'], s:out())
  call s:wait()
  call assert_equal(['first', 'second'], s:out())
endfunction

function! Test_interrupt() abort
  call s:reset()
  call s:buf('int.sh', ['KEEP=yes', 'echo started; sleep 100; echo never', 'echo "KEEP=$KEEP"'], 'sh')
  call s:run(1)
  2Sh
  let start = reltime()
  while index(s:preview(), 'started') < 0 && reltimefloat(reltime(start)) < 5
    sleep 20m
  endwhile
  Sh interrupt
  call s:wait(3)
  call assert_match('^── L2 · exit 143 ·', s:preview()[0])
  call assert_equal(['started'], s:out())
  call assert_equal(['KEEP=yes'], s:run_out(3))
endfunction

function! Test_init() abort
  for shell in ['bash', 'zsh']
    call s:reset()
    let g:shell_init = 'alias hello="echo hello from init"' . "\n" . 'INIT_VAR=1'
    call s:buf('init.' . shell, ['#!/bin/' . shell, 'hello; echo "$INIT_VAR"'])
    call assert_equal(['hello from init', '1'], s:run_out(2))
  endfor
endfunction

function! Test_restart() abort
  call s:reset()
  call s:buf('restart.sh', ['X=1', 'echo "X=${X-none}"'], 'sh')
  call s:run(1)
  call assert_equal(['X=1'], s:run_out(2))
  Sh restart
  call assert_equal({}, shell#session())
  call assert_equal(['X=none'], s:run_out(2))
endfunction

function! Test_session_per_buffer_or_cwd() abort
  call s:reset()
  call s:buf('one.sh', ['V=one'], 'sh')
  call s:run(1)
  call s:buf('two.sh', ['echo "V=${V-}"'], 'sh')
  call assert_equal(['V='], s:run_out(1))
  call s:reset()
  let g:shell_session = 'cwd'
  call s:buf('one.sh', ['V=one'], 'sh')
  call s:run(1)
  call s:buf('two.sh', ['echo "V=${V-}"'], 'sh')
  call assert_equal(['V=one'], s:run_out(1))
endfunction

function! Test_sessions_are_independent() abort
  call s:reset()
  call s:buf('a.sh', ['X=a', 'echo "X=$X"'], 'sh')
  let a = bufnr('%')
  call s:run(1)
  call s:buf('b.sh', ['X=b', 'echo "X=$X"'], 'sh')
  call s:run(1)
  call assert_equal(['X=b'], s:run_out(2))
  execute 'buffer ' . a
  call assert_equal(['X=a'], s:run_out(2))
endfunction

function! Test_wipeout_stops_session() abort
  call s:reset()
  call s:buf('wipe.sh', ['echo'], 'sh')
  call s:run(1)
  let sess = shell#session()
  call assert_false(empty(sess))
  let dir = sess.dir
  bwipe!
  call assert_true(get(sess, 'stopped', 0))
  call assert_false(isdirectory(dir))
endfunction

" ------------------------------------------------------------------ ui

function! Test_diagnostics_and_signs() abort
  call s:reset()
  call s:buf('diag.sh', ['echo ok', '[ -z "${nope:-}" ] && {', '  echo "usage: nope=..." >&2; exit 1', '}', 'true'], 'sh')
  call s:run(1)
  call s:run(2, 4)
  call assert_equal([[2, 'usage: nope=...']], shell#compat#diagnostics(bufnr('%')))
  call assert_equal([1, 2, 3, 4], shell#mark#ran_lines(bufnr('%')))
  " A passing run over the same lines clears the diagnostic.
  call setline(2, 'true || {')
  call s:run(2, 4)
  call assert_equal([], shell#compat#diagnostics(bufnr('%')))
  call s:run(5)
  Sh restart
  call assert_equal([], shell#mark#ran_lines(bufnr('%')))
endfunction

function! Test_preview_ansi_highlight() abort
  call s:reset()
  call s:buf('color.sh', ['printf ''\033[1;34mblue\033[0m plain\n'''], 'sh')
  call assert_equal(['blue plain'], s:run_out(1))
  call assert_equal('$ printf ''\033[1;34mblue\033[0m plain\n''', s:preview()[1])
  let buf = shell#preview#bufnr()
  if has('nvim')
    let marks = nvim_buf_get_extmarks(buf, -1, [2, 0], [2, -1], {'details': 1})
    call assert_equal('ShellAnsi4Bold', marks[0][3].hl_group)
    call assert_equal(4, marks[0][3].end_col)
  else
    let props = prop_list(3, {'bufnr': buf})
    call assert_equal([['ShellAnsi4Bold', 1, 4]], map(props, '[v:val.type, v:val.col, v:val.length]'))
  endif
  call assert_notequal(-1, bufwinid(buf))
  call assert_equal(0, getbufvar(buf, '&modifiable'))
endfunction

function! Test_keys() abort
  call s:reset()
  call s:buf('keys.sh', ['echo one', 'echo two', 'echo three'], 'sh')
  call cursor(2, 1)
  execute "normal \\rr"
  call s:wait()
  call assert_equal(['two'], s:out())
  execute "normal 1GVj\\r"
  call s:wait()
  call assert_equal(['one', 'two'], s:out())
  execute "normal \\ral"
  call s:wait()
  call assert_match('^── L1-3 ', s:preview()[0])
  call assert_equal(['one', 'two', 'three'], s:out())
  call cursor(3, 1)
  execute "normal \\rtc"
  call s:wait()
  call assert_match('^── L1-2 ', s:preview()[0])
  " <C-c> in the preview interrupts, q closes it.
  call setline(1, 'sleep 100')
  1Sh
  call win_gotoid(bufwinid(shell#preview#bufnr()))
  execute "normal \<C-c>"
  call s:wait(3)
  call assert_match('exit 143', s:preview()[0])
  normal q
  call assert_equal(-1, bufwinid(shell#preview#bufnr()))
endfunction

function! Test_mappings() abort
  call s:reset()
  call s:buf('map.sh', ['echo x'], 'sh')
  call assert_match('shell-run', maparg('<LocalLeader>rr', 'n'))
  call assert_match('shell-run-selection', maparg('<LocalLeader>r', 'x'))
  call assert_match('shell-run-tocursor', maparg('<LocalLeader>rtc', 'n'))
  call assert_match('shell-run-file', maparg('<LocalLeader>rf', 'n'))
  call assert_match('shell-actions', maparg('<LocalLeader>rc', 'n'))
  call assert_match('shell-run-all', maparg('<LocalLeader>ral', 'n'))
  call assert_equal('', maparg('<LocalLeader>ra', 'n'))
  call assert_match('shell-history', maparg('<LocalLeader>rh', 'n'))
  let g:shell_no_mappings = 1
  call s:buf('nomap.sh', ['echo x'], 'sh')
  call assert_equal('', maparg('<LocalLeader>rr', 'n'))
  unlet g:shell_no_mappings
endfunction

" ------------------------------------------------------------------ marks

" The run mark on lnum of the current buffer.
function! s:mark(lnum) abort
  let ids = shell#mark#overlapping(bufnr('%'), a:lnum, a:lnum)
  call assert_equal(1, len(ids), 'one run mark on line ' . a:lnum)
  return get(ids, 0, -1)
endfunction

function! s:wait_for(expr) abort
  let start = reltime()
  while !eval(a:expr) && reltimefloat(reltime(start)) < 5
    sleep 20m
  endwhile
endfunction

function! Test_inline_status() abort
  call s:reset()
  call s:buf('status.sh', ['sleep 0.5', 'echo queued', 'false'], 'sh')
  1Sh
  2Sh
  let buf = bufnr('%')
  call assert_equal('⟳ running', shell#mark#status(buf, s:mark(1)))
  call assert_equal('… queued', shell#mark#status(buf, s:mark(2)))
  call s:wait()
  call assert_match('^✓ \d\+ms$', shell#mark#status(buf, s:mark(1)))
  call s:run(3)
  call assert_match('^✗ exit 1 · \d\+ms$', shell#mark#status(buf, s:mark(3)))
  " Running the same lines again replaces the result.
  call setline(3, 'true')
  call s:run(3)
  call assert_match('^✓ ', shell#mark#status(buf, s:mark(3)))
endfunction

function! Test_marks_follow_edits() abort
  call s:reset()
  call s:buf('edits.sh', ['echo top', 'sleep 0.5; echo "usage: x"; false'], 'sh')
  2Sh
  " Edit above the command while it runs.
  call append(0, ['# new 1', '# new 2'])
  call s:wait()
  call assert_equal([4, 4], shell#mark#range(bufnr('%'), s:mark(4)))
  call assert_equal([[4, 'usage: x']], shell#compat#diagnostics(bufnr('%')))
  call assert_equal([4], shell#mark#ran_lines(bufnr('%')))
endfunction

function! Test_interrupt_drops_queued_marks() abort
  call s:reset()
  call s:buf('drop.sh', ['echo started; sleep 100', 'echo never'], 'sh')
  1Sh
  2Sh
  call s:wait_for('index(s:preview(), "started") >= 0')
  Sh interrupt
  call s:wait(3)
  call assert_equal([], shell#mark#overlapping(bufnr('%'), 2, 2))
  call assert_match('^✗ exit 143', shell#mark#status(bufnr('%'), s:mark(1)))
endfunction

function! Test_inline_output() abort
  call s:reset()
  let g:shell_inline_output = 2
  call s:buf('inline.sh', ['printf "a\\nb\\n\\033[31mc\\033[0m\\n"', 'echo one'], 'sh')
  call s:run(1)
  call assert_equal(['│ … 1 more in [Shell]', '│ b', '│ c'], shell#mark#lines(bufnr('%'), s:mark(1)))
  call s:run(2)
  call assert_equal(['│ one'], shell#mark#lines(bufnr('%'), s:mark(2)))
  let g:shell_inline_output = 0
  call s:run(2)
  call assert_equal([], shell#mark#lines(bufnr('%'), s:mark(2)))
endfunction

function! Test_region_status() abort
  call s:reset()
  call s:buf('regions.sh', ['echo before', '# @setup', 'X=1', '# @end', 'echo "$X"'], 'sh')
  let buf = bufnr('%')
  call assert_equal('', shell#mark#region_status(buf, 2))
  call s:run(1)
  call assert_equal('○ setup not applied', shell#mark#region_status(buf, 2))
  call s:run(5)
  call assert_equal('● setup applied', shell#mark#region_status(buf, 2))
  call setline(3, 'X=2')
  doautocmd TextChanged
  call assert_equal('◐ setup changed · re-applied on next run', shell#mark#region_status(buf, 2))
  call assert_equal(['2'], s:out()[-1:] == ['1'] ? s:run(5)[-1:] : ['2'])
  call assert_equal('● setup applied', shell#mark#region_status(buf, 2))
  Sh restart
  call assert_equal('', shell#mark#region_status(buf, 2))
endfunction

function! Test_preview_named_after_file() abort
  call s:reset()
  call s:buf('a.sh', ['echo from a'], 'sh')
  let a = shell#script(bufnr('%'))
  call s:run(1)
  let pa = shell#preview#bufnr()
  call assert_equal('[Shell] ' . fnamemodify(a, ':~:.'), bufname(pa))
  call s:buf('b.sh', ['echo from b'], 'sh')
  call s:run(1)
  let pb = shell#preview#bufnr()
  call assert_notequal(pa, pb)
  call assert_match('b\.sh$', bufname(pb))
  " One preview window, now showing b; a keeps its output.
  call assert_equal(1, len(filter(range(1, winnr('$')), 'getbufvar(winbufnr(v:val), "shell_preview", 0)')))
  call assert_notequal(-1, bufwinid(pb))
  call assert_equal(['$ echo from a', 'from a'], getbufline(pa, 2, '$'))
  " A scratch buffer uses its script's preview; history too.
  Sh scratch
  call setline(1, 'echo scratch')
  call s:run(1)
  call assert_equal(pb, shell#preview#bufnr())
  call shell#history#show(shell#history#list(a)[-1])
  call assert_equal(pa, shell#preview#bufnr())
  call assert_notequal(-1, bufwinid(pa))
  " A buffer without a name uses plain [Shell].
  enew
  setfiletype sh
  call setline(1, 'echo')
  call s:run(1)
  call assert_equal('[Shell]', bufname(shell#preview#bufnr()))
endfunction

function! Test_preview_header_and_jump() abort
  call s:reset()
  call s:buf('jump.sh', ['echo one', 'echo two', 'false'], 'sh')
  let src = bufnr('%')
  call s:run(2)
  call s:run(3)
  let pbuf = shell#preview#bufnr()
  if has('nvim')
    let groups = map(nvim_buf_get_extmarks(pbuf, -1, [0, 0], [0, -1], {'details': 1}), 'v:val[3].hl_group')
  else
    let groups = map(prop_list(1, {'bufnr': pbuf}), 'v:val.type')
  endif
  call assert_notequal(-1, index(groups, 'ShellHeader'))
  call assert_notequal(-1, index(groups, 'ShellFail'))
  " <CR> in the preview jumps to the source lines, which follow edits.
  call append(0, '# shifted')
  call win_gotoid(bufwinid(pbuf))
  call cursor(1, 1)
  execute "normal \<CR>"
  call assert_equal(src, bufnr('%'))
  call assert_equal(4, line('.'))
endfunction

" ------------------------------------------------------------------ history

function! s:script() abort
  return shell#script(bufnr('%'))
endfunction

function! Test_history_recorded() abort
  call s:reset()
  call s:buf('hist.sh', ['printf "\033[31mred\033[0m\n"; false', 'echo "$((1 + 1))"'], 'sh')
  call s:run(1)
  call s:run(2)
  let file = shell#history#file(s:script())
  call assert_equal(g:shell_history_dir . '/' . substitute(s:script(), '/', '%', 'g') . '.jsonl', file)
  call assert_equal('rw-------', getfperm(file))
  call assert_equal('rwx------', getfperm(g:shell_history_dir))
  let entries = shell#history#list(s:script())
  call assert_equal(2, len(entries))
  let e = entries[0]
  call assert_equal(['L1', 1, "\e[31mred\e[0m", shell#shell_for(bufnr('%'))], [e.label, e.status, e.output[0], e.shell])
  call assert_equal(getline(1), e.code)
  call assert_equal(sha256(getline(1)), e.hash)
  call assert_equal(['L2', 0, ['2']], [entries[1].label, entries[1].status, entries[1].output])
  call assert_equal(1, len(shell#history#for_code(s:script(), getline(2))))
  " History survives a restart.
  Sh restart
  call assert_equal(2, len(shell#history#list(s:script())))
endfunction

function! Test_history_limits() abort
  call s:reset()
  let g:shell_history_max = 3
  let g:shell_history_output = 2
  call s:buf('limits.sh', ['seq 5'], 'sh')
  for i in range(5)
    call s:run(1)
  endfor
  let entries = shell#history#list(s:script())
  call assert_equal(3, len(entries))
  call assert_equal([['1', '2'], 3], [entries[-1].output, entries[-1].truncated])
  unlet g:shell_history_max g:shell_history_output
  let g:shell_history = 0
  call s:buf('off.sh', ['echo'], 'sh')
  call s:run(1)
  call assert_false(filereadable(shell#history#file(s:script())))
  unlet g:shell_history
endfunction

function! Test_history_show() abort
  call s:reset()
  call s:buf('show.sh', ['echo one', 'echo two; exit 2'], 'sh')
  call s:run(1, 2)
  let e = shell#history#list(s:script())[-1]
  call shell#preview#clear(shell#preview#bufnr())
  call shell#history#show(e)
  let out = s:preview()
  call assert_match('^── history L1-2 · exit 2 · \d\+ms · \d\{4}-\d\d-\d\d \d\d:\d\d:\d\d · ', out[0])
  call assert_equal(['$ echo one', '> echo two; exit 2', 'one', 'two'], out[1:])
endfunction

function! Test_codelens() abort
  call s:reset()
  call s:buf('lens.sh', ['# lens', 'echo ok', 'false', 'f() {', '  echo in f', '}'], 'sh')
  let buf = bufnr('%')
  call assert_equal([], shell#lens#get(buf))
  call s:run(2)
  call s:run(2)
  call s:run(3)
  call s:run(4, 6)
  let lens = shell#lens#get(buf)
  call assert_equal([2, 3, 4], map(copy(lens), 'v:val[0]'))
  call assert_match('^↺ 2 runs · last ✓ \d\+ms · just now$', lens[0][1])
  call assert_match('^↺ 1 run · last ✗ exit 1 · \d\+ms · just now$', lens[1][1])
  " Lenses follow the code, and go when it changes.
  call append(0, '# shifted')
  call setline(4, 'false # edited')
  doautocmd TextChanged
  call assert_equal([3, 5], map(shell#lens#get(buf), 'v:val[0]'))
  " They come from the history on disk, without a session.
  write
  let path = expand('%:p')
  call s:reset()
  execute 'edit ' . fnameescape(path)
  call assert_equal([3, 5], map(shell#lens#get(bufnr('%')), 'v:val[0]'))
  let g:shell_codelens = 0
  doautocmd TextChanged
  call assert_equal([], shell#lens#get(bufnr('%')))
  unlet g:shell_codelens
endfunction

function! Test_codelens_scratch() abort
  call s:reset()
  call s:buf('lsrc.sh', ['echo src'], 'sh')
  Sh scratch
  call setline(1, 'echo from scratch')
  call s:run(1)
  call assert_match('^↺ 1 run', get(get(shell#lens#get(bufnr('%')), 0, []), 1, ''))
  call assert_equal('scratch L1', shell#history#list(shell#script(bufnr('%')))[-1].label)
endfunction

" ------------------------------------------------------------------ actions

function! s:titles() abort
  return map(shell#actions#list(), 'v:val.title')
endfunction

function! Test_actions_list() abort
  call s:reset()
  call s:buf('act.sh', ['# @setup', 'X=1', '# @end', 'echo "$X"', '', 'echo end'], 'sh')
  call cursor(5, 1)
  call assert_equal(['Run lines above the cursor (L1-4)', 'Re-apply setup regions', 'Open scratch buffer'], s:titles())
  write
  call cursor(4, 1)
  call assert_equal(['Run command (L4)', 'Run lines above the cursor (L1-3)', 'Run file', 'Re-apply setup regions', 'Open scratch buffer'], s:titles())
  call shell#actions#list()[0].Fn()
  call s:wait()
  call assert_equal(['1'], s:out())
  call assert_equal(['Run command (L4)', 'Run lines above the cursor (L1-3)', 'Run file', 'Re-apply setup regions', 'Open scratch buffer',
        \ 'History of this command (1)', 'History of this file (2)', 'Restart the session'], s:titles())
  call setline(6, 'sleep 5')
  6Sh
  call assert_notequal(-1, index(s:titles(), 'Interrupt the run'))
  Sh interrupt
  call s:wait()
endfunction

" Answer the next menu with item n.
function! s:pick(n) abort
  if has('nvim')
    call luaeval('(function(n) vim.ui.select = function(items, _, cb) cb(items[n], n) end end)(_A)', a:n)
  endif
endfunction

function! s:picked(n) abort
  if !has('nvim')
    call popup_close(popup_list()[0], a:n)
  endif
endfunction

function! Test_actions_menu() abort
  call s:reset()
  call s:buf('menu.sh', ['echo picked'], 'sh')
  call s:pick(1)
  Sh actions
  call s:picked(1)
  call s:wait()
  call assert_equal(['picked'], s:out())
endfunction

function! Test_history_menu() abort
  call s:reset()
  call s:buf('hmenu.sh', ['echo "n=$N"', 'N=1'], 'sh')
  call s:run(1)
  call s:run(2)
  call s:run(1)
  call cursor(1, 1)
  " Newest first: the second run of line 1 (n=1).
  call shell#preview#clear(shell#preview#bufnr())
  call s:pick(1)
  Sh history
  call s:picked(1)
  call assert_match('^── history L1 · exit 0', s:preview()[0])
  call assert_equal(['$ echo "n=$N"', 'n=1'], s:preview()[1:])
  " On a line without history: the file's history.
  call setline(3, 'echo new')
  call cursor(3, 1)
  call s:pick(3)
  Sh history
  call s:picked(3)
  call assert_equal(['$ echo "n=$N"', 'n='], s:preview()[1:])
endfunction

function! Test_popup_menu() abort
  if !has('menu')
    return
  endif
  call s:reset()
  call s:buf('popup.sh', ['echo from popup'], 'sh')
  write
  call s:run(1)
  call shell#actions#popup()
  let menu = execute('menu PopUp.Shell')
  call assert_match('Run command (L1)', menu)
  call assert_match('History', menu)
  call assert_match('✓ \d\+ms · L1 · echo from popup', menu)
  call shell#preview#clear(shell#preview#bufnr())
  execute 'emenu PopUp.Shell.Run\ command\ (L1)'
  call s:wait()
  call assert_equal(['from popup'], s:out())
  call shell#actions#popup()
  execute 'emenu PopUp.Shell.History.' . escape(shell#history#title(shell#history#list(s:script())[-1]), ' .\')
  call assert_match('^── history L1', s:preview()[0])
endfunction

" ------------------------------------------------------------------ commands

function! Test_run_statement_and_tocursor() abort
  call s:reset()
  call s:buf('tocursor.sh', ['A=1', 'B=$((A + 1))', 'if [ "$B" = 2 ]; then', '  echo "B=$B"', 'fi'], 'sh')
  call cursor(3, 1)
  Sh tocursor
  call s:wait()
  call assert_match('^── L1-2 ·', s:preview()[0])
  call cursor(4, 1)
  Sh
  call s:wait()
  call assert_match('^── L3-5 ·', s:preview()[0])
  call assert_equal(['B=2'], s:out())
endfunction

function! Test_file() abort
  call s:reset()
  call s:buf('file.sh', ['#!/bin/bash', 'echo "arg=$1 exported=${E-} local=${U-} cwd=$(basename "$PWD")"'], 'sh')
  write
  call setline(3, 'export E=1; U=2; cd /tmp')
  call s:run(3)
  Sh file 'a b'
  call s:wait()
  call assert_match('^── file file.sh ''a b'' · exit 0', s:preview()[0])
  call assert_equal(['arg=a b exported=1 local= cwd=tmp'], s:out())
endfunction

function! Test_scratch() abort
  call s:reset()
  call s:buf('src.sh', ['#!/bin/bash', '# @setup', 'greet() { echo "hi $1 from $0"; }', '# @end'], 'sh')
  let src = bufnr('%')
  Sh scratch
  call assert_notequal(src, bufnr('%'))
  call assert_equal('sh', &filetype)
  call assert_equal('nofile', &buftype)
  call setline(1, 'greet you')
  let out = s:run(1)
  call assert_match('^── setup L3-3 · exit 0', out[0])
  call assert_equal('$ greet() { echo "hi $1 from $0"; }', out[1])
  call assert_match('^── scratch L1 · exit 0', out[2])
  call assert_equal('$ greet you', out[3])
  call assert_equal(resolve(fnamemodify(bufname(src), ':p')), resolve(matchstr(out[4], '^hi you from \zs.*')))
  call assert_true(shell#session(src) is shell#session())
  let scratch = bufnr('%')
  call win_gotoid(bufwinid(src))
  Sh scratch
  call assert_equal(scratch, bufnr('%'))
endfunction

" ------------------------------------------------------------------ setup regions

function! Test_setup_regions() abort
  call s:reset()
  call s:buf('alliance.sh', readfile(s:fixtures . 'alliance.sh'), 'sh')
  let $baseURL = 'http://api'
  " A fresh session applies the region before the snippet.
  let out = s:run(18)
  call assert_match('^── setup L9-15 · exit 0', out[0])
  call assert_equal(['$ STEPS=${STEPS:-me,nodes}', '> CALLS=${CALLS:-0}'], out[1:2])
  call assert_match('^── L18 · exit 0', out[8])
  call assert_equal(['$ has_step me && step_me', '==> me'], out[9:])
  " Unchanged region: not re-applied, so state from runs is kept.
  call assert_equal(['==> nodes'], s:run_out(19))
  call assert_equal(['done: a-42 [1,2] calls=2'], s:run_out(20))
  " Editing a function re-applies the region (CALLS keeps its value).
  call setline(11, 'log() { echo "LOG $*"; }')
  let out = s:run(19)
  call assert_match('^── setup L9-15', out[0])
  call assert_equal(['LOG nodes'], s:out())
  call assert_equal(['done: a-42 [1,2] calls=3'], s:run_out(20))
  " Running inside the region runs just that line.
  call assert_match('^── L10 ·', s:run(10)[0])
  call assert_equal(['$ CALLS=${CALLS:-0}'], s:preview()[1:])
  unlet $baseURL
endfunction

function! Test_setup_region_failure() abort
  call s:reset()
  call s:buf('fail.sh', ['# @setup', 'echo loading', 'echo "bad config" >&2; exit 4', '# @end', 'echo never'], 'sh')
  let out = s:run(5)
  call assert_equal(['── setup L2-3 failed · exit 4', '$ echo loading', '> echo "bad config" >&2; exit 4', 'loading', 'bad config'],
        \ [substitute(out[0], ' · \d\+ms.*', '', '')] + out[1:])
  call assert_equal([[2, 'bad config']], shell#compat#diagnostics(bufnr('%')))
  " Fixing it applies it and clears the diagnostic.
  call setline(3, 'echo fixed')
  call s:run(5)
  call assert_equal(['loading', 'fixed', 'never'], s:out())
  call assert_equal([], shell#compat#diagnostics(bufnr('%')))
endfunction

function! Test_setup_force_and_tocursor() abort
  call s:reset()
  call s:buf('force.sh', ['# @setup', 'N=$(( ${N:-0} + 1 ))', '# @end', 'echo "N=$N"'], 'sh')
  call cursor(4, 1)
  Sh tocursor
  call s:wait()
  " `tocursor` covered the region, so it counts as applied.
  call assert_equal(['N=1'], s:run_out(4))
  Sh setup
  call s:wait()
  call assert_equal(['N=2'], s:run_out(4))
  call s:buf('none.sh', ['echo'], 'sh')
  call assert_match('no setup regions', execute('Sh setup'))
endfunction

function! Test_chained_state_zsh() abort
  call s:reset()
  call s:buf('activation.zsh', readfile(s:fixtures . 'activation.zsh'), 'zsh')
  call s:run(3, 5)
  let first = s:run_out(7, 8)
  call assert_match('^plain key-\d\+ iv-1$', first[0])
  " Re-running only the decrypt lines reuses res, k and iv.
  call assert_equal(first, s:run_out(7, 8))
endfunction

function! Test_unknown_subcommand() abort
  call assert_match('unknown subcommand: bogus', execute('Sh bogus'))
endfunction

" ------------------------------------------------------------------ runner
let s:failed = 0
let s:out = []
for s:name in sort(filter(map(split(execute('function /^Test_'), "\n"), 'matchstr(v:val, ''Test_\w\+'')'), '!empty(v:val)'))
  let v:errors = []
  try
    call call(s:name, [])
  catch
    call add(v:errors, v:exception . ' @ ' . v:throwpoint)
  endtry
  if empty(v:errors)
    call add(s:out, 'ok   ' . s:name)
  else
    let s:failed += 1
    call add(s:out, 'FAIL ' . s:name)
    call extend(s:out, map(copy(v:errors), '"     " . v:val'))
  endif
endfor
call shell#stop_all()
call delete(s:tmp, 'rf')
call writefile(s:out, $TEST_RESULT)
execute s:failed ? 'cquit!' : 'qall!'
