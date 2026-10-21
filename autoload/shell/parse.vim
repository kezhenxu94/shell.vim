" Split shell code into commands without a parser: tracks quotes, `\`
" continuations, trailing |/&&/||, heredocs and if/for/while/case/{ }/( ).

let s:openers = {'if': 'if', 'case': 'case', 'for': 'loop', 'while': 'loop', 'until': 'loop', 'select': 'loop'}
let s:closers = {'fi': 'if', 'esac': 'case', 'done': 'loop'}

" Commands in lines as [{'start': lnum, 'end': lnum}, ...] (1-based).
" Blank and comment-only lines between commands belong to none.
function! shell#parse#statements(lines) abort
  let stmts = []
  let st = {'stack': [], 'quote': '', 'heredocs': [], 'cont': 0, 'cmdpos': 1, 'fn': 0}
  let start = 0
  let lnum = 0
  for line in a:lines
    let lnum += 1
    if !empty(st.heredocs)
      let [delim, strip] = st.heredocs[0]
      if (strip ? substitute(line, '^\t*', '', '') : line) ==# delim
        call remove(st.heredocs, 0)
      endif
    else
      let backslash = st.cont == 2
      if !backslash && empty(st.quote)
        let st.cmdpos = 1
      endif
      let st.cont = 0
      let had = s:scan(st, line)
      if !start && (had || !empty(st.quote))
        let start = lnum
      endif
    endif
    if start && empty(st.stack) && empty(st.quote) && empty(st.heredocs) && !st.cont
      call add(stmts, {'start': start, 'end': lnum})
      let start = 0
    endif
  endfor
  if start
    call add(stmts, {'start': start, 'end': len(a:lines)})
  endif
  return stmts
endfunction

" Scan one line, updating st. Returns 1 if the line has any code.
function! s:scan(st, line) abort
  let st = a:st
  let n = strlen(a:line)
  let i = 0
  let had = 0
  while i < n
    let c = a:line[i]
    if st.quote ==# "'"
      let j = stridx(a:line, "'", i)
      let i = j < 0 ? n : j + 1
      if j >= 0 | let st.quote = '' | endif
      continue
    elseif st.quote !=# ''
      " ", ` and $' end at an unescaped closing quote.
      let close = st.quote ==# "$'" ? "'" : st.quote
      if c ==# '\'
        let i += 2
        continue
      elseif c ==# close
        let st.quote = ''
      endif
      let i += 1
      continue
    endif
    if c =~# '\s'
      let i += 1
      continue
    endif
    if c ==# '#' && (i == 0 || a:line[i - 1] =~# '[[:space:];&|()]')
      break
    endif
    let had = 1
    let st.cont = 0
    if c ==# '\'
      if i == n - 1
        let st.cont = 2
      endif
      let st.cmdpos = 0
      let i += 2
    elseif c ==# "'" || c ==# '"' || c ==# '`'
      let st.quote = c
      let st.cmdpos = 0
      let i += 1
    elseif c ==# '$'
      let next = a:line[i + 1]
      if next ==# "'"
        let st.quote = "$'"
        let i += 2
      elseif next ==# '{'
        let i = s:skip_braces(a:line, i + 1)
      elseif next ==# '('
        call add(st.stack, '(')
        let st.cmdpos = 1
        let i += 2
        continue
      else
        let i += 1
      endif
      let st.cmdpos = 0
    elseif c ==# ';' || c ==# '&' || c ==# '|'
      let op = matchstr(a:line, '^\%(&&\|||\||&\|;;&\|;;\|;&\|[;&|]\)', i)
      let st.cont = op =~# '^\%(&&\|||\||&\||\)$'
      let st.cmdpos = 1
      let i += strlen(op)
    elseif c ==# '('
      call add(st.stack, '(')
      let st.cmdpos = 1
      let i += 1
    elseif c ==# ')'
      if get(st.stack, -1, '') ==# '('
        call remove(st.stack, -1)
      endif
      " Inside case, `)` ends a pattern.
      let st.cmdpos = 1
      let i += 1
    elseif a:line[i : i + 2] ==# '<<<'
      let st.cmdpos = 0
      let i += 3
    elseif a:line[i : i + 1] ==# '<<'
      let m = matchlist(a:line, '^<<\(-\=\)\s*\([''"]\=\)\([^[:space:];&|<>()''"]\+\)\2', i)
      if !empty(m)
        call add(st.heredocs, [m[3], m[1] ==# '-'])
        let i += strlen(m[0])
      else
        let i += 2
      endif
      let st.cmdpos = 0
    elseif c ==# '{' && st.cmdpos && a:line[i + 1] =~# '^\s\=$'
      call add(st.stack, '{')
      let i += 1
    elseif c ==# '}' && st.cmdpos && get(st.stack, -1, '') ==# '{'
      call remove(st.stack, -1)
      let st.cmdpos = 0
      let i += 1
    else
      let word = matchstr(a:line, '^[^[:space:];&|()<>''"`$\\]\+', i)
      if word ==# ''
        let st.cmdpos = 0
        let i += 1
        continue
      endif
      let i += strlen(word)
      if st.fn
        " `function name` is followed by its body at command position.
        let st.fn = 0
        let st.cmdpos = 1
      elseif !st.cmdpos
      elseif has_key(s:openers, word)
        call add(st.stack, s:openers[word])
        let st.cmdpos = word ==# 'if' || word ==# 'while' || word ==# 'until'
      elseif has_key(s:closers, word)
        if get(st.stack, -1, '') ==# s:closers[word]
          call remove(st.stack, -1)
        endif
        let st.cmdpos = 0
      elseif word ==# 'function'
        let st.fn = 1
        let st.cmdpos = 0
      elseif index(['then', 'do', 'else', 'elif', '!', 'time'], word) < 0
        let st.cmdpos = 0
      endif
    endif
  endwhile
  return had
endfunction

" Index just past the } matching the { at i.
function! s:skip_braces(line, i) abort
  let depth = 0
  let i = a:i
  while i < strlen(a:line)
    if a:line[i] ==# '{'
      let depth += 1
    elseif a:line[i] ==# '}'
      let depth -= 1
      if depth == 0
        return i + 1
      endif
    endif
    let i += 1
  endwhile
  return i
endfunction

" Setup regions: [{'start', 'end', 'hash'}, ...] where start/end are the
" first/last lines between the markers (1-based, may be empty: end < start).
function! shell#parse#regions(lines) abort
  let [open, close] = get(g:, 'shell_setup_markers', ['# @setup', '# @end'])
  let regions = []
  let start = 0
  let lnum = 0
  for line in a:lines
    let lnum += 1
    let line = trim(line)
    if !start && line ==# open
      let start = lnum + 1
    elseif start && line ==# close
      call add(regions, {'start': start, 'end': lnum - 1,
            \ 'hash': sha256(join(a:lines[start - 1 : lnum - 2], "\n"))})
      let start = 0
    endif
  endfor
  return regions
endfunction
