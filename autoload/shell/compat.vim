" Vim / Neovim shims: jobs, highlights and diagnostics.

" Start cmd (a list, no shell). OnLine(line) gets each stdout line as it
" arrives, OnExit(code) when the process ends. stderr is discarded.
function! shell#compat#start(cmd, OnLine, OnExit) abort
  if has('nvim')
    let ctx = {'partial': '', 'OnLine': a:OnLine}
    let id = jobstart(a:cmd, {'on_stdout': {j, data, e -> s:nvim_out(ctx, data)}, 'on_exit': {j, code, e -> a:OnExit(code)}})
    return id > 0 ? id : 0
  endif
  let job = job_start(a:cmd, {
        \ 'in_mode': 'raw', 'out_mode': 'nl', 'err_io': 'null',
        \ 'out_cb': {ch, line -> a:OnLine(line)},
        \ 'exit_cb': {j, code -> a:OnExit(code)}})
  return job_status(job) ==# 'fail' ? 0 : job
endfunction

" Neovim delivers chunks: the last item of data is an unfinished line, and
" [''] means end of output.
function! s:nvim_out(ctx, data) abort
  if a:data == ['']
    if a:ctx.partial !=# ''
      call a:ctx.OnLine(a:ctx.partial)
      let a:ctx.partial = ''
    endif
    return
  endif
  let data = copy(a:data)
  let data[0] = a:ctx.partial . data[0]
  let a:ctx.partial = remove(data, -1)
  for line in data
    call a:ctx.OnLine(line)
  endfor
endfunction

function! shell#compat#send(job, text) abort
  if has('nvim')
    call chansend(a:job, a:text)
  else
    call ch_sendraw(job_getchannel(a:job), a:text)
  endif
endfunction

function! shell#compat#running(job) abort
  if has('nvim')
    return a:job > 0 && jobwait([a:job], 0)[0] == -1
  endif
  return type(a:job) == v:t_job && job_status(a:job) ==# 'run'
endfunction

function! shell#compat#stop(job) abort
  if has('nvim')
    silent! call jobstop(a:job)
  elseif type(a:job) == v:t_job
    call job_stop(a:job)
  endif
endfunction

" Highlight bytes [col, col + len) (col 0-based) of line lnum in buf.
function! shell#compat#highlight(buf, lnum, col, len, group) abort
  if a:len <= 0
    return
  endif
  if has('nvim')
    call nvim_buf_set_extmark(a:buf, s:ns(), a:lnum - 1, a:col, {'end_col': a:col + a:len, 'hl_group': a:group})
    return
  endif
  if empty(prop_type_get(a:group))
    call prop_type_add(a:group, {'highlight': a:group})
  endif
  call prop_add(a:lnum, a:col + 1, {'length': a:len, 'type': a:group, 'bufnr': a:buf})
endfunction

" Replace the diagnostics on lines l1..l2 of buf with msg at l1 (none when
" msg is empty). Neovim uses vim.diagnostic; Vim a sign plus virtual text.
function! shell#compat#diagnostic(buf, l1, l2, msg) abort
  if has('nvim')
    call luaeval('require("shell.diagnostic").set(_A[1], _A[2], _A[3], _A[4])', [a:buf, a:l1, a:l2, a:msg])
    return
  endif
  for s in sign_getplaced(a:buf, {'group': 'shell_diag'})[0].signs
    if a:l1 <= s.lnum && s.lnum <= a:l2
      call sign_unplace('shell_diag', {'buffer': a:buf, 'id': s.id})
    endif
  endfor
  if empty(prop_type_get('ShellDiag'))
    call prop_type_add('ShellDiag', {'highlight': 'ShellDiagnostic'})
  endif
  call prop_remove({'type': 'ShellDiag', 'bufnr': a:buf, 'all': 1}, a:l1, a:l2)
  if a:msg !=# ''
    call sign_place(0, 'shell_diag', 'ShellError', a:buf, {'lnum': a:l1})
    call prop_add(a:l1, 0, {'type': 'ShellDiag', 'bufnr': a:buf, 'text': '  ' . a:msg, 'text_align': 'after'})
  endif
endfunction

" Diagnostics in buf as [[lnum, msg], ...].
function! shell#compat#diagnostics(buf) abort
  if has('nvim')
    return luaeval('require("shell.diagnostic").get(_A)', a:buf)
  endif
  let msgs = {}
  for p in prop_list(1, {'bufnr': a:buf, 'end_lnum': -1, 'types': ['ShellDiag']})
    let msgs[p.lnum] = p.text[2:]
  endfor
  return map(sort(keys(msgs), 'N'), '[str2nr(v:val), msgs[v:val]]')
endfunction

" Remove highlights from buf, or from its line lnum.
function! shell#compat#clear(buf, ...) abort
  let [l1, l2] = a:0 ? [a:1, a:1] : [1, max([1, getbufinfo(a:buf)[0].linecount])]
  if has('nvim')
    call nvim_buf_clear_namespace(a:buf, s:ns(), l1 - 1, l2)
    return
  endif
  call prop_clear(l1, l2, {'bufnr': a:buf})
endfunction

function! s:ns() abort
  if !exists('s:namespace')
    let s:namespace = nvim_create_namespace('shell')
  endif
  return s:namespace
endfunction
