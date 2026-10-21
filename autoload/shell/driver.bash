# shell.vim session driver for bash, sourced via:
#   bash -c '. "$1"' <script> <driver> <dir> <root>
# Reads requests "<kind> <id>" from stdin; the code is in <dir>/<id>.
# Each "run" executes in a background subshell whose final state (variables,
# functions, aliases, options, positional args, cwd) is dumped on EXIT and
# sourced back here, so `exit` / `set -e` only end that run.
__sh_dir=$2
cd -- "$3" || exit 1
set --
shopt -s expand_aliases
__sh_opts=
__sh_args=()

# Names of variables that are carried between runs.
__sh_names() {
  local __sh_ro __sh_v
  __sh_ro=" $(readonly -p | sed -n 's/^declare -[^ ]* \([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' | tr '\n' ' ') "
  for __sh_v in $(compgen -v); do
    case $__sh_v in
      __sh_*|BASH*|_|RANDOM|SECONDS|LINENO|PIPESTATUS|FUNCNAME|GROUPS|HISTCMD|DIRSTACK|COMP_*|SHLVL|PWD|OLDPWD|PPID|OPTIND|OPTARG) continue ;;
    esac
    case $__sh_ro in *" $__sh_v "*) continue ;; esac
    printf "%s\n" "$__sh_v"
  done
}

__sh_dump() {
  local __sh_rc=$? __sh_flags=$- __sh_vs __sh_o __sh_v __sh_d __sh_k __sh_x __sh_ks
  trap - EXIT
  # Command substitution resets errexit; take it from $- instead.
  __sh_o=$(set +o | grep -v -e monitor -e errexit; shopt -p | grep -v login_shell)
  case $__sh_flags in *e*) __sh_o+=$'\nset -e' ;; *) __sh_o+=$'\nset +e' ;; esac
  set +eux
  {
    printf "__sh_opts=%q\n" "$__sh_o"
    __sh_vs=$(__sh_names)
    printf '__sh_keep=%q\n' " $(echo $__sh_vs) "
    [ -n "$__sh_vs" ] && declare -p $__sh_vs
    # declare -p mangles some bytes, so reassign the values with %q, which
    # round-trips any byte. Array elements one by one: bash 3.2 also mangles
    # \001 in compound assignments.
    for __sh_v in $__sh_vs; do
      __sh_d=$(declare -p "$__sh_v")
      case $__sh_d in *=*) ;; *) continue ;; esac
      __sh_d=${__sh_d#declare -}
      case ${__sh_d%% *} in
        *[aA]*)
          printf '%s=()\n' "$__sh_v"
          eval "__sh_ks=(\"\${!$__sh_v[@]}\")"
          for __sh_k in "${__sh_ks[@]}"; do
            eval "__sh_x=\${$__sh_v[\$__sh_k]}"
            printf '%s[%q]=%q\n' "$__sh_v" "$__sh_k" "$__sh_x"
          done
          ;;
        *) printf '%s=%q\n' "$__sh_v" "${!__sh_v}" ;;
      esac
    done
    declare -f
    alias -p
    __sh_args=("$@")
    declare -p __sh_args
    printf 'cd -- %q\n' "$PWD"
  } >"$__sh_dir/dump" 2>/dev/null
  exit $__sh_rc
}

while IFS= read -r __sh_req; do
  __sh_kind=${__sh_req%% *}
  __sh_id=${__sh_req#* }
  rm -f "$__sh_dir/dump"
  case $__sh_kind in
    init)
      eval "$(cat "$__sh_dir/$__sh_id")" </dev/null >/dev/null 2>&1
      __sh_st=$?
      ;;
    file)
      ( eval "$(cat "$__sh_dir/$__sh_id")" ) </dev/null 2>&1 &
      echo $! >"$__sh_dir/pid"
      wait $!
      __sh_st=$?
      ;;
    run)
      (
        if [ ${#__sh_args[@]} -gt 0 ]; then set -- "${__sh_args[@]}"; fi
        eval "$__sh_opts"
        trap '__sh_dump "$@"' EXIT
        eval "$(cat "$__sh_dir/$__sh_id")"
      ) </dev/null 2>&1 &
      echo $! >"$__sh_dir/pid"
      wait $!
      __sh_st=$?
      if [ -s "$__sh_dir/dump" ]; then
        __sh_keep=
        . "$__sh_dir/dump"
        for __sh_n in $(__sh_names); do
          case $__sh_keep in *" $__sh_n "*) ;; *) unset "$__sh_n" ;; esac
        done
      fi
      ;;
    *) __sh_st=2 ;;
  esac
  rm -f "$__sh_dir/$__sh_id" "$__sh_dir/pid"
  printf "\036SHDONE %s %s %s\n" "$__sh_id" "$__sh_st" "$PWD"
done
