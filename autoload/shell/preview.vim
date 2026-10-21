" The [Shell] preview window: run headers, streamed output, ANSI colors.

let s:buf = -1
let s:empty = 1
let s:palette = ['#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
      \ '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff']
let s:defined = {}
let s:links = {}

augroup shell_preview
  autocmd!
  autocmd ColorScheme * let s:defined = {}
augroup END

function! shell#preview#bufnr() abort
  return s:buf
endfunction

" Show the preview window (without focusing it), creating the buffer.
function! shell#preview#open() abort
  if !bufexists(s:buf)
    let s:buf = bufadd('[Shell]')
    call bufload(s:buf)
    call setbufvar(s:buf, '&buftype', 'nofile')
    call setbufvar(s:buf, '&bufhidden', 'hide')
    call setbufvar(s:buf, '&swapfile', 0)
    call setbufvar(s:buf, '&buflisted', 0)
    call setbufvar(s:buf, '&modifiable', 0)
    let s:empty = 1
  endif
  if bufwinid(s:buf) != -1
    return
  endif
  let cur = win_getid()
  execute 'botright vertical ' . get(g:, 'shell_preview_width', 80) . 'split'
  execute 'buffer ' . s:buf
  setlocal winfixwidth nonumber norelativenumber signcolumn=no nolist nowrap
  nnoremap <buffer> <silent> q :close<CR>
  nnoremap <buffer> <silent> <CR> :call shell#preview#jump()<CR>
  nnoremap <buffer> <silent> <C-c> :Sh interrupt<CR>
  call win_gotoid(cur)
endfunction

function! shell#preview#clear() abort
  if !bufexists(s:buf)
    return
  endif
  call s:modify('silent call deletebufline(s:buf, 1, "$")')
  call shell#compat#clear(s:buf)
  let s:empty = 1
  let s:links = {}
endfunction

" Append a line of text; returns its line number.
function! shell#preview#add(text) abort
  if s:empty
    call s:modify('call setbufline(s:buf, 1, a:1)', a:text)
    let s:empty = 0
  else
    call s:modify('call appendbufline(s:buf, "$", a:1)', a:text)
  endif
  let lnum = getbufinfo(s:buf)[0].linecount
  call s:follow()
  return lnum
endfunction

" Replace line lnum with chunks [[text, group], ...].
function! shell#preview#set(lnum, chunks) abort
  call s:modify('call setbufline(s:buf, a:1, a:2)', a:lnum, join(map(copy(a:chunks), 'v:val[0]'), ''))
  call shell#compat#clear(s:buf, a:lnum)
  let col = 0
  for [text, group] in a:chunks
    call shell#compat#highlight(s:buf, a:lnum, col, strlen(text), group)
    let col += strlen(text)
  endfor
endfunction

" Make <CR> on the section starting at header lnum jump to mark id in buf.
function! shell#preview#link(lnum, buf, id) abort
  let s:links[a:lnum] = [a:buf, a:id]
endfunction

" Go to the source lines of the section under the cursor.
function! shell#preview#jump() abort
  let heads = filter(map(keys(s:links), 'str2nr(v:val)'), 'v:val <= line(".")')
  if empty(heads)
    return
  endif
  let [buf, id] = s:links[max(heads)]
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

" Echo the executed code: "$ " before the first line, "> " before the rest.
function! shell#preview#code(lines) abort
  let prefix = '$ '
  for line in a:lines
    call shell#preview#set(shell#preview#add(''), [[prefix, 'ShellMuted'], [line, 'ShellCode']])
    let prefix = '> '
  endfor
endfunction

" Append a line of program output, rendering ANSI SGR codes with state
" (a dict carried across the run's lines). Returns [text, spans].
function! shell#preview#output(line, state) abort
  let [text, spans] = shell#preview#ansi(a:line, a:state)
  let lnum = shell#preview#add(text)
  for [col, len, group] in spans
    call shell#compat#highlight(s:buf, lnum, col, len, group)
  endfor
  return [text, spans]
endfunction

function! s:modify(cmd, ...) abort
  call setbufvar(s:buf, '&modifiable', 1)
  execute a:cmd
  call setbufvar(s:buf, '&modifiable', 0)
endfunction

" Keep windows showing the end of the output, unless the user is in one.
function! s:follow() abort
  for winid in win_findbuf(s:buf)
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
