#!/usr/bin/env bash
# PreToolUse/Bash: nega comandos destrutivos, inclusive dentro de sh -c, bash -c, $() e crases.
# Compativel com bash 3.2. Qualquer erro inesperado bloqueia (exit 2).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_guard_fail_closed
kit_require_jq_strict --allow-jq-install
kit_read_input
kit_require_input

CMD="$(kit_field '.tool_input.command')"
[ -n "$CMD" ] || exit 0

CWD="$(kit_cwd)"
PROJECT="$CWD"
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && PROJECT="$(kit_norm_path "$CLAUDE_PROJECT_DIR")"
PROJECT_REAL="$(kit_path_norm "$PROJECT" /)"
START_DIR="$(kit_path_norm "$CWD" "$PROJECT_REAL")"
PROJECT_CMP="$(kit_fold "$PROJECT_REAL")"
PLATFORM="$(kit_platform)"

# No Git Bash, /c/pasta e C:/pasta sao o mesmo caminho, e /tmp e outras montagens tem um caminho
# Windows. cygpath resolve pela tabela de montagem, sem tocar no disco; sem ele, so a letra do drive.
msys_drive() {
  local p="$1" c=""
  if [ "$PLATFORM" = "windows" ]; then
    case "$p" in
      /*)
        command -v cygpath >/dev/null 2>&1 && c="$(cygpath -m -- "$p" 2>/dev/null | tr -d '\r')"
        if [ -n "$c" ]; then
          p="$c"
        else
          case "$p" in
            /[A-Za-z]) p="${p#/}:/" ;;
            /[A-Za-z]/*) p="${p:1:1}:${p:2}" ;;
          esac
        fi ;;
    esac
  fi
  printf '%s' "$p"
}

# Continuacao de linha vira espaco; escapes de aspas, $, crase e espaco perdem a barra; o resto
# das barras invertidas vira / (caminho Windows). Depois as aspas saem: o conteudo de sh -c "..."
# passa a ser analisado como texto comum.
FLAT="${CMD//\\$'\n'/ }"
FLAT="$(printf '%s' "$FLAT" | sed -E "s/\\\\([\"'\$\` ])/\\1/g; s/\\\\+/\\//g" | tr -d "\"'" | tr '\t\r' '  ')"

has() { printf '%s' "$FLAT" | grep -Eiq -- "$1"; }

# DROP/TRUNCATE: o texto inteiro so marca a suspeita; quem nega e check_sql, trecho a trecho.
DROP_RE='(^|[^a-z0-9_])drop[[:space:]]+(database|table|schema)([^a-z0-9_]|$)'
TRUNC_RE='(^|[^a-z0-9_.-])truncate[[:space:]]+(table[[:space:]]|[a-z_`\[])'
SQL_DROP=0
SQL_TRUNC=0
has "$DROP_RE" && SQL_DROP=1
has "$TRUNC_RE" && SQL_TRUNC=1
FIND_DELETE=0
has '(^|[[:space:]])-delete([[:space:]]|$)' && FIND_DELETE=1
ESC_PAREN=0
case "$CMD" in *'\('*) ESC_PAREN=1 ;; esac

# Shell que executa o que recebe: sh, bash, zsh, dash, ksh, fish, com ou sem caminho e prefixos
# como sudo, env, /usr/bin/env, nohup ou VAR=x.
SH_RE='([a-z0-9_./-]*/)?(ba|z|da|k|fi)?sh'
PFX_RE='((sudo|doas|env|command|exec|nohup|time|nice|stdbuf|[a-z0-9_./-]*/env)([[:space:]]+-[^[:space:]]*([[:space:]]+[a-z0-9_]+)?)*[[:space:]]+|[a-z_][a-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
if has "(curl|wget)[^;&]*\|[[:space:]]*${PFX_RE}${SH_RE}([[:space:]]|$)" ||
  has "(^|[^a-z0-9_])${SH_RE}([[:space:]]+-[a-z]*)*[[:space:]]+(\\\$\(|\`|<\()[[:space:]]*(curl|wget)" ||
  has "(^|[^a-z0-9_])(eval|source|\.)[[:space:]]+(\\\$\(|\`|<\()[[:space:]]*(curl|wget)"; then
  kit_deny_pretool "kit: execucao de script baixado da rede (curl/wget | sh) bloqueada."
fi
if has '(^|[^a-z0-9_./-])mkfs(\.[a-z0-9]+)?([[:space:]]|$)'; then
  kit_deny_pretool "kit: mkfs bloqueado."
fi
if has '(^|[^a-z0-9_-])dd[[:space:]].*of=/dev/' &&
  ! printf '%s' "$FLAT" | grep -Eiq 'of=/dev/(null|zero|stdout|stderr)([[:space:]]|$)'; then
  kit_deny_pretool "kit: dd escrevendo em dispositivo bloqueado."
fi

# Pasta corrente do trecho analisado, atualizada a cada cd. CUR_OK=0: cd para alvo nao resolvivel.
CUR="$START_DIR"
CUR_OK=1
XARGS=0

# Indice da primeira palavra que e o comando de fato, pulando palavras-chave do shell, VAR=x e
# prefixos que executam o comando seguinte (sudo, env, nice, timeout, xargs...), com as opcoes deles.
CMD_I=0
skip_prefix() {
  local -a w=("$@")
  local i=0 n=$# tok
  XARGS=0
  while [ "$i" -lt "$n" ]; do
    tok="${w[$i]}"
    case "$tok" in
      if | then | else | elif | fi | for | do | done | while | until | select | '!' | builtin | noglob | nohup | setsid | eval | -- )
        i=$((i + 1)); continue ;;
      [A-Za-z_]*=*) i=$((i + 1)); continue ;;
      sudo | doas | */sudo | */doas)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${w[$i]}" in
            -u | -g | -C | -h | -p | -U | -r | -t | -D | -R | -T) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        continue ;;
      env | */env)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${w[$i]}" in
            -u | --unset | -C | --chdir) i=$((i + 2)) ;;
            -* | [A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        continue ;;
      nice | */nice)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${w[$i]}" in
            -n | --adjustment) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        continue ;;
      timeout | */timeout)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${w[$i]}" in
            -s | -k | --signal | --kill-after) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        i=$((i + 1))
        continue ;;
      xargs | */xargs)
        XARGS=1
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${w[$i]}" in
            -I | -n | -P | -L | -d | -s | -E | -e | -a | --max-args | --max-procs | --delimiter | --arg-file) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        continue ;;
      command | */command)
        case "${w[$((i + 1))]:-}" in -v | -V) CMD_I=$n; return 0 ;; esac
        i=$((i + 1))
        [ "${w[$i]:-}" = "-p" ] && i=$((i + 1))
        continue ;;
      exec)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${w[$i]}" in
            -a) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        continue ;;
      time)
        i=$((i + 1))
        [ "${w[$i]:-}" = "-p" ] && i=$((i + 1))
        continue ;;
      stdbuf | ionice | chrt | taskset | unbuffer)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${w[$i]}" in
            -c | -n | -p) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        case "$tok" in taskset | chrt) i=$((i + 1)) ;; esac
        continue ;;
    esac
    break
  done
  CMD_I=$i
}

# Pasta onde comeca o primeiro componente com glob, ou o proprio caminho se nao houver glob.
glob_base() {
  local p="$1" out="" part IFS=/
  local -a parts=()
  read -r -a parts <<<"$p"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in *[*?[]*) break ;; esac
    out+="$part/"
  done
  out="${out%/}"
  [ -n "$out" ] || out="/"
  printf '%s' "$out"
}

# 0 se o alvo de rm -rf for perigoso: fora do projeto, o proprio projeto, home, variavel,
# substituicao de comando, alvo relativo depois de cd nao resolvivel ou glob que apaga o projeto.
rm_target_unsafe() {
  local t="$1" r b
  case "$t" in
    '~'* | *'$'* | *'`'*) return 0 ;;
  esac
  case "$t" in
    [A-Za-z]: | [A-Za-z]:[!/]*) return 0 ;;
    /* | [A-Za-z]:/*) ;;
    *)
      [ "$CUR_OK" -eq 1 ] || return 0
      case "${t%%/*}" in *[*?[]*) return 0 ;; esac ;;
  esac
  t="$(msys_drive "$t")"
  r="$(kit_path_norm "$t" "$CUR")"
  case "$t" in
    *[*?[]*)
      b="$(kit_fold "$(glob_base "$r")")"
      case "$b" in "$PROJECT_CMP"/?*) ;; *) return 0 ;; esac ;;
  esac
  r="$(kit_fold "$r")"
  case "$r" in "$PROJECT_CMP"/?*) return 1 ;; esac
  return 0
}

check_rm() {
  local -a w=("$@")
  local i=1 n=$# tok rec=0 force=0 opts_done=0
  local -a targets=()
  while [ "$i" -lt "$n" ]; do
    tok="${w[$i]}"
    if [ "$opts_done" -eq 0 ]; then
      case "$tok" in
        --) opts_done=1; i=$((i + 1)); continue ;;
        --recursive) rec=1; i=$((i + 1)); continue ;;
        --force) force=1; i=$((i + 1)); continue ;;
        --*) i=$((i + 1)); continue ;;
        -?*)
          case "$tok" in *[rR]*) rec=1 ;; esac
          case "$tok" in *f*) force=1 ;; esac
          i=$((i + 1)); continue ;;
      esac
    fi
    targets+=("$tok")
    i=$((i + 1))
  done
  [ "$rec" -eq 1 ] || return 0
  if [ "$XARGS" -eq 1 ]; then
    kit_deny_pretool "kit: rm -rf com alvos vindos do xargs bloqueado (alvo nao resolvivel). Liste os caminhos explicitamente."
  fi
  for tok in ${targets[@]+"${targets[@]}"}; do
    if rm_target_unsafe "$tok"; then
      kit_deny_pretool "kit: rm -rf em '$tok' bloqueado (fora do projeto, raiz, home ou alvo nao resolvivel)."
    fi
  done
  return 0
}

do_cd() {
  local -a w=("$@")
  local i=1 n=$# t=""
  case "${w[0]}" in popd) CUR_OK=0; return 0 ;; esac
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      --) i=$((i + 1)); break ;;
      -P | -L | -e | -@ | -n) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] && t="${w[$i]}"
  case "$t" in
    '' | - | '~'* | *'$'* | *'`'* | [+-][0-9]*) CUR_OK=0; return 0 ;;
    /* | [A-Za-z]:*) CUR="$(kit_path_norm "$(msys_drive "$t")" /)"; CUR_OK=1 ;;
    *) [ "$CUR_OK" -eq 1 ] && CUR="$(kit_path_norm "$t" "$CUR")" ;;
  esac
  return 0
}

check_git() {
  local -a w=("$@")
  local i=1 n=$# sub="" tok
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
  local -a rest=()
  [ "$i" -lt "$n" ] && rest=("${w[@]:$i}")
  case "$sub" in
    push)
      for tok in ${rest[@]+"${rest[@]}"}; do
        case "$tok" in
          --force | --force-if-includes) kit_deny_pretool "kit: git push --force bloqueado. Use --force-with-lease manualmente se necessario." ;;
          --mirror) kit_deny_pretool "kit: git push --mirror bloqueado (sobrescreve e apaga refs do remoto)." ;;
          --delete) kit_deny_pretool "kit: git push --delete bloqueado (apaga ref do remoto). Rode manualmente se for intencional." ;;
          --*) ;;
          -*f*) kit_deny_pretool "kit: git push -f bloqueado. Use --force-with-lease manualmente se necessario." ;;
          -*d*) kit_deny_pretool "kit: git push -d bloqueado (apaga ref do remoto). Rode manualmente se for intencional." ;;
          +*) kit_deny_pretool "kit: git push com refspec forcado (+) bloqueado." ;;
          :?*) kit_deny_pretool "kit: git push com refspec ':<ref>' bloqueado (apaga ref do remoto). Rode manualmente se for intencional." ;;
        esac
      done ;;
    reset)
      for tok in ${rest[@]+"${rest[@]}"}; do
        [ "$tok" = "--hard" ] && kit_deny_pretool "kit: git reset --hard bloqueado. Use git stash ou rode manualmente."
      done ;;
    clean)
      local flags=""
      for tok in ${rest[@]+"${rest[@]}"}; do
        case "$tok" in
          --force) flags+="f" ;;
          --dry-run) flags+="n" ;;
          --*) ;;
          -*) flags+="${tok#-}" ;;
        esac
      done
      case "$flags" in *f*) ;; *) return 0 ;; esac
      case "$flags" in *[dxX]*) ;; *) return 0 ;; esac
      case "$flags" in *n*) return 0 ;; esac
      kit_deny_pretool "kit: git clean -fdx bloqueado. Rode git clean -n para ver o que seria apagado." ;;
  esac
  return 0
}

check_chmod() {
  local tok rec=0 perm=0 is=0
  for tok in "$@"; do
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

# 0 se o caminho inicial de um find que apaga estiver fora do projeto ou nao for resolvivel.
find_start_unsafe() {
  local t="$1" r
  case "$t" in
    '~'* | *'$'* | *'`'*) return 0 ;;
  esac
  case "$t" in
    [A-Za-z]: | [A-Za-z]:[!/]*) return 0 ;;
    /* | [A-Za-z]:/*) ;;
    *) [ "$CUR_OK" -eq 1 ] || return 0 ;;
  esac
  r="$(kit_fold "$(kit_path_norm "$(msys_drive "$t")" "$CUR")")"
  case "$r" in "$PROJECT_CMP" | "$PROJECT_CMP"/*) return 1 ;; esac
  return 0
}

# find com -delete ou -exec rm: os caminhos iniciais precisam estar dentro do projeto.
check_find() {
  local -a w=("$@")
  local i=1 n=$# tok danger="$FIND_DELETE" inexec=0
  local -a starts=()
  while [ "$i" -lt "$n" ]; do
    tok="${w[$i]}"
    case "$tok" in
      -H | -L | -P) i=$((i + 1)); continue ;;
      -* | '!') break ;;
    esac
    starts+=("$tok")
    i=$((i + 1))
  done
  # "\(" chega aqui como "/" no fim do trecho (a barra invertida vira / e o parentese separa).
  if [ "$ESC_PAREN" -eq 1 ] && [ "$i" -eq "$n" ] && [ "${#starts[@]}" -gt 0 ] && [ "${starts[$((${#starts[@]} - 1))]}" = "/" ]; then
    unset "starts[$((${#starts[@]} - 1))]"
  fi
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      -exec | -execdir | -ok | -okdir) inexec=1 ;;
      rm | */rm | rm.exe | */rm.exe) [ "$inexec" -eq 1 ] && danger=1 ;;
    esac
    i=$((i + 1))
  done
  [ "$danger" -eq 1 ] || return 0
  [ "${#starts[@]}" -gt 0 ] || starts=(".")
  for tok in ${starts[@]+"${starts[@]}"}; do
    if find_start_unsafe "$tok"; then
      kit_deny_pretool "kit: find que apaga a partir de '$tok' bloqueado (fora do projeto ou alvo nao resolvivel)."
    fi
  done
  return 0
}

# DROP/TRUNCATE num trecho. git e os buscadores de texto so carregam o texto como argumento.
check_sql() {
  [ "$SQL_DROP" -eq 1 ] || [ "$SQL_TRUNC" -eq 1 ] || return 0
  case "${1##*/}" in
    git | git.exe | grep | egrep | fgrep | rg | ag | ack) return 0 ;;
  esac
  local seg="$*"
  if [ "$SQL_DROP" -eq 1 ] && printf '%s' "$seg" | grep -Eiq -- "$DROP_RE"; then
    kit_deny_pretool "kit: DROP DATABASE/TABLE bloqueado. Rode manualmente se for intencional."
  fi
  if [ "$SQL_TRUNC" -eq 1 ] && printf '%s' "$seg" | grep -Eiq -- "$TRUNC_RE"; then
    kit_deny_pretool "kit: TRUNCATE bloqueado. Rode manualmente se for intencional."
  fi
  return 0
}

# Um comando simples (ja separado de ;, &&, |...). sh -c/bash -c analisa o resto como comando.
check_segment() {
  [ "$#" -gt 0 ] || return 0
  check_chmod "$@"
  skip_prefix "$@"
  local -a w=("$@")
  if [ "$CMD_I" -ge "$#" ]; then check_sql "" "$@"; return 0; fi
  local -a c=("${w[@]:$CMD_I}")
  local j=1 found=0
  check_sql "${c[@]}"
  case "${c[0]}" in
    cd | pushd | popd) do_cd "${c[@]}" ;;
    rm | */rm | rm.exe | */rm.exe) check_rm "${c[@]}" ;;
    find | */find | find.exe | */find.exe) check_find "${c[@]}" ;;
    *'$'*) check_rm "${c[@]}" ;;
    git | */git | git.exe | */git.exe) check_git "${c[@]}" ;;
    sh | bash | zsh | dash | ksh | */sh | */bash | */zsh | */dash | */ksh)
      while [ "$j" -lt "${#c[@]}" ]; do
        case "${c[$j]}" in
          -*c*) found=1; j=$((j + 1)); break ;;
          -*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      [ "$found" -eq 1 ] && [ "$j" -lt "${#c[@]}" ] && check_segment "${c[@]:$j}" ;;
  esac
  return 0
}

# Analisa um texto ja sem aspas, trecho a trecho, na ordem: cd muda a pasta dos trechos seguintes.
analyze() {
  local segs seg
  local -a words
  CUR="$START_DIR"
  CUR_OK=1
  segs="$(printf '%s' "$1" | sed -E 's/(\|\||&&|\$\(|[;|&`(){}])/\n/g')"
  while IFS= read -r seg; do
    case "$seg" in *[![:space:]]*) ;; *) continue ;; esac
    words=()
    read -r -a words <<<"$seg"
    [ "${#words[@]}" -gt 0 ] || continue
    check_segment "${words[@]}" # array nao vazio
  done <<<"$segs"
}

# Duas leituras: os comandos de dentro de $() e crases como trechos proprios, e o comando externo
# com cada substituicao trocada por $KITSUB (alvo nao resolvivel).
analyze "$FLAT"
OUTER="$FLAT"
prev=""
n=0
while [ "$prev" != "$OUTER" ] && [ "$n" -lt 20 ]; do
  prev="$OUTER"
  OUTER="$(printf '%s' "$OUTER" | sed -E 's/[$<>]\([^()]*\)/$KITSUB/g')"
  n=$((n + 1))
done
OUTER="$(printf '%s' "$OUTER" | sed -E 's/`[^`]*`/$KITSUB/g; s/[$<>]\(/ $KITSUB /g; s/`/ $KITSUB /g')"
[ "$OUTER" != "$FLAT" ] && analyze "$OUTER"

exit 0
