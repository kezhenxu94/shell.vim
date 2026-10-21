# shell.vim session driver for zsh, sourced via:
#   zsh -c '. "$1"' <script> <driver> <dir> <root>
# Reads requests "<kind> <id>" from stdin; the code is in <dir>/<id>.
# Each "run" executes in a background subshell whose final state (variables,
# functions, aliases, options, positional args, cwd) is dumped on EXIT and
# sourced back here, so `exit` / `set -e` only end that run.
__sh_dir=$2
__sh_script=$ZSH_ARGZERO
cd -- "$3" || exit 1
set --
__sh_opts=()
__sh_args=()

# Names of variables that are carried between runs. Special parameters are
# skipped, except the writable path-like ones.
__sh_names() {
  local __sh_v __sh_t
  for __sh_v in ${(k)parameters}; do
    __sh_t=${parameters[$__sh_v]}
    [[ $__sh_v == (__sh_*|_|PWD|OLDPWD|ZSH_*) || $__sh_t == *(readonly|local)* ]] && continue
    [[ $__sh_t == *special* && $__sh_v != (PATH|FPATH|MANPATH|CDPATH|IFS) ]] && continue
    print -r -- $__sh_v
  done
}

__sh_dump() {
  local __sh_rc=$? __sh_e=$options[errexit] __sh_o
  trap - EXIT
  # Command substitution may reset errexit; take it from $options instead.
  __sh_o=${(F)${(f)"$(setopt)":#errexit}}
  [[ $__sh_e == on ]] && __sh_o+=$'\nerrexit'
  emulate -L zsh
  local -a __sh_vs
  __sh_vs=(${(f)"$(__sh_names)"})
  {
    print -r -- "__sh_opts=(${(j: :)${(@qf)__sh_o}})"
    print -r -- "__sh_keep=(${(j: :)${(@q)__sh_vs}})"
    (( $#__sh_vs )) && typeset -p -- $__sh_vs
    # typeset -p mangles some bytes (0x1c is written as an ambiguous \C-\),
    # so reassign the values with (q) quoting, which round-trips any byte.
    local -a __sh_kv
    for __sh_v in $__sh_vs; do
      case ${parameters[$__sh_v]} in
        (scalar*) print -r -- "$__sh_v=${(q)${(P)__sh_v}}" ;;
        (array*) __sh_kv=("${(@P)__sh_v}") ;|
        (association*) __sh_kv=("${(@kvP)__sh_v}") ;|
        (array*|association*) print -r -- "$__sh_v=(${(j: :)${(@q)__sh_kv}})" ;;
      esac
    done
    typeset -f
    alias -L
    print -r -- "__sh_args=(${(j: :)${(@q)argv}})"
    print -r -- "cd -- ${(q)PWD}"
  } >$__sh_dir/dump 2>/dev/null
  exit $__sh_rc
}

while IFS= read -r __sh_req; do
  __sh_kind=${__sh_req%% *}
  __sh_id=${__sh_req#* }
  rm -f $__sh_dir/dump
  case $__sh_kind in
    (init)
      eval "$(<$__sh_dir/$__sh_id)" </dev/null >/dev/null 2>&1
      __sh_st=$?
      ;;
    (file)
      ( eval "$(<$__sh_dir/$__sh_id)" ) </dev/null 2>&1 &
      print $! >$__sh_dir/pid
      wait $!
      __sh_st=$?
      ;;
    (run)
      (
        0=$__sh_script
        set -- "${__sh_args[@]}"
        (( $#__sh_opts )) && setopt $__sh_opts
        trap '__sh_dump "$@"' EXIT
        eval "$(<$__sh_dir/$__sh_id)"
      ) </dev/null 2>&1 &
      print $! >$__sh_dir/pid
      wait $!
      __sh_st=$?
      if [[ -s $__sh_dir/dump ]]; then
        __sh_keep=()
        . $__sh_dir/dump
        for __sh_n in ${(f)"$(__sh_names)"}; do
          (( ${__sh_keep[(Ie)$__sh_n]} )) || unset $__sh_n
        done
      fi
      ;;
    (*) __sh_st=2 ;;
  esac
  rm -f $__sh_dir/$__sh_id $__sh_dir/pid
  printf "\036SHDONE %s %s %s\n" $__sh_id $__sh_st $PWD
done
