if exists('g:loaded_shell')
  finish
endif
let g:loaded_shell = 1

command! -range -nargs=* -complete=customlist,shell#complete Sh call shell#command(<range>, <line1>, <line2>, <q-args>)

nnoremap <silent> <Plug>(shell-run) :<C-u>Sh run<CR>
xnoremap <silent> <Plug>(shell-run-selection) :Sh run<CR>
nnoremap <silent> <Plug>(shell-run-tocursor) :<C-u>Sh tocursor<CR>
nnoremap <silent> <Plug>(shell-run-file) :<C-u>Sh file<CR>
nnoremap <silent> <Plug>(shell-actions) :<C-u>Sh actions<CR>
nnoremap <silent> <Plug>(shell-history) :<C-u>Sh history<CR>

highlight default link ShellRan Comment
highlight default link ShellError ErrorMsg
highlight default link ShellDiagnostic ErrorMsg
highlight default link ShellHeader Title
highlight default link ShellMuted Comment
highlight default link ShellOutput Comment
highlight default link ShellCode Statement
highlight default link ShellLens Comment
highlight default link ShellRunning Special
highlight default link ShellWarn WarningMsg
if has('nvim')
  highlight default link ShellOk DiagnosticOk
  highlight default link ShellFail DiagnosticError
else
  highlight default ShellOk ctermfg=2 guifg=SeaGreen
  highlight default ShellFail ctermfg=1 guifg=Red
endif

function! s:mappings() abort
  if get(g:, 'shell_no_mappings', 0)
    return
  endif
  nmap <buffer> <LocalLeader>rr <Plug>(shell-run)
  xmap <buffer> <LocalLeader>r <Plug>(shell-run-selection)
  nmap <buffer> <LocalLeader>rtc <Plug>(shell-run-tocursor)
  nmap <buffer> <LocalLeader>rf <Plug>(shell-run-file)
  nmap <buffer> <LocalLeader>ra <Plug>(shell-actions)
  nmap <buffer> <LocalLeader>rh <Plug>(shell-history)
endfunction

augroup shell
  autocmd!
  autocmd FileType sh,zsh call s:mappings()
  autocmd BufWinEnter,TextChanged,InsertLeave * if &filetype =~# '^\%(sh\|zsh\)$' | call shell#refresh(bufnr('%')) | endif
  if has('menu')
    autocmd MenuPopup * if &filetype =~# '^\%(sh\|zsh\)$' | call shell#actions#popup() | else | silent! aunmenu PopUp.Shell | endif
  endif
  autocmd BufWipeout * call shell#detach(str2nr(expand('<abuf>')))
  autocmd VimLeavePre * call shell#stop_all()
augroup END
