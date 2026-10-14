#!/usr/bin/env bash
# PreToolUse/Bash: nega comandos destrutivos, inclusive dentro de sh -c, bash -c e $().
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq_strict
kit_read_input

CMD="$(kit_field '.tool_input.command')"
[ -n "$CMD" ] || exit 0

PROJECT="$(kit_cwd)"
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && PROJECT="$(kit_norm_path "$CLAUDE_PROJECT_DIR")"

# Aspas e escapes removidos: o conteudo de sh -c "..." passa a ser analisado como texto comum.
FLAT="$(printf '%s' "$CMD" | tr -d "\"'\\\\" | tr '\t\r' '  ')"

has() { printf '%s' "$FLAT" | grep -Eiq -- "$1"; }

if has '(^|[^a-z0-9_])drop[[:space:]]+(database|table|schema)([^a-z0-9_]|$)'; then
  kit_deny_pretool "kit: DROP DATABASE/TABLE bloqueado. Rode manualmente se for intencional."
fi
if has '(^|[^a-z0-9_.-])truncate[[:space:]]+(table[[:space:]]|[a-z_`\[])'; then
  kit_deny_pretool "kit: TRUNCATE bloqueado. Rode manualmente se for intencional."
fi
if has '(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?([a-z/]*/)?(ba|z|da|k)?sh([[:space:]]|$)' ||
  has '(^|[^a-z])(ba|z|da|k)?sh[[:space:]]+(-[a-z]+[[:space:]]+)*<\([[:space:]]*(curl|wget)' ||
  has '(^|[^a-z])(ba|z|da|k)?sh[[:space:]]+-c[[:space:]]+\$\([[:space:]]*(curl|wget)'; then
  kit_deny_pretool "kit: execucao de script baixado da rede (curl/wget | sh) bloqueada."
fi
if has '(^|[^a-z0-9_./-])mkfs(\.[a-z0-9]+)?([[:space:]]|$)'; then
  kit_deny_pretool "kit: mkfs bloqueado."
fi
if has '(^|[^a-z0-9_-])dd[[:space:]].*of=/dev/' &&
  ! printf '%s' "$FLAT" | grep -Eiq 'of=/dev/(null|zero|stdout|stderr)([[:space:]]|$)'; then
  kit_deny_pretool "kit: dd escrevendo em dispositivo bloqueado."
fi

resolve() {
  local t="$1" base="$2"
  case "$t" in
    /* | [A-Za-z]:/*) ;;
    *) t="$base/$t" ;;
  esac
  realpath -m -- "$t" 2>/dev/null || printf '%s' "$t"
}

PROJECT_REAL="$(resolve "$PROJECT" /)"

# Retorna 0 se o alvo de rm -rf for perigoso.
rm_target_unsafe() {
  local t="$1" r
  case "$t" in
    '~'*) return 0 ;;
    '$'*) return 0 ;;
    '*' | '.*' | '.' | './' | './*') return 0 ;;
  esac
  r="$(resolve "$t" "$PROJECT")"
  case "$r" in
    "$PROJECT_REAL"/?*) return 1 ;;
  esac
  return 0
}

check_rm() {
  local -a w=("$@")
  local i=0 n=${#w[@]} tok rec=0 force=0 opts_done=0
  local -a targets=()
  while [ "$i" -lt "$n" ]; do
    tok="${w[$i]}"
    case "$tok" in
      sudo | doas | env | command | exec | nohup | time | nice | xargs | eval | builtin) i=$((i + 1)); continue ;;
      -*) if [ "$i" -gt 0 ] && [[ "${w[$((i - 1))]}" =~ ^(sudo|env|nice|xargs|time)$ ]]; then i=$((i + 1)); continue; fi ;;
      *=*) i=$((i + 1)); continue ;;
    esac
    break
  done
  [ "$i" -lt "$n" ] || return 0
  case "${w[$i]}" in
    rm | */rm | rm.exe) ;;
    sh | bash | zsh | dash | ksh | */sh | */bash)
      if [ "${w[$((i + 1))]:-}" = "-c" ]; then check_rm "${w[@]:$((i + 2))}"; fi
      return 0 ;;
    *) return 0 ;;
  esac
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    tok="${w[$i]}"
    if [ "$opts_done" -eq 0 ]; then
      case "$tok" in
        --) opts_done=1; i=$((i + 1)); continue ;;
        --recursive) rec=1; i=$((i + 1)); continue ;;
        --force) force=1; i=$((i + 1)); continue ;;
        --*) i=$((i + 1)); continue ;;
        -?*)
          [[ "$tok" == *[rR]* ]] && rec=1
          [[ "$tok" == *f* ]] && force=1
          i=$((i + 1)); continue ;;
      esac
    fi
    targets+=("$tok")
    i=$((i + 1))
  done
  [ "$rec" -eq 1 ] && [ "$force" -eq 1 ] || return 0
  for tok in "${targets[@]}"; do
    if rm_target_unsafe "$tok"; then
      kit_deny_pretool "kit: rm -rf em '$tok' bloqueado (fora do projeto, raiz, home ou alvo nao resolvivel)."
    fi
  done
  return 0
}

check_git() {
  local -a w=("$@")
  local i=0 n=${#w[@]} sub="" tok
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      sudo | env | command | exec | nohup | time | *=*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  case "${w[$i]:-}" in git | */git | git.exe) ;; *) return 0 ;; esac
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    tok="${w[$i]}"
    case "$tok" in
      -C | -c | --git-dir | --work-tree | --namespace) i=$((i + 2)); continue ;;
      -*) i=$((i + 1)); continue ;;
    esac
    sub="$tok"
    i=$((i + 1))
    break
  done
  local -a rest=("${w[@]:$i}")
  case "$sub" in
    push)
      for tok in "${rest[@]}"; do
        case "$tok" in
          --force | --force-if-includes) kit_deny_pretool "kit: git push --force bloqueado. Use --force-with-lease manualmente se necessario." ;;
          --*) ;;
          -*f*) kit_deny_pretool "kit: git push -f bloqueado. Use --force-with-lease manualmente se necessario." ;;
          +*) kit_deny_pretool "kit: git push com refspec forcado (+) bloqueado." ;;
        esac
      done ;;
    reset)
      for tok in "${rest[@]}"; do
        [ "$tok" = "--hard" ] && kit_deny_pretool "kit: git reset --hard bloqueado. Use git stash ou rode manualmente."
      done ;;
    clean)
      local flags=""
      for tok in "${rest[@]}"; do
        case "$tok" in
          --force) flags+="f" ;;
          --dry-run) flags+="n" ;;
          --*) ;;
          -*) flags+="${tok#-}" ;;
        esac
      done
      if [[ "$flags" == *f* ]] && [[ "$flags" == *[dxX]* ]] && [[ "$flags" != *n* ]]; then
        kit_deny_pretool "kit: git clean -fdx bloqueado. Rode git clean -n para ver o que seria apagado."
      fi ;;
  esac
  return 0
}

check_chmod() {
  local -a w=("$@")
  local tok rec=0 perm=0 is=0
  for tok in "${w[@]}"; do
    case "$tok" in
      chmod | */chmod) is=1 ;;
      --recursive) rec=1 ;;
      -*R*) rec=1 ;;
      777 | 0777 | a+rwx | ugo+rwx) perm=1 ;;
    esac
  done
  if [ "$is" -eq 1 ] && [ "$rec" -eq 1 ] && [ "$perm" -eq 1 ]; then
    kit_deny_pretool "kit: chmod -R 777 bloqueado."
  fi
  return 0
}

# Quebra em segmentos por separadores de comando e substituicao.
SEGMENTS="$(printf '%s' "$FLAT" | sed -E 's/(\|\||&&|\$\(|[;|&`()\n{}])/\n/g')"
while IFS= read -r seg; do
  [ -n "${seg// /}" ] || continue
  read -r -a words <<<"$seg"
  [ "${#words[@]}" -gt 0 ] || continue
  check_rm "${words[@]}"
  check_git "${words[@]}"
  check_chmod "${words[@]}"
done <<<"$SEGMENTS"

exit 0
