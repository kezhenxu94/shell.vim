" Execution history: one JSON line per run in <state dir>/<script path>.jsonl.

let s:cache = {}

function! shell#history#enabled() abort
  return get(g:, 'shell_history', 1)
endfunction

function! shell#history#dir() abort
  if exists('g:shell_history_dir')
    return g:shell_history_dir
  endif
  if has('nvim')
    return stdpath('state') . '/shell'
  endif
  return (empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME) . '/vim/shell'
endfunction

" History file of a script (absolute path), named like 'undofile'.
function! shell#history#file(script) abort
  return shell#history#dir() . '/' . substitute(a:script, '/', '%', 'g') . '.jsonl'
endfunction

" Append entry, keeping at most g:shell_history_max entries per script.
" The directory is private (0700) and files are 0600: output may hold secrets.
function! shell#history#add(script, entry) abort
  let dir = shell#history#dir()
  if !isdirectory(dir)
    call mkdir(dir, 'p', 0700)
  endif
  let file = shell#history#file(a:script)
  let lines = filereadable(file) ? readfile(file) : []
  call add(lines, json_encode(a:entry))
  let max = get(g:, 'shell_history_max', 100)
  call writefile(lines[max([0, len(lines) - max]) :], file)
  call setfperm(file, 'rw-------')
  silent! call remove(s:cache, file)
endfunction

" Entries of a script, oldest first.
function! shell#history#list(script) abort
  let file = shell#history#file(a:script)
  if !filereadable(file)
    return []
  endif
  let mtime = getftime(file) . ':' . getfsize(file)
  if get(get(s:cache, file, {}), 'mtime', '') !=# mtime
    let entries = []
    for line in readfile(file)
      try
        call add(entries, json_decode(line))
      catch
      endtry
    endfor
    for e in entries
      let e.script = a:script
    endfor
    let s:cache[file] = {'mtime': mtime, 'entries': entries}
  endif
  return s:cache[file].entries
endfunction

" Entries of a script that ran exactly code, oldest first.
function! shell#history#for_code(script, code) abort
  let hash = sha256(a:code)
  return filter(copy(shell#history#list(a:script)), 'v:val.hash ==# hash')
endfunction

" One-line summary: "21:30:05 · ✓ 230ms · L5-7 · echo hi".
function! shell#history#title(entry) abort
  let e = a:entry
  return printf('%s · %s · %s · %s', strftime('%Y-%m-%d %H:%M:%S', e.time),
        \ shell#history#result(e), e.label, matchstr(e.code, '^\s*\zs[^\n]*'))
endfunction

function! shell#history#result(entry) abort
  let dur = shell#history#duration(a:entry.ms)
  return a:entry.status ? '✗ exit ' . a:entry.status . ' · ' . dur : '✓ ' . dur
endfunction

function! shell#history#duration(ms) abort
  return a:ms < 1000 ? a:ms . 'ms' : printf('%.1fs', a:ms / 1000.0)
endfunction

function! shell#history#ago(time) abort
  let s = localtime() - a:time
  return s < 60 ? 'just now' : s < 3600 ? s / 60 . 'm ago' : s < 86400 ? s / 3600 . 'h ago' : s / 86400 . 'd ago'
endfunction

" Show an entry in the [Shell] window: header, the code, then its output.
function! shell#history#show(entry) abort
  let e = a:entry
  let buf = shell#preview#buffer(get(e, 'script', ''))
  call shell#preview#open(buf)
  call shell#preview#clear(buf)
  let header = shell#preview#add(buf, '')
  call shell#preview#set(buf, header, [['── history ' . e.label, 'ShellHeader'],
        \ [' · ', 'ShellMuted'], [e.status ? 'exit ' . e.status : 'exit 0', e.status ? 'ShellFail' : 'ShellOk'],
        \ [' · ' . shell#history#duration(e.ms) . ' · ' . strftime('%Y-%m-%d %H:%M:%S', e.time)
        \ . ' · ' . fnamemodify(e.cwd, ':~'), 'ShellMuted']])
  call shell#preview#code(buf, split(e.code, "\n", 1))
  let state = {}
  for line in e.output
    call shell#preview#output(buf, line, state)
  endfor
  if get(e, 'truncated', 0)
    call shell#preview#set(buf, shell#preview#add(buf, ''), [['… ' . e.truncated . ' more lines not kept', 'ShellMuted']])
  endif
endfunction
