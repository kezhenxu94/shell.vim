" Run parts of a shell script in a persistent session. See doc/shell.txt.

let s:drivers = expand('<sfile>:p:h') . '/shell/driver.'
let s:sessions = {}
let s:subcommands = ['run', 'tocursor', 'file', 'scratch', 'setup', 'actions', 'history', 'restart', 'interrupt']

call sign_define('ShellRan', {'text': get(g:, 'shell_sign', '▏'), 'texthl': 'ShellRan'})
call sign_define('ShellError', {'text': '✗', 'texthl': 'ShellError'})

" ------------------------------------------------------------------ commands

function! shell#command(range, l1, l2, args) abort
  let sub = matchstr(a:args, '^\S*')
  let rest = trim(a:args[strlen(sub) :])
  if sub ==# '' || sub ==# 'run'
    return a:range ? shell#run(a:l1, a:l2) : shell#run_statement()
  elseif index(s:subcommands, sub) < 0
    return s:error('unknown subcommand: ' . sub)
  elseif sub ==# 'file'
    return shell#file(rest)
  elseif sub ==# 'actions'
    return shell#actions#menu()
  elseif sub ==# 'history'
    return shell#actions#history_menu()
  endif
  call call('shell#' . sub, [])
endfunction

function! shell#complete(arglead, cmdline, pos) abort
  if a:cmdline[: a:pos - 1] =~# '\<Sh\s\+\S*\s'
    return []
  endif
  return filter(copy(s:subcommands), 'stridx(v:val, a:arglead) == 0')
endfunction

function! shell#run(l1, l2) abort
  call s:run(bufnr('%'), a:l1, a:l2)
endfunction

function! shell#run_statement() abort
  let r = shell#statement_range(line('.'))
  if empty(r)
    return s:error('no command under cursor')
  endif
  call s:run(bufnr('%'), r[0], r[1])
endfunction

" Run the lines up to and including the cursor line.
function! shell#tocursor() abort
  call s:run(bufnr('%'), 1, line('.'))
endfunction

" Run the saved script in a fresh process (it gets the session's exported
" variables and cwd, nothing else).
function! shell#file(args) abort
  let src = s:source(bufnr('%'))
  let path = fnamemodify(bufname(src), ':p')
  if bufname(src) ==# '' || !filereadable(path)
    return s:error('buffer has no file on disk')
  endif
  if getbufvar(src, '&modified')
    call s:warn('running the saved file; the buffer has unsaved changes')
  endif
  let sess = s:session(bufnr('%'))
  if empty(sess)
    return
  endif
  let cmd = executable(path) ? shellescape(path) : sess.shell . ' ' . shellescape(path)
  let label = 'file ' . fnamemodify(path, ':t') . (a:args ==# '' ? '' : ' ' . a:args)
  call s:enqueue(sess, [{'kind': 'file', 'code': 'exec ' . cmd . (a:args ==# '' ? '' : ' ' . a:args), 'label': label}])
endfunction

" Open (or go to) the scratch buffer attached to this buffer's session.
function! shell#scratch() abort
  let src = s:source(bufnr('%'))
  let scratch = getbufvar(src, 'shell_scratch', -1)
  if bufexists(scratch)
    let winid = bufwinid(scratch)
    if winid != -1
      call win_gotoid(winid)
    else
      execute 'split | buffer ' . scratch
    endif
    return
  endif
  let ft = getbufvar(src, '&filetype')
  new
  setlocal buftype=nofile bufhidden=hide noswapfile
  execute 'silent file [Shell\ scratch\ ' . src . ']'
  let b:shell_source = src
  call setbufvar(src, 'shell_scratch', bufnr('%'))
  execute 'setfiletype ' . (ft =~# '^\%(sh\|zsh\|bash\)$' ? ft : 'sh')
endfunction

" Re-apply every setup region of the script.
function! shell#setup() abort
  let src = s:source(bufnr('%'))
  let regions = shell#parse#regions(getbufline(src, 1, '$'))
  if empty(regions)
    return s:error('no setup regions (' . join(get(g:, 'shell_setup_markers', ['# @setup', '# @end']), ' … ') . ')')
  endif
  let sess = s:session(bufnr('%'))
  if !empty(sess)
    call s:enqueue(sess, map(regions, 's:setup_item(src, v:val, v:key)'))
  endif
endfunction

function! shell#restart() abort
  let key = s:key(bufnr('%'))
  if has_key(s:sessions, key)
    call s:stop(s:sessions[key])
  endif
  echo 'shell: session restarted'
endfunction

function! shell#interrupt() abort
  let sess = get(b:, 'shell_preview', 0) ? get(s:, 'last', {}) : get(s:sessions, s:key(bufnr('%')), {})
  if empty(sess) || empty(sess.cur)
    return s:error('nothing is running')
  endif
  call s:drop(sess, '1')
  call s:kill(sess)
endfunction

" Stop every session (on exit).
function! shell#stop_all() abort
  for sess in values(s:sessions)
    call s:stop(sess)
  endfor
endfunction

" Stop the session of a buffer that is going away.
function! shell#detach(buf) abort
  if get(g:, 'shell_session', 'buffer') ==# 'buffer' && has_key(s:sessions, 'buf:' . a:buf)
    call s:stop(s:sessions['buf:' . a:buf])
  endif
endfunction

" ------------------------------------------------------------------ queries

" The script buffer of buf (itself, or the script of a scratch buffer).
function! shell#source(buf) abort
  return s:source(a:buf)
endfunction

" Absolute path of buf's script, or '' if it has no name.
function! shell#script(buf) abort
  let src = s:source(a:buf)
  " Resolved: Neovim may switch a name between a symlink and its target.
  return bufname(src) ==# '' ? '' : resolve(fnamemodify(bufname(src), ':p'))
endfunction

" The session of buf (default: current buffer), or {} if none is running.
function! shell#session(...) abort
  return get(s:sessions, s:key(a:0 ? a:1 : bufnr('%')), {})
endfunction

" 1 while any session has a run in progress or queued.
function! shell#busy() abort
  for sess in values(s:sessions)
    if !empty(sess.cur) || !empty(sess.queue)
      return 1
    endif
  endfor
  return 0
endfunction

" Line range [start, end] of the command at lnum in the current buffer.
function! shell#statement_range(lnum) abort
  if has('nvim') && get(g:, 'shell_treesitter', 1)
    let r = luaeval('require("shell.ts").range(_A[1], _A[2])', [bufnr('%'), a:lnum])
    if r isnot v:null && !empty(r)
      return r
    endif
  endif
  for st in shell#parse#statements(getline(1, '$'))
    if st.start <= a:lnum && a:lnum <= st.end
      return [st.start, st.end]
    endif
  endfor
  return []
endfunction

" Shell for buf: the shebang, else zsh for zsh files, else $SHELL if it is
" zsh or bash, else bash.
function! shell#shell_for(buf) abort
  let first = get(getbufline(a:buf, 1), 0, '')
  if first =~# '^#!'
    if first =~# 'zsh'
      return 'zsh'
    elseif first =~# '\<\%(ba\|da\|k\|\)sh\>'
      return 'bash'
    endif
  endif
  if getbufvar(a:buf, '&filetype') ==# 'zsh'
    return 'zsh'
  endif
  let sh = fnamemodify($SHELL, ':t')
  return sh ==# 'zsh' || sh ==# 'bash' ? sh : 'bash'
endfunction

" Session working directory for buf: the git root, else the file's directory.
function! shell#root(buf) abort
  let root = getbufvar(a:buf, 'shell_root', '')
  if root !=# ''
    return root
  endif
  let dir = bufname(a:buf) ==# '' ? getcwd() : fnamemodify(bufname(a:buf), ':p:h')
  let out = systemlist('git -C ' . shellescape(dir) . ' rev-parse --show-toplevel 2>/dev/null')
  let root = v:shell_error == 0 && !empty(out) ? out[0] : dir
  call setbufvar(a:buf, 'shell_root', root)
  return root
endfunction

" ------------------------------------------------------------------ runs

" Run lines l1..l2 of buf, after the setup regions above them that this
" session hasn't applied in their current form.
function! s:run(buf, l1, l2) abort
  let sess = s:session(a:buf)
  if empty(sess)
    return
  endif
  let src = s:source(a:buf)
  let items = []
  let covers = []
  let idx = 0
  for r in shell#parse#regions(getbufline(src, 1, '$'))
    if (src != a:buf || r.end < a:l1) && !has_key(sess.applied, r.hash)
      call add(items, s:setup_item(src, r, idx))
    elseif src == a:buf && a:l1 <= r.start && r.end <= a:l2
      call add(covers, [idx, r.hash])
    endif
    let idx += 1
  endfor
  " A new run over the same lines replaces the old result.
  for id in shell#mark#overlapping(a:buf, a:l1, a:l2)
    call shell#mark#del(a:buf, id)
  endfor
  let sess.bufs[a:buf] = 1
  let sess.bufs[src] = 1
  let label = (src == a:buf ? '' : 'scratch ') . 'L' . a:l1 . (a:l1 == a:l2 ? '' : '-' . a:l2)
  let item = {'kind': 'run', 'code': join(getbufline(a:buf, a:l1, a:l2), "\n"), 'label': label,
        \ 'buf': a:buf, 'mark': shell#mark#add(a:buf, a:l1, a:l2), 'covers': covers}
  call shell#mark#show(a:buf, item.mark, {'status': [['… queued', 'ShellMuted']]})
  call s:enqueue(sess, items + [item])
endfunction

function! s:setup_item(src, region, idx) abort
  return {'kind': 'run', 'code': join(getbufline(a:src, a:region.start, a:region.end), "\n"),
        \ 'label': 'setup L' . a:region.start . '-' . a:region.end, 'setup': a:region.hash,
        \ 'region': a:idx, 'buf': a:src, 'mark': shell#mark#add(a:src, a:region.start, max([a:region.start, a:region.end]))}
endfunction

" Queue items as one batch: a failing setup item drops the rest of it.
function! s:enqueue(sess, items) abort
  let s:batch = get(s:, 'batch', 0) + 1
  for item in a:items
    let item.batch = s:batch
  endfor
  let a:items[0].first = 1
  let preview = shell#preview#buffer(shell#script(get(a:items[-1], 'buf', a:sess.src)))
  for item in a:items
    let item.preview = preview
  endfor
  call extend(a:sess.queue, a:items)
  call shell#preview#open(preview)
  call s:next(a:sess)
endfunction

function! s:next(sess) abort
  if !empty(a:sess.cur) || empty(a:sess.queue)
    return
  endif
  let item = remove(a:sess.queue, 0)
  let a:sess.seq += 1
  let item.id = a:sess.seq
  let item.ansi = {}
  let item.last = ''
  let item.tail = []
  let item.lines = 0
  let item.output = []
  call writefile(split(item.code, "\n", 1), a:sess.dir . '/' . item.id)
  if item.kind !=# 'init'
    if get(item, 'first', 0)
      call shell#preview#clear(item.preview)
    endif
    let item.header = shell#preview#add(item.preview, '')
    call s:header(item, [['running', 'ShellRunning'], [fnamemodify(a:sess.cwd, ':~'), 'ShellMuted']])
    call shell#preview#code(item.preview, split(item.code, "\n", 1))
    if has_key(item, 'mark')
      call shell#preview#link(item.preview, item.header, item.buf, item.mark)
      if !has_key(item, 'setup')
        call shell#mark#show(item.buf, item.mark, {'status': [['⟳ running', 'ShellRunning']]})
      endif
    endif
    let s:last = a:sess
  endif
  let item.start = reltime()
  let a:sess.cur = item
  call shell#compat#send(a:sess.job, item.kind . ' ' . item.id . "\n")
endfunction

" Set the preview header of item: "── <label> · <chunk> · <chunk>".
function! s:header(item, chunks) abort
  let chunks = [['── ' . a:item.label, 'ShellHeader']]
  for chunk in a:chunks
    call extend(chunks, [[' · ', 'ShellMuted'], chunk])
  endfor
  call shell#preview#set(a:item.preview, a:item.header, chunks)
endfunction

function! s:on_line(sess, line) abort
  let item = a:sess.cur
  if empty(item)
    return
  endif
  let i = stridx(a:line, "\x1eSHDONE ")
  let out = i < 0 ? a:line : strpart(a:line, 0, i)
  if i != 0 && item.kind !=# 'init'
    let [text, spans] = shell#preview#output(item.preview, out, item.ansi)
    if trim(text) !=# ''
      let item.last = trim(text)
    endif
    let item.lines += 1
    if len(item.output) < get(g:, 'shell_history_output', 500)
      call add(item.output, out)
    endif
    call add(item.tail, s:chunks(text, spans))
    if len(item.tail) > get(g:, 'shell_inline_output', 0)
      call remove(item.tail, 0)
    endif
  endif
  if i >= 0
    let m = matchlist(a:line[i :], '^\%x1eSHDONE \(\d\+\) \(\d\+\) \(.*\)$')
    call s:done(a:sess, item, str2nr(m[2]), m[3])
  endif
endfunction

" Inline output line: text split into [text, group] chunks.
function! s:chunks(text, spans) abort
  let chunks = [['│ ', 'ShellMuted']]
  let col = 0
  for [start, len, group] in a:spans
    if start > col
      call add(chunks, [strpart(a:text, col, start - col), 'ShellOutput'])
    endif
    call add(chunks, [strpart(a:text, start, len), group])
    let col = start + len
  endfor
  if col < strlen(a:text)
    call add(chunks, [strpart(a:text, col), 'ShellOutput'])
  endif
  return chunks
endfunction

function! s:done(sess, item, status, cwd) abort
  let a:sess.cur = {}
  let a:sess.cwd = a:cwd
  let item = a:item
  let ms = float2nr(reltimefloat(reltime(item.start)) * 1000)
  let dur = shell#history#duration(ms)
  if item.kind ==# 'init'
    if a:status
      call s:warn('g:shell_init failed with exit ' . a:status)
    endif
  else
    if has_key(item, 'setup') && a:status
      let item.label .= ' failed'
    endif
    call s:header(item, [['exit ' . a:status,
          \ a:status ? 'ShellFail' : 'ShellOk'], [dur, 'ShellMuted'], [fnamemodify(a:cwd, ':~'), 'ShellMuted']])
  endif
  let r = has_key(item, 'mark') ? shell#mark#range(item.buf, item.mark) : []
  if !empty(r)
    let msg = a:status ? (item.last ==# '' ? 'exit ' . a:status : item.last) : ''
    call shell#compat#diagnostic(item.buf, r[0], r[1], msg)
  endif
  if has_key(item, 'setup')
    if a:status
      call s:drop(a:sess, 'v:val.batch == ' . item.batch)
    else
      let a:sess.applied[item.setup] = 1
      let a:sess.regions[item.region] = item.setup
    endif
    if !a:status || empty(r)
      call shell#mark#del(item.buf, item.mark)
    endif
  elseif !empty(r)
    let status = a:status ? [['✗ exit ' . a:status . ' · ' . dur, 'ShellFail']] : [['✓ ' . dur, 'ShellOk']]
    let lines = copy(item.tail)
    if item.lines > len(lines) && !empty(lines)
      call insert(lines, [['│ … ' . (item.lines - len(lines)) . ' more in [Shell]', 'ShellMuted']])
    endif
    call shell#mark#show(item.buf, item.mark, {'status': status, 'sign': 1, 'lines': lines})
    if !a:status
      for [idx, hash] in item.covers
        let a:sess.applied[hash] = 1
        let a:sess.regions[idx] = hash
      endfor
    endif
  endif
  if item.kind !=# 'init'
    call s:record(a:sess, item, a:status, ms)
  endif
  if has_key(item, 'buf')
    call shell#render_regions(item.buf)
  endif
  call s:next(a:sess)
endfunction

" Remove queued items matching expr, with their marks.
function! s:drop(sess, expr) abort
  for item in filter(copy(a:sess.queue), a:expr)
    if has_key(item, 'mark')
      call shell#mark#del(item.buf, item.mark)
    endif
  endfor
  call filter(a:sess.queue, '!(' . a:expr . ')')
endfunction

" Save a finished run to the history of its script and refresh lenses.
function! s:record(sess, item, status, ms) abort
  let script = shell#script(get(a:item, 'buf', a:sess.src))
  if script ==# '' || !shell#history#enabled()
    return
  endif
  call shell#history#add(script, {'time': localtime(), 'hash': sha256(a:item.code), 'code': a:item.code,
        \ 'label': a:item.label, 'status': a:status, 'ms': a:ms, 'cwd': a:sess.cwd, 'shell': a:sess.shell,
        \ 'output': a:item.output, 'truncated': a:item.lines - len(a:item.output)})
  call shell#refresh(get(a:item, 'buf', a:sess.src))
endfunction

" Redraw the lenses and setup-region statuses of buf and its script.
function! shell#refresh(buf) abort
  if !bufexists(a:buf)
    return
  endif
  let src = s:source(a:buf)
  let script = shell#script(a:buf)
  for b in uniq([a:buf, src])
    call shell#lens#render(b, script)
  endfor
  call shell#render_regions(src)
endfunction

" Show on each `# @setup` line of buf's script whether the session applied it.
function! shell#render_regions(buf) abort
  let src = s:source(a:buf)
  let sess = get(s:sessions, s:key(src), {})
  let items = []
  if !empty(sess)
    let idx = 0
    for r in shell#parse#regions(getbufline(src, 1, '$'))
      if has_key(sess.applied, r.hash)
        call add(items, [r.start - 1, [['● setup applied', 'ShellOk']]])
      elseif has_key(sess.regions, idx)
        call add(items, [r.start - 1, [['◐ setup changed · re-applied on next run', 'ShellWarn']]])
      else
        call add(items, [r.start - 1, [['○ setup not applied', 'ShellMuted']]])
      endif
      let idx += 1
    endfor
  endif
  call shell#mark#regions(src, items)
endfunction

" ------------------------------------------------------------------ sessions

function! s:source(buf) abort
  let src = getbufvar(a:buf, 'shell_source', a:buf)
  return bufexists(src) ? src : a:buf
endfunction

function! s:key(buf) abort
  let src = s:source(a:buf)
  if get(g:, 'shell_session', 'buffer') ==# 'cwd'
    return 'cwd:' . shell#shell_for(src) . ':' . shell#root(src)
  endif
  return 'buf:' . src
endfunction

" The running session for buf, started if needed; {} on failure.
function! s:session(buf) abort
  let key = s:key(a:buf)
  if has_key(s:sessions, key)
    return s:sessions[key]
  endif
  let src = s:source(a:buf)
  let shell = shell#shell_for(src)
  if !executable(shell)
    call s:error(shell . ' not found in $PATH')
    return {}
  endif
  let dir = tempname()
  call mkdir(dir, 'p', 0700)
  let root = shell#root(src)
  let script = bufname(src) ==# '' ? shell : fnamemodify(bufname(src), ':p')
  let sess = {'key': key, 'src': src, 'shell': shell, 'dir': dir, 'cwd': root, 'queue': [], 'cur': {},
        \ 'applied': {}, 'regions': {}, 'seq': 0, 'bufs': {}}
  let sess.job = shell#compat#start([shell, '-c', '. "$1"', script, s:drivers . shell, dir, root],
        \ {line -> s:on_line(sess, line)}, {code -> s:on_exit(sess, code)})
  if empty(sess.job)
    call s:error('failed to start ' . shell)
    return {}
  endif
  let s:sessions[key] = sess
  let init = get(g:, 'shell_init', s:default_init)
  if init !=# ''
    call add(sess.queue, {'kind': 'init', 'code': init, 'label': 'init', 'batch': 0})
  endif
  return sess
endfunction

let s:default_init = '[ -r ~/.aliases ] && . ~/.aliases' . "\n"
      \ . 'for __sh_f in "${XDG_CONFIG_HOME:-$HOME/.config}"/zsh/functions/*; do [ -r "$__sh_f" ] && . "$__sh_f"; done' . "\n"
      \ . 'unset __sh_f'

function! s:on_exit(sess, code) abort
  if get(a:sess, 'stopped', 0)
    return
  endif
  if !empty(a:sess.cur) && has_key(a:sess.cur, 'header')
    call s:header(a:sess.cur, [['session exited ' . a:code, 'ShellFail']])
  endif
  call s:stop(a:sess)
endfunction

function! s:stop(sess) abort
  let a:sess.stopped = 1
  if !empty(a:sess.cur)
    call s:kill(a:sess)
  endif
  call shell#compat#stop(a:sess.job)
  call delete(a:sess.dir, 'rf')
  if get(s:sessions, a:sess.key, {}) is a:sess
    call remove(s:sessions, a:sess.key)
  endif
  for buf in map(keys(a:sess.bufs), 'str2nr(v:val)')
    if bufexists(buf)
      call shell#mark#clear(buf)
      call shell#compat#diagnostic(buf, 1, max([1, getbufinfo(buf)[0].linecount]), '')
    endif
  endfor
  let a:sess.queue = []
  let a:sess.cur = {}
endfunction

" Terminate the current run: its subshell and every process below it.
function! s:kill(sess) abort
  let file = a:sess.dir . '/pid'
  " The driver writes the pid just after forking; allow it a moment.
  let tries = 0
  while !filereadable(file) && tries < 50
    sleep 10m
    let tries += 1
  endwhile
  let pid = filereadable(file) ? get(readfile(file), 0, '') : ''
  if pid =~# '^\d\+$'
    call system('sh -c ' . shellescape('t() { echo "$1"; for c in $(pgrep -P "$1"); do t "$c"; done; }; kill -TERM $(t ' . pid . ') 2>/dev/null'))
  endif
endfunction

function! s:error(msg) abort
  echohl ErrorMsg | echomsg 'shell: ' . a:msg | echohl None
endfunction

function! s:warn(msg) abort
  echohl WarningMsg | echomsg 'shell: ' . a:msg | echohl None
endfunction
