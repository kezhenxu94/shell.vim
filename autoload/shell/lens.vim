" Codelens: a virtual line above each command that has run before, with
" its run count and last result from the history.

function! shell#lens#enabled() abort
  return get(g:, 'shell_codelens', 1) && shell#history#enabled()
endfunction

" Lenses for buf as [[lnum, text, result_group], ...]: one per command
" whose exact code is in the history of script.
function! shell#lens#items(buf, script) abort
  let runs = {}
  for e in shell#history#list(a:script)
    let runs[e.hash] = [get(runs, e.hash, [0])[0] + 1, e]
  endfor
  if empty(runs)
    return []
  endif
  let lines = getbufline(a:buf, 1, '$')
  let items = []
  for st in shell#parse#statements(lines)
    let hash = sha256(join(lines[st.start - 1 : st.end - 1], "\n"))
    if has_key(runs, hash)
      let [n, last] = runs[hash]
      call add(items, [st.start, printf('↺ %d run%s · last %s · %s', n, n == 1 ? '' : 's',
            \ shell#history#result(last), shell#history#ago(last.time)), last.status ? 'ShellFail' : 'ShellOk'])
    endif
  endfor
  return items
endfunction

" Redraw the lenses of buf (a script or its scratch buffer).
function! shell#lens#render(buf, script) abort
  let items = shell#lens#enabled() && a:script !=# '' ? shell#lens#items(a:buf, a:script) : []
  if has('nvim')
    let ns = nvim_create_namespace('shell.lens')
    call nvim_buf_clear_namespace(a:buf, ns, 0, -1)
    for [lnum, text, group] in items
      let [count, result] = matchlist(text, '^\(.\{-} · last \)\(.*\)$')[1:2]
      call nvim_buf_set_extmark(a:buf, ns, lnum - 1, 0, {'virt_lines_above': v:true,
            \ 'virt_lines': [[[s:indent(a:buf, lnum) . count, 'ShellLens'], [result, group]]]})
    endfor
    return
  endif
  if empty(prop_type_get('ShellLens'))
    call prop_type_add('ShellLens', {'highlight': 'ShellLens'})
  endif
  call prop_remove({'type': 'ShellLens', 'bufnr': a:buf, 'all': 1})
  for [lnum, text, group] in items
    call prop_add(lnum, 0, {'type': 'ShellLens', 'bufnr': a:buf, 'text': s:indent(a:buf, lnum) . text, 'text_align': 'above'})
  endfor
endfunction

function! s:indent(buf, lnum) abort
  return matchstr(get(getbufline(a:buf, a:lnum), 0, ''), '^\s*')
endfunction

" Lens texts of buf as [[lnum, text], ...] (for tests).
function! shell#lens#get(buf) abort
  if has('nvim')
    let marks = nvim_buf_get_extmarks(a:buf, nvim_create_namespace('shell.lens'), 0, -1, {'details': v:true})
    return map(marks, '[v:val[1] + 1, trim(join(map(copy(v:val[3].virt_lines[0]), "v:val[0]"), ""))]')
  endif
  return map(filter(prop_list(1, {'bufnr': a:buf, 'end_lnum': -1}), 'v:val.type ==# "ShellLens"'), '[v:val.lnum, v:val.text]')
endfunction
