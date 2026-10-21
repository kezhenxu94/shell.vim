" Code actions: what can be done at the cursor, as a menu (vim.ui.select in
" Neovim, a popup in Vim) and in the right-click PopUp menu.

" Actions at the cursor in the current buffer: [{'title', 'Fn'}, ...].
function! shell#actions#list() abort
  let items = []
  let r = shell#statement_range(line('.'))
  if !empty(r)
    call add(items, {'title': 'Run command (' . s:lines(r[0], r[1]) . ')', 'Fn': function('shell#run', r)})
  endif
  call add(items, {'title': 'Run to the cursor (' . s:lines(1, line('.')) . ')', 'Fn': function('shell#tocursor')})
  let script = shell#script(bufnr('%'))
  if script !=# '' && filereadable(script)
    call add(items, {'title': 'Run file', 'Fn': function('shell#file', [''])})
  endif
  if !empty(shell#parse#regions(getbufline(shell#source(bufnr('%')), 1, '$')))
    call add(items, {'title': 'Re-apply setup regions', 'Fn': function('shell#setup')})
  endif
  call add(items, {'title': 'Open scratch buffer', 'Fn': function('shell#scratch')})
  if script !=# '' && shell#history#enabled()
    let entries = empty(r) ? [] : shell#history#for_code(script, join(getline(r[0], r[1]), "\n"))
    if !empty(entries)
      call add(items, {'title': 'History of this command (' . len(entries) . ')', 'Fn': function('shell#actions#history', [entries])})
    endif
    let all = shell#history#list(script)
    if !empty(all)
      call add(items, {'title': 'History of this file (' . len(all) . ')', 'Fn': function('shell#actions#history', [all])})
    endif
  endif
  let sess = shell#session()
  if !empty(sess) && !empty(sess.cur)
    call add(items, {'title': 'Interrupt the run', 'Fn': function('shell#interrupt')})
  endif
  if !empty(sess)
    call add(items, {'title': 'Restart the session', 'Fn': function('shell#restart')})
  endif
  return items
endfunction

function! s:lines(l1, l2) abort
  return 'L' . a:l1 . (a:l1 == a:l2 ? '' : '-' . a:l2)
endfunction

function! shell#actions#menu() abort
  call shell#actions#select(shell#actions#list(), 'Shell actions')
endfunction

" History entries of the command under the cursor, else of the file.
function! shell#actions#history_menu() abort
  let script = shell#script(bufnr('%'))
  if script ==# ''
    return s:warn('no history for a buffer without a file')
  endif
  let r = shell#statement_range(line('.'))
  let entries = empty(r) ? [] : shell#history#for_code(script, join(getline(r[0], r[1]), "\n"))
  call shell#actions#history(empty(entries) ? shell#history#list(script) : entries)
endfunction

" Pick one of entries (newest first) to show it in [Shell].
function! shell#actions#history(entries) abort
  let items = map(reverse(copy(a:entries)), {_, e -> {'title': shell#history#title(e), 'Fn': function('shell#history#show', [e])}})
  call shell#actions#select(items, 'Shell history')
endfunction

" Let the user pick one of items and call its Fn.
function! shell#actions#select(items, prompt) abort
  if empty(a:items)
    return s:warn('nothing to show')
  endif
  let titles = map(copy(a:items), 'v:val.title')
  if has('nvim')
    " A Vim lambda isn't callable from Lua: call back by name instead.
    let s:choices = a:items
    call luaeval('vim.ui.select(_A[1], {prompt = _A[2]}, function(_, idx)'
          \ . ' if idx then vim.fn["shell#actions#chosen"](idx) end end)', [titles, a:prompt])
  else
    call popup_menu(titles, {'title': ' ' . a:prompt . ' ', 'callback': {_, i -> i > 0 ? a:items[i - 1].Fn() : 0}})
  endif
endfunction

function! shell#actions#chosen(idx) abort
  call s:choices[a:idx - 1].Fn()
endfunction

" Fill the PopUp menu's Shell submenu for the cursor position.
function! shell#actions#popup() abort
  silent! aunmenu PopUp.Shell
  let s:popup = shell#actions#list()
  let i = 0
  for item in s:popup
    if item.title !~# '^History of'
      execute 'anoremenu <silent> PopUp.Shell.' . s:escape(item.title) . ' <Cmd>call shell#actions#popup_do(' . i . ')<CR>'
    endif
    let i += 1
  endfor
  let script = shell#script(bufnr('%'))
  if script ==# '' || !shell#history#enabled()
    return
  endif
  let r = shell#statement_range(line('.'))
  let entries = empty(r) ? [] : shell#history#for_code(script, join(getline(r[0], r[1]), "\n"))
  let s:popup_history = reverse(copy(empty(entries) ? shell#history#list(script) : entries))[: get(g:, 'shell_menu_history', 15) - 1]
  let i = 0
  for e in s:popup_history
    execute 'anoremenu <silent> PopUp.Shell.History.' . s:escape(shell#history#title(e)) . ' <Cmd>call shell#history#show(shell#actions#popup_entry(' . i . '))<CR>'
    let i += 1
  endfor
endfunction

function! shell#actions#popup_do(i) abort
  call s:popup[a:i].Fn()
endfunction

function! shell#actions#popup_entry(i) abort
  return s:popup_history[a:i]
endfunction

function! s:escape(name) abort
  return escape(substitute(a:name, '&', '\&\&', 'g'), ' .\|	')
endfunction

function! s:warn(msg) abort
  echohl WarningMsg | echomsg 'shell: ' . a:msg | echohl None
endfunction
