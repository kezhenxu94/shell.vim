" The preview window: one "[Shell] <file>" buffer per script, with run
" headers, the code that ran, streamed output and ANSI colors.

let s:buf = -1
let s:bufs = {}
let s:palette = ['#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
      \ '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff']
let s:defined = {}

augroup shell_preview
  autocmd!
  autocmd ColorScheme * let s:defined = {}
augroup END

" The preview buffer shown last.
function! shell#preview#bufnr() abort
  return s:buf
endfunction

" The preview buffer of script (an absolute path, or '' for none).
function! shell#preview#buffer(script) abort
  let name = a:script ==# '' ? '[Shell]' : '[Shell] ' . fnamemodify(a:script, ':~:.')
  let buf = get(s:bufs, name, -1)
  if bufexists(buf)
    return buf
  endif
  let buf = bufadd(name)
  " No autocommands: a name ending in .sh would get the sh filetype (and LSP).
  noautocmd call bufload(buf)
  for [opt, val] in [['&buftype', 'nofile'], ['&bufhidden', 'hide'], ['&swapfile', 0], ['&buflisted', 0], ['&modifiable', 0]]
    call setbufvar(buf, opt, val)
  endfor
  call setbufvar(buf, 'shell_preview', 1)
  call setbufvar(buf, 'shell_empty', 1)
  call setbufvar(buf, 'shell_links', {})
  let s:bufs[name] = buf
  return buf
endfunction

" Show buf in the preview window (without focusing it): reuse the window
" of another preview buffer, else open a split.
function! shell#preview#open(buf) abort
  let s:buf = a:buf
  if bufwinid(a:buf) != -1
    return
  endif
  let winid = get(filter(map(range(1, winnr('$')), 'win_getid(v:val)'), 'getbufvar(winbufnr(v:val), "shell_preview", 0)'), 0, 0)
  if winid
    call win_execute(winid, 'buffer ' . a:buf)
  else
    let cur = win_getid()
    execute 'botright vertical ' . get(g:, 'shell_preview_width', 80) . 'split'
    execute 'buffer ' . a:buf
    setlocal winfixwidth nonumber norelativenumber signcolumn=no nolist nowrap
    let winid = win_getid()
    call win_gotoid(cur)
  endif
  if !getbufvar(a:buf, 'shell_mapped', 0)
    call win_execute(winid, 'nnoremap <buffer> <silent> q :close<CR>')
    call win_execute(winid, 'nnoremap <buffer> <silent> <CR> :call shell#preview#jump()<CR>')
    call win_execute(winid, 'nnoremap <buffer> <silent> <C-c> :Sh interrupt<CR>')
    call setbufvar(a:buf, 'shell_mapped', 1)
  endif
endfunction

function! shell#preview#clear(buf) abort
  if !bufexists(a:buf)
    return
  endif
  call s:modify(a:buf, 'silent call deletebufline(a:1, 1, "$")', a:buf)
  call shell#compat#clear(a:buf)
  call setbufvar(a:buf, 'shell_empty', 1)
  call setbufvar(a:buf, 'shell_links', {})
endfunction

" Append a line of text to buf; returns its line number.
function! shell#preview#add(buf, text) abort
  if getbufvar(a:buf, 'shell_empty')
    call s:modify(a:buf, 'call setbufline(a:1, 1, a:2)', a:buf, a:text)
    call setbufvar(a:buf, 'shell_empty', 0)
  else
    call s:modify(a:buf, 'call appendbufline(a:1, "$", a:2)', a:buf, a:text)
  endif
  let lnum = getbufinfo(a:buf)[0].linecount
  call s:follow(a:buf)
  return lnum
endfunction

" Replace line lnum of buf with chunks [[text, group], ...].
function! shell#preview#set(buf, lnum, chunks) abort
  call s:modify(a:buf, 'call setbufline(a:1, a:2, a:3)', a:buf, a:lnum, join(map(copy(a:chunks), 'v:val[0]'), ''))
  call shell#compat#clear(a:buf, a:lnum)
  let col = 0
  for [text, group] in a:chunks
    call shell#compat#highlight(a:buf, a:lnum, col, strlen(text), group)
    let col += strlen(text)
  endfor
endfunction

" Make <CR> on the section of buf starting at header lnum jump to mark id
" in src.
function! shell#preview#link(buf, lnum, src, id) abort
  call extend(getbufvar(a:buf, 'shell_links'), {a:lnum: [a:src, a:id]})
endfunction

" Go to the source lines of the section under the cursor.
function! shell#preview#jump() abort
  let links = get(b:, 'shell_links', {})
  let heads = filter(map(keys(links), 'str2nr(v:val)'), 'v:val <= line(".")')
  if empty(heads)
    return
  endif
  let [buf, id] = links[max(heads)]
  let r = shell#mark#range(buf, id)
  if empty(r)
    echohl WarningMsg | echo 'shell: those lines are gone' | echohl None
    return
  endif
  let winid = get(win_findbuf(buf), 0, -1)
  if winid == -1
    wincmd p
    execute 'buffer ' . buf
  else
    call win_gotoid(winid)
  endif
  call cursor(r[0], 1)
endfunction

" Echo the executed code: "$ " before the first line, "# " before the rest.
function! shell#preview#code(buf, lines) abort
  let prefix = '$ '
  for line in a:lines
    call shell#preview#set(a:buf, shell#preview#add(a:buf, ''), [[prefix, 'ShellMuted'], [line, 'ShellCode']])
    let prefix = '# '
  endfor
endfunction

" Append a line of program output to buf, rendering ANSI SGR codes with
" state (a dict carried across the run's lines). Returns [text, spans].
function! shell#preview#output(buf, line, state) abort
  let [text, spans] = shell#preview#ansi(a:line, a:state)
  let lnum = shell#preview#add(a:buf, text)
  for [col, len, group] in spans
    call shell#compat#highlight(a:buf, lnum, col, len, group)
  endfor
  return [text, spans]
endfunction

function! s:modify(buf, cmd, ...) abort
  call setbufvar(a:buf, '&modifiable', 1)
  execute a:cmd
  call setbufvar(a:buf, '&modifiable', 0)
endfunction

" Keep windows showing the end of the output, unless the user is in one.
function! s:follow(buf) abort
  for winid in win_findbuf(a:buf)
    if winid != win_getid()
      call win_execute(winid, 'normal! G')
    endif
  endfor
endfunction

" Strip escape sequences from line. Returns [text, spans] where spans are
" [col, len, group] for bold / 16-color SGR runs. After a \r only the text
" that follows is kept, as a terminal would show it.
function! shell#preview#ansi(line, state) abort
  let line = substitute(a:line, '\r\+$', '', '')
  let cr = strridx(line, "\r")
  if cr >= 0
    let line = line[cr + 1 :]
  endif
  call extend(a:state, {'fg': -1, 'bold': 0}, 'keep')
  let text = ''
  let spans = []
  let i = 0
  while 1
    let j = stridx(line, "\e", i)
    let seg = j < 0 ? line[i :] : strpart(line, i, j - i)
    let group = s:group(a:state)
    if seg !=# '' && group !=# ''
      call add(spans, [strlen(text), strlen(seg), group])
    endif
    let text .= seg
    if j < 0
      break
    endif
    let m = matchlist(line, '^\e\[\([0-9;?]*\)[ -/]*\([@-~]\)', j)
    if !empty(m)
      if m[2] ==# 'm' && m[1] !~# '?'
        call s:sgr(a:state, m[1])
      endif
      let i = j + strlen(m[0])
      continue
    endif
    let m = matchstr(line, '^\e\][^\x07\e]*\%(\%x07\|\e\\\)\=', j)
    let i = m !=# '' ? j + strlen(m) : j + 2
  endwhile
  return [text, spans]
endfunction

function! s:sgr(state, params) abort
  let codes = map(split(a:params, ';', 1), 'str2nr(v:val)')
  let k = 0
  while k < len(codes)
    let c = codes[k]
    if c == 0
      let a:state.fg = -1
      let a:state.bold = 0
    elseif c == 1
      let a:state.bold = 1
    elseif c == 22
      let a:state.bold = 0
    elseif c >= 30 && c <= 37
      let a:state.fg = c - 30
    elseif c >= 90 && c <= 97
      let a:state.fg = c - 90 + 8
    elseif c == 39
      let a:state.fg = -1
    elseif c == 38 || c == 48
      " 256-color / truecolor: keep the 16 basic colors, skip the rest.
      if get(codes, k + 1, -1) == 5
        if c == 38 && get(codes, k + 2, 99) < 16
          let a:state.fg = codes[k + 2]
        endif
        let k += 2
      elseif get(codes, k + 1, -1) == 2
        let k += 4
      endif
    endif
    let k += 1
  endwhile
endfunction

function! s:group(state) abort
  if a:state.fg < 0 && !a:state.bold
    return ''
  endif
  let name = 'ShellAnsi' . (a:state.fg >= 0 ? a:state.fg : '') . (a:state.bold ? 'Bold' : '')
  if !has_key(s:defined, name)
    let attrs = a:state.bold ? ' cterm=bold gui=bold' : ''
    if a:state.fg >= 0
      let fg = a:state.fg
      let attrs .= ' ctermfg=' . fg . ' guifg=' . get(g:, 'terminal_color_' . fg, s:palette[fg])
    endif
    execute 'highlight ' . name . attrs
    let s:defined[name] = 1
  endif
  return name
endfunction
