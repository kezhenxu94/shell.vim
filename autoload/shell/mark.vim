" Run marks: a tracked line range per run that carries its decorations (ran
" sign, end-of-line status, inline output). Neovim uses extmarks, Vim text
" properties plus signs. Also the status shown on `# @setup` lines.

let s:marks = {}
let s:next_id = 0
" Vim: sign ids placed for each mark id.
let s:signs = {}

" Mark lines l1..l2 of buf; returns the mark id.
function! shell#mark#add(buf, l1, l2) abort
  let end_col = strlen(get(getbufline(a:buf, a:l2), 0, ''))
  if has('nvim')
    let id = nvim_buf_set_extmark(a:buf, s:ns('run'), a:l1 - 1, 0,
          \ {'end_row': a:l2 - 1, 'end_col': end_col, 'invalidate': v:true})
  else
    let s:next_id += 1
    let id = s:next_id
    call s:prop_type('ShellRun', '')
    call prop_add(a:l1, 1, {'end_lnum': a:l2, 'end_col': end_col + 1, 'id': id, 'type': 'ShellRun', 'bufnr': a:buf})
  endif
  call add(s:list(a:buf), id)
  return id
endfunction

" Current [l1, l2] of a mark, or [] when its lines are gone.
function! shell#mark#range(buf, id) abort
  if !bufexists(a:buf) || index(s:list(a:buf), a:id) < 0
    return []
  endif
  if has('nvim')
    let m = nvim_buf_get_extmark_by_id(a:buf, s:ns('run'), a:id, {'details': v:true})
    if empty(m) || get(m[2], 'invalid', v:false)
      return []
    endif
    let end = m[2].end_row
    if m[2].end_col == 0 && end > m[0]
      let end -= 1
    endif
    return [m[0] + 1, end + 1]
  endif
  let lnums = map(prop_list(1, {'bufnr': a:buf, 'end_lnum': -1, 'ids': [a:id], 'types': ['ShellRun']}), 'v:val.lnum')
  return empty(lnums) ? [] : [min(lnums), max(lnums)]
endfunction

" Ids of marks in buf overlapping lines l1..l2.
function! shell#mark#overlapping(buf, l1, l2) abort
  return filter(copy(s:list(a:buf)), {_, id -> s:overlaps(shell#mark#range(a:buf, id), a:l1, a:l2)})
endfunction

function! s:overlaps(r, l1, l2) abort
  return !empty(a:r) && a:r[0] <= a:l2 && a:l1 <= a:r[1]
endfunction

" Decorate a mark. opts: 'status' (chunks [[text, group], ...] after its
" first line), 'sign' (1: ran sign on each line), 'lines' (virtual lines
" below it, each a list of chunks).
function! shell#mark#show(buf, id, opts) abort
  let r = shell#mark#range(a:buf, a:id)
  if empty(r)
    return
  endif
  let status = map(copy(get(a:opts, 'status', [])), '[" " . v:val[0], v:val[1]]')
  let lines = get(a:opts, 'lines', [])
  if has('nvim')
    let m = nvim_buf_get_extmark_by_id(a:buf, s:ns('run'), a:id, {'details': v:true})
    let o = {'id': a:id, 'end_row': m[2].end_row, 'end_col': m[2].end_col, 'invalidate': v:true}
    if !empty(status)
      let o.virt_text = status
    endif
    if get(a:opts, 'sign', 0)
      let o.sign_text = get(g:, 'shell_sign', '▏')
      let o.sign_hl_group = 'ShellRan'
    endif
    call nvim_buf_set_extmark(a:buf, s:ns('run'), m[0], m[1], o)
    silent! call nvim_buf_del_extmark(a:buf, s:ns('out'), a:id)
    if !empty(lines)
      call nvim_buf_set_extmark(a:buf, s:ns('out'), r[1] - 1, 0, {'id': a:id, 'virt_lines': lines})
    endif
    return
  endif
  call s:vim_undecorate(a:buf, r)
  for sign in get(s:signs, a:id, [])
    call sign_unplace('shell_ran', {'buffer': a:buf, 'id': sign})
  endfor
  for [text, group] in status
    call prop_add(r[0], 0, {'type': s:prop_type('ShellVT' . group, group), 'bufnr': a:buf, 'text': text, 'text_align': 'after'})
  endfor
  for chunks in lines
    let group = empty(chunks) ? 'ShellOutput' : chunks[0][1]
    call prop_add(r[1], 0, {'type': s:prop_type('ShellVL' . group, group), 'bufnr': a:buf,
          \ 'text': join(map(copy(chunks), 'v:val[0]'), ''), 'text_align': 'below'})
  endfor
  if get(a:opts, 'sign', 0)
    let s:signs[a:id] = map(range(r[0], r[1]), 'sign_place(0, "shell_ran", "ShellRan", a:buf, {"lnum": v:val, "priority": 5})')
  endif
endfunction

function! shell#mark#del(buf, id) abort
  let r = shell#mark#range(a:buf, a:id)
  call filter(s:list(a:buf), 'v:val != a:id')
  if !bufexists(a:buf)
    return
  endif
  if has('nvim')
    call nvim_buf_del_extmark(a:buf, s:ns('run'), a:id)
    silent! call nvim_buf_del_extmark(a:buf, s:ns('out'), a:id)
    return
  endif
  call prop_remove({'type': 'ShellRun', 'id': a:id, 'both': 1, 'bufnr': a:buf, 'all': 1})
  if !empty(r)
    call s:vim_undecorate(a:buf, r)
  endif
  for sign in get(s:signs, a:id, [])
    call sign_unplace('shell_ran', {'buffer': a:buf, 'id': sign})
  endfor
  silent! call remove(s:signs, a:id)
endfunction

function! shell#mark#clear(buf) abort
  for id in copy(s:list(a:buf))
    call shell#mark#del(a:buf, id)
  endfor
  call shell#mark#regions(a:buf, [])
  if !has('nvim') && bufexists(a:buf)
    " Text properties go away with replaced lines; clear what is left.
    call sign_unplace('shell_ran', {'buffer': a:buf})
    let types = filter(prop_type_list(), 'v:val =~# "^ShellV[TL]"')
    if !empty(types)
      call prop_remove({'types': types, 'bufnr': a:buf, 'all': 1})
    endif
  endif
endfunction

" Lines of buf that have the ran sign.
function! shell#mark#ran_lines(buf) abort
  if !has('nvim')
    return sort(map(sign_getplaced(a:buf, {'group': 'shell_ran'})[0].signs, 'v:val.lnum'), 'n')
  endif
  let lnums = []
  for id in s:list(a:buf)
    let m = nvim_buf_get_extmark_by_id(a:buf, s:ns('run'), id, {'details': v:true})
    if !empty(m) && has_key(m[2], 'sign_text')
      let r = shell#mark#range(a:buf, id)
      call extend(lnums, empty(r) ? [] : range(r[0], r[1]))
    endif
  endfor
  return sort(lnums, 'n')
endfunction

" End-of-line status text of the mark (for tests).
function! shell#mark#status(buf, id) abort
  if has('nvim')
    let m = nvim_buf_get_extmark_by_id(a:buf, s:ns('run'), a:id, {'details': v:true})
    return empty(m) ? '' : trim(join(map(get(m[2], 'virt_text', []), 'v:val[0]'), ''))
  endif
  let r = shell#mark#range(a:buf, a:id)
  return empty(r) ? '' : trim(join(map(filter(prop_list(r[0], {'bufnr': a:buf}),
        \ 'v:val.type =~# "^ShellVT"'), 'v:val.text'), ''))
endfunction

" Virtual lines below the mark, as text (for tests).
function! shell#mark#lines(buf, id) abort
  let r = shell#mark#range(a:buf, a:id)
  if empty(r)
    return []
  endif
  if has('nvim')
    let m = nvim_buf_get_extmark_by_id(a:buf, s:ns('out'), a:id, {'details': v:true})
    return empty(m) ? [] : map(copy(m[2].virt_lines), 'join(map(copy(v:val), "v:val[0]"), "")')
  endif
  " prop_list() has them last-added first; they display in the added order.
  return reverse(map(filter(prop_list(r[1], {'bufnr': a:buf}), 'v:val.type =~# "^ShellVL"'), 'v:val.text'))
endfunction

" Replace the setup-region statuses of buf: [[lnum, chunks], ...].
function! shell#mark#regions(buf, items) abort
  if !bufexists(a:buf)
    return
  endif
  if has('nvim')
    call nvim_buf_clear_namespace(a:buf, s:ns('region'), 0, -1)
    for [lnum, chunks] in a:items
      call nvim_buf_set_extmark(a:buf, s:ns('region'), lnum - 1, 0,
            \ {'virt_text': map(copy(chunks), '[" " . v:val[0], v:val[1]]')})
    endfor
    return
  endif
  let types = filter(prop_type_list(), 'v:val =~# "^ShellRegion"')
  if !empty(types)
    call prop_remove({'types': types, 'bufnr': a:buf, 'all': 1})
  endif
  for [lnum, chunks] in a:items
    for [text, group] in chunks
      call prop_add(lnum, 0, {'type': s:prop_type('ShellRegion' . group, group), 'bufnr': a:buf,
            \ 'text': ' ' . text, 'text_align': 'after'})
    endfor
  endfor
endfunction

" Region status text on lnum (for tests).
function! shell#mark#region_status(buf, lnum) abort
  if has('nvim')
    let marks = nvim_buf_get_extmarks(a:buf, s:ns('region'), [a:lnum - 1, 0], [a:lnum - 1, -1], {'details': v:true})
    return trim(join(map(marks, 'join(map(copy(v:val[3].virt_text), "v:val[0]"), "")'), ''))
  endif
  return trim(join(map(filter(prop_list(a:lnum, {'bufnr': a:buf}), 'v:val.type =~# "^ShellRegion"'), 'v:val.text'), ''))
endfunction

function! s:vim_undecorate(buf, r) abort
  let types = filter(prop_type_list(), 'v:val =~# "^ShellV[TL]"')
  if !empty(types)
    call prop_remove({'types': types, 'bufnr': a:buf, 'all': 1}, a:r[0], a:r[1])
  endif
endfunction

function! s:prop_type(name, group) abort
  if empty(prop_type_get(a:name))
    call prop_type_add(a:name, a:group ==# '' ? {} : {'highlight': a:group})
  endif
  return a:name
endfunction

function! s:list(buf) abort
  if !has_key(s:marks, a:buf)
    let s:marks[a:buf] = []
  endif
  return s:marks[a:buf]
endfunction

function! s:ns(name) abort
  return nvim_create_namespace('shell.' . a:name)
endfunction
