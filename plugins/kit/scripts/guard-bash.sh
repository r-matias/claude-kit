#!/usr/bin/env bash
# PreToolUse/Bash: nega comandos destrutivos, inclusive dentro de sh -c, bash -c, cmd /c,
# powershell -Command, $() e crases.
# Compativel com bash 3.2. Qualquer erro inesperado bloqueia (exit 2).
set -u
KIT_HERE="${BASH_SOURCE[0]%/*}"
[ "$KIT_HERE" != "${BASH_SOURCE[0]}" ] || KIT_HERE="."
. "$KIT_HERE/lib.sh"
kit_guard_fail_closed
kit_require_jq_strict --allow-jq-install
kit_read_input

# Entrada lida num jq so: o guarda roda a cada comando, com limite de tempo.
CMD=""
CWD=""
MODE=""
if ! kit_fields CMD '.tool_input.command' CWD '.cwd' MODE '.permission_mode'; then
  echo "kit: entrada do hook vazia ou ilegível; chamada bloqueada" >&2
  exit 2
fi
[ -n "$CMD" ] || exit 0

# Roda a cada chamada de Bash e, no Git Bash, cada processo custa dezenas de milissegundos: daqui
# ate o caminho rapido, so bash puro.
BS='\'
NL=$'\n'

# Continuacao de linha vira espaco; escapes de aspas, $, crase e espaco perdem a barra; o resto
# das barras invertidas vira / (caminho Windows). Depois as aspas saem: o conteudo de sh -c "..."
# passa a ser analisado como texto comum.
SL='/'
DQ='"'
SQ="'"
TAB=$'\t'
CR=$'\r'
FLAT_OUT=""
flatten() {
  local f c
  f=${1//"$BS$NL"/ }
  for c in "$DQ" "$SQ" '$' '`' ' '; do
    f=${f//"$BS$c"/$c}
  done
  while [[ "$f" == *"$BS$BS"* ]]; do f=${f//"$BS$BS"/$BS}; done
  f=${f//"$BS"/$SL}
  f=${f//"$DQ"/}
  f=${f//"$SQ"/}
  f=${f//"$TAB"/ }
  f=${f//"$CR"/ }
  # As chaves separariam o trecho: ${HOME} vira $HOME.
  f=${f//'${HOME}'/'$HOME'}
  while [ "${f%"$NL"}" != "$f" ]; do f="${f%"$NL"}"; done
  FLAT_OUT="$f"
}
flatten "$CMD"
FLAT="$FLAT_OUT"

# Minusculas em bash puro (o 3.2 nao tem ${x,,}), em LC_OUT. So ASCII: os padroes sao ASCII.
LC_OUT=""
to_lower() {
  local i
  LC_OUT="$1"
  case "$1" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) ;; *) return 0 ;; esac
  for ((i = 0; i < 26; i++)); do
    LC_OUT="${LC_OUT//${KIT_ASCII_UPPER:$i:1}/${KIT_ASCII_LOWER:$i:1}}"
  done
}
to_lower "$FLAT"
FLAT_LC="$LC_OUT"

# Caminho rapido: tudo o que o guarda nega ou confirma depende de uma destas palavras no texto.
# Regra nova acrescenta a sua aqui. Os redirecionamentos que nao escrevem em arquivo (2>&1,
# >/dev/null) nao contam como ">".
FAST="$FLAT_LC "
case "$FAST" in
  *'>'*)
    for c in '>&1 ' '>&2 ' '>/dev/null ' '> /dev/null '; do FAST=${FAST//"$c"/ }; done ;;
esac
case "$FAST" in
  *rm* | *find* | *git* | *sh* | *curl* | *wget* | *mkfs* | *dd* | *drop* | *truncate* | *chmod* | \
    *xargs* | *'$'* | *'`'* | *eval* | *source* | \
    *cmd* | *powershell* | *pwsh* | *py* | *node* | *deno* | *bun* | *ruby* | *php* | \
    *'>'* | *tee* | *sed* | *perl* | *cp* | *mv* | *install* | *ln* | \
    *.env* | *.pem* | *.key* | *secrets* | *.ssh* | *.aws* | *.kube* | *.git-credentials* | *.npmrc* | \
    *.config/gh* | *.docker/config.json*) ;;
  *) exit 0 ;;
esac

# Leitura de segredo pelo shell so e conferida quando o texto cita um dos nomes do grupo segredos.
SECRET_HINT=0
case "$FLAT_LC" in
  *.env* | *.pem* | *.key* | *secrets* | *.ssh* | *.aws* | *.kube* | *.git-credentials* | *.npmrc* | \
    *.config/gh* | *.docker/config.json*) SECRET_HINT=1 ;;
esac

# Regex estendida linha a linha, como o grep -Ei: o texto vai para minusculas, entao o padrao tem
# de ser escrito todo em minusculas. Uso: has_in <texto> <re>
has_in() {
  local rest l
  to_lower "$1"
  rest="$LC_OUT"
  case "$rest" in
    *"$NL"*) ;;
    *) [[ $rest =~ $2 ]]; return ;;
  esac
  while :; do
    l="${rest%%"$NL"*}"
    [[ $l =~ $2 ]] && return 0
    [ "$l" != "$rest" ] || return 1
    rest="${rest#*"$NL"}"
  done
}
has() { has_in "$FLAT_LC" "$1"; }

[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
CWD="${CWD//\\//}"
# No shell principal: os subshells herdam o sistema ja lido.
kit_case_insensitive || true
PROJECT="$CWD"
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && PROJECT="$(kit_norm_path "$CLAUDE_PROJECT_DIR")"
PROJECT_REAL="$(kit_path_norm "$PROJECT" /)"
START_DIR="$(kit_path_norm "$CWD" "$PROJECT_REAL")"
PROJECT_CMP="$(kit_fold "$PROJECT_REAL")"
PLATFORM="$(kit_platform)"
KIT_CEILING="$CWD"

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
# PowerShell: iwr/irm/DownloadString com iex ou Invoke-Expression (no PowerShell 5, curl e wget sao iwr).
NET_PS='(iwr|irm|invoke-webrequest|invoke-restmethod|downloadstring|curl|wget)'
IEX_PS='(iex|invoke-expression)'
if has "(^|[^a-z0-9_-])${NET_PS}[^;&]*\|[[:space:]]*${IEX_PS}([^a-z0-9_-]|$)" ||
  has "(^|[^a-z0-9_-])${IEX_PS}([^a-z0-9_-][^;|]*)?[^a-z0-9_-]${NET_PS}([^a-z0-9_-]|$)"; then
  kit_deny_pretool "kit: execucao de script baixado da rede (iwr | iex) bloqueada."
fi
if has '(^|[^a-z0-9_./-])mkfs(\.[a-z0-9]+)?([[:space:]]|$)'; then
  kit_deny_pretool "kit: mkfs bloqueado."
fi
if has '(^|[^a-z0-9_-])dd[[:space:]].*of=/dev/' &&
  ! has 'of=/dev/(null|zero|stdout|stderr)([[:space:]]|$)'; then
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
  # %VAR% do cmd e drive de provedor do PowerShell (HKCU:, Env:) tambem nao se resolvem.
  case "$t" in
    '~'* | *'$'* | *'`'* | *%*%*) return 0 ;;
  esac
  [[ ${t%%/*} =~ ^[A-Za-z][A-Za-z0-9_]+: ]] && return 0
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

# Confirmacao adiada: o pedido sai depois da analise inteira, para que um trecho negado no mesmo
# comando ganhe. Vale o primeiro. Uso: ask_later <motivo do ask> <motivo da negacao em bypassPermissions>
ASK_MSG=""
ASK_BYPASS=""
ask_later() {
  [ -z "$ASK_MSG" ] || return 0
  ASK_MSG="$1"
  ASK_BYPASS="$2"
}

# Descarta alteracoes nao commitadas do working tree, sem volta. Desfazer a propria edicao e legitimo,
# entao o usuario confirma em vez de o guarda negar.
git_discard() {
  ask_later "kit: $1 descarta alteracoes nao commitadas sem volta, inclusive as que voce nao fez nesta sessao. Confirme so se nada ali precisa ser mantido; senao, use git stash." \
    "kit: $1 bloqueado em bypassPermissions (descarta alteracoes nao commitadas sem volta e nao ha como confirmar). Use git stash ou rode manualmente."
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
      case "$flags" in *n*) return 0 ;; esac
      kit_deny_pretool "kit: git clean -f bloqueado (apaga arquivos nao rastreados sem volta). Rode git clean -n para ver o que seria apagado." ;;
    checkout)
      local dd=0
      for tok in ${rest[@]+"${rest[@]}"}; do
        if [ "$dd" -eq 1 ]; then
          git_discard "git checkout -- <caminho>"
          break
        fi
        case "$tok" in
          --) dd=1 ;;
          --pathspec-from-file*) git_discard "git checkout --pathspec-from-file" ;;
          --force) git_discard "git checkout --force" ;;
          --*) ;;
          -*f*) git_discard "git checkout -f" ;;
          . | ./ | :/ | '*') git_discard "git checkout $tok" ;;
        esac
      done ;;
    restore)
      local staged=0 wt=0
      for tok in ${rest[@]+"${rest[@]}"}; do
        case "$tok" in
          --staged) staged=1 ;;
          --worktree) wt=1 ;;
          --) break ;;
          --*) ;;
          -*)
            case "$tok" in *S*) staged=1 ;; esac
            case "$tok" in *W*) wt=1 ;; esac ;;
        esac
      done
      [ "$staged" -eq 1 ] && [ "$wt" -eq 0 ] && return 0
      git_discard "git restore" ;;
    switch)
      for tok in ${rest[@]+"${rest[@]}"}; do
        case "$tok" in
          --force | --discard-changes) git_discard "git switch $tok" ;;
          --*) ;;
          -*f*) git_discard "git switch -f" ;;
        esac
      done ;;
    stash)
      case "${rest[0]:-}" in
        drop | clear) kit_deny_pretool "kit: git stash ${rest[0]} bloqueado (apaga stash sem volta). Rode manualmente se for intencional." ;;
      esac ;;
    branch)
      local del=0 force=0 skip=0
      for tok in ${rest[@]+"${rest[@]}"}; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$tok" in
          --sort | --format | --contains | --no-contains | --merged | --no-merged | --points-at) skip=1 ;;
          --delete) del=1 ;;
          --force) force=1 ;;
          --*) ;;
          -*D*) del=1; force=1 ;;
          -*)
            case "$tok" in *d*) del=1 ;; esac
            case "$tok" in *f*) force=1 ;; esac ;;
        esac
      done
      if [ "$del" -eq 1 ] && [ "$force" -eq 1 ]; then
        kit_deny_pretool "kit: git branch -D bloqueado (apaga branch nao mesclada). Use git branch -d ou rode manualmente."
      fi ;;
    reflog)
      case "${rest[0]:-}" in
        expire | delete) kit_deny_pretool "kit: git reflog ${rest[0]} bloqueado (apaga o historico de recuperacao). Rode manualmente se for intencional." ;;
      esac ;;
    gc)
      for tok in ${rest[@]+"${rest[@]}"}; do
        case "$tok" in
          --prune=now | --prune=all) kit_deny_pretool "kit: git gc $tok bloqueado (apaga objetos sem referencia, inclusive os recuperaveis pelo reflog). Rode manualmente se for intencional." ;;
        esac
      done ;;
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
  if [ "$SQL_DROP" -eq 1 ] && has_in "$seg" "$DROP_RE"; then
    kit_deny_pretool "kit: DROP DATABASE/TABLE bloqueado. Rode manualmente se for intencional."
  fi
  if [ "$SQL_TRUNC" -eq 1 ] && has_in "$seg" "$TRUNC_RE"; then
    kit_deny_pretool "kit: TRUNCATE bloqueado. Rode manualmente se for intencional."
  fi
  return 0
}

# Escrita pelo shell: alvos de redirecionamento, tee, sed -i, perl -i, cp, mv, install, ln, dd of=
# e truncate passam pelas regras do guard-files (kit_check_write no lib.sh). O kit.json so e lido
# quando aparece um alvo, e cada caminho e conferido uma vez.
WRITE_SEEN="$NL"
RW_PATH=""

# Caminho absoluto do alvo em RW_PATH. 1 se nao der para resolver (variavel, ~, glob, C:x, alvo
# relativo depois de cd nao resolvivel).
resolve_write() {
  local t="$1"
  case "$t" in
    '~'* | *'$'* | *'`'* | *[*?[]* | [A-Za-z]: | [A-Za-z]:[!/]*) return 1 ;;
    /*) [ "$PLATFORM" = "windows" ] && t="$(msys_drive "$t")" ;;
    [A-Za-z]:/*) ;;
    *) [ "$CUR_OK" -eq 1 ] || return 1 ;;
  esac
  if [ "$PLATFORM" = "windows" ]; then
    case "${t#[A-Za-z]:}" in *:* | *[.\ ]/* | *[.\ ]) t="$(kit_win_clean "$t")" ;; esac
  fi
  kit_path_norm_to "$t" "$CUR"
  RW_PATH="$KIT_NORMED"
}

write_target() {
  local t="$1"
  case "$t" in
    '' | -) return 0 ;;
    //*) ;;
    /*) kit_path_norm_to "$t" /; t="$KIT_NORMED" ;;
    *[!0-9]*) ;;
    *) return 0 ;;
  esac
  case "$t" in /dev | /dev/*) return 0 ;; esac
  if ! resolve_write "$t"; then
    kit_check_write_name "$t"
    return 0
  fi
  case "$WRITE_SEEN" in *"$NL$RW_PATH$NL"*) return 0 ;; esac
  WRITE_SEEN+="$RW_PATH$NL"
  KIT_NEW_FILE=0
  [ -e "$RW_PATH" ] || KIT_NEW_FILE=1
  kit_check_write_path "$RW_PATH"
}

# Redirecionamentos de saida (>, >>, N>, >arq colado; o analyze ja trocou >|, >& e &> por >). Com
# $1 = 1 confere cada alvo; sempre deixa em ARGS_NR os argumentos sem os redirecionamentos. Alvo so
# com digitos e o que sobra de 2>&1 e >&2.
ARGS_NR=()
scan_redirects() {
  local check="$1" tok rest
  shift
  ARGS_NR=()
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    case "$tok" in
      *'>'*) ;;
      *) ARGS_NR+=("$tok"); continue ;;
    esac
    rest="${tok#*>}"
    rest="${rest#>}"
    if [ -z "$rest" ] && [ "$#" -gt 0 ]; then
      rest="$1"
      shift
    fi
    [ "$check" -eq 1 ] && write_target "$rest"
  done
  return 0
}

# Destino de cp, mv, install e ln: o -t ou o ultimo argumento; destino que e pasta recebe o nome de
# cada origem. No mv as origens tambem contam (somem do lugar). install -d: todos sao pastas criadas.
check_copy() {
  local name="$1" tok tdir="" opts_done=0 k ch v argc="tS" mkdirs=0 n dest src todir=0
  local -a pos=()
  shift
  [ "$name" = "install" ] && argc="tSmog"
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    if [ "$opts_done" -eq 0 ]; then
      case "$tok" in
        --) opts_done=1; continue ;;
        --target-directory=*) tdir="${tok#*=}"; continue ;;
        --target-directory) tdir="${1:-}"; [ "$#" -gt 0 ] && shift; continue ;;
        --directory) mkdirs=1; continue ;;
        --suffix | --mode | --owner | --group) [ "$#" -gt 0 ] && shift; continue ;;
        --*) continue ;;
        -?*)
          k=1
          while [ "$k" -lt "${#tok}" ]; do
            ch="${tok:$k:1}"
            case "$argc" in
              *"$ch"*)
                v="${tok:$((k + 1))}"
                if [ -z "$v" ] && [ "$#" -gt 0 ]; then v="$1"; shift; fi
                [ "$ch" = "t" ] && tdir="$v"
                break ;;
            esac
            [ "$ch" = "d" ] && [ "$name" = "install" ] && mkdirs=1
            k=$((k + 1))
          done
          continue ;;
      esac
    fi
    pos+=("$tok")
  done
  n=${#pos[@]}
  [ "$n" -gt 0 ] || return 0
  if [ "$mkdirs" -eq 1 ]; then
    for tok in ${pos[@]+"${pos[@]}"}; do write_target "$tok"; done
    return 0
  fi
  if [ -n "$tdir" ]; then
    dest="$tdir"
    todir=1
  elif [ "$n" -eq 1 ]; then
    # ln -s alvo: o link nasce na pasta corrente com o nome do alvo.
    [ "$name" = "ln" ] || return 0
    dest="."
    todir=1
  else
    dest="${pos[$((n - 1))]}"
    unset "pos[$((n - 1))]"
    case "$dest" in */) todir=1 ;; esac
    [ "$n" -gt 2 ] && todir=1
    if [ "$todir" -eq 0 ] && resolve_write "$dest" && [ -d "$RW_PATH" ]; then todir=1; fi
  fi
  for src in ${pos[@]+"${pos[@]}"}; do
    [ "$name" = "mv" ] && write_target "$src"
    if [ "$todir" -eq 1 ]; then
      src="${src%/}"
      write_target "${dest%/}/${src##*/}"
    fi
  done
  [ "$todir" -eq 0 ] && write_target "$dest"
  return 0
}

# sed -i / --in-place: os arquivos depois do script (o script e o primeiro argumento, salvo com -e ou -f).
check_sed() {
  local tok inplace=0 script=0 opts_done=0 k ch
  local -a pos=()
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    if [ "$opts_done" -eq 0 ]; then
      case "$tok" in
        --) opts_done=1; continue ;;
        --in-place | --in-place=*) inplace=1; continue ;;
        --expression=* | --file=*) script=1; continue ;;
        --expression | --file) script=1; [ "$#" -gt 0 ] && shift; continue ;;
        --line-length) [ "$#" -gt 0 ] && shift; continue ;;
        --*) continue ;;
        -?*)
          k=1
          while [ "$k" -lt "${#tok}" ]; do
            ch="${tok:$k:1}"
            case "$ch" in
              i | I) inplace=1; break ;;
              e | f | l)
                [ "$ch" = "l" ] || script=1
                [ -z "${tok:$((k + 1))}" ] && [ "$#" -gt 0 ] && shift
                break ;;
            esac
            k=$((k + 1))
          done
          continue ;;
      esac
    fi
    pos+=("$tok")
  done
  [ "$inplace" -eq 1 ] || return 0
  [ "$script" -eq 1 ] || pos=(${pos[@]+"${pos[@]:1}"})
  for tok in ${pos[@]+"${pos[@]}"}; do write_target "$tok"; done
  return 0
}

# perl -i: os arquivos depois do programa (-e/-E ou o primeiro argumento). As opcoes acabam no
# primeiro argumento que nao e opcao.
check_perl() {
  local tok inplace=0 script=0 k ch
  local -a pos=()
  while [ "$#" -gt 0 ]; do
    tok="$1"
    case "$tok" in
      --) shift; break ;;
      -?*) shift ;;
      *) break ;;
    esac
    k=1
    while [ "$k" -lt "${#tok}" ]; do
      ch="${tok:$k:1}"
      case "$ch" in
        i) inplace=1; break ;;
        e | E)
          script=1
          [ -z "${tok:$((k + 1))}" ] && [ "$#" -gt 0 ] && shift
          break ;;
        I | M | m | x | d | D | C | 0 | l | F | V) break ;;
      esac
      k=$((k + 1))
    done
  done
  [ "$inplace" -eq 1 ] || return 0
  pos=("$@")
  [ "$script" -eq 1 ] || pos=(${pos[@]+"${pos[@]:1}"})
  for tok in ${pos[@]+"${pos[@]}"}; do write_target "$tok"; done
  return 0
}

# truncate: todos os arquivos; -s e -r levam valor.
check_truncate() {
  local tok opts_done=0
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    if [ "$opts_done" -eq 0 ]; then
      case "$tok" in
        --) opts_done=1; continue ;;
        -s | -r | --size | --reference) [ "$#" -gt 0 ] && shift; continue ;;
        -?*) continue ;;
      esac
    fi
    write_target "$tok"
  done
  return 0
}

# Comando que escreve nos arquivos dos argumentos. Recebe o comando ja sem prefixos.
check_write_cmd() {
  local name="${1##*/}" tok
  name="${name%.exe}"
  case "$name" in
    tee | sed | gsed | perl | cp | mv | install | ln | dd | truncate) ;;
    *) return 0 ;;
  esac
  scan_redirects 0 "$@"
  set -- ${ARGS_NR[@]+"${ARGS_NR[@]}"}
  shift
  case "$name" in
    tee)
      for tok in "$@"; do
        case "$tok" in -*) ;; *) write_target "$tok" ;; esac
      done ;;
    sed | gsed) check_sed "$@" ;;
    perl) check_perl "$@" ;;
    cp | mv | install | ln) check_copy "$name" "$@" ;;
    dd)
      for tok in "$@"; do
        case "$tok" in of=*) write_target "${tok#of=}" ;; esac
      done ;;
    truncate) check_truncate "$@" ;;
  esac
  return 0
}

# Leitura de segredo pelo shell: so com o grupo segredos em permissions.groups do kit.json. Mesmos
# nomes do Read negado pelo grupo; nome de exemplo (.example, .sample...) e liberado.
# READ_GROUP: "" nao lido, 0 desligado, 1 ligado. kit.json ilegivel conta como ligado.
READ_GROUP=""
READ_BAD=""
READ_WHY=""
read_group_on() {
  local root r
  if [ -z "$READ_GROUP" ]; then
    READ_GROUP=0
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      r="$(jq -r 'if type == "object" and ((.permissions // {}) | type == "object") then
          ((.permissions.groups // []) | if type == "array" then any(.[]; . == "segredos") else "x" end)
        else "x" end' "$root/.claude/kit.json" 2>/dev/null)"
      r="${r//$CR/}"
      case "$r" in
        true) READ_GROUP=1; break ;;
        false) ;;
        x) READ_GROUP=1; READ_BAD="$root/.claude/kit.json"; READ_WHY="tem permissions ou permissions.groups com tipo errado (groups precisa ser lista)"; break ;;
        *) READ_GROUP=1; READ_BAD="$root/.claude/kit.json"; READ_WHY="nao e JSON valido (jq . mostra o erro)"; break ;;
      esac
    done < <(kit_kit_roots "$START_DIR")
  fi
  [ "$READ_GROUP" = "1" ]
}

read_deny() {
  read_group_on || return 0
  if [ -n "$READ_BAD" ]; then
    kit_deny_pretool "kit: $READ_BAD $READ_WHY; o grupo segredos nao pode ser conferido e a leitura de '$1' pelo shell foi bloqueada. Corrija o kit.json."
  fi
  kit_deny_pretool "kit: leitura de segredo ('$1') pelo shell bloqueada (grupo segredos). Quem usa o valor e o script do projeto, que carrega o arquivo (node --env-file, docker compose --env-file); o Claude nao le o conteudo."
}

# 0 se o caminho (relativo ao projeto ou como foi escrito) tem nome de segredo do grupo.
secret_name() {
  local p base
  kit_fold_to "$1"
  p="${KIT_FOLDED%/}"
  case "/$p/" in */secrets/*) return 0 ;; esac
  base="${p##*/}"
  kit_is_example_name "$base" && return 1
  case "$base" in
    .env | .env.local | .env.*.local | .env.test | .env.production | .env.development | .env.staging | \
      *.pem | *.key) return 0 ;;
  esac
  return 1
}

# Credenciais na home. Com $2 = 1, o caminho nao foi resolvido: casa o trecho em qualquer pasta.
HOME_CMP=""
home_secret() {
  local p h
  kit_fold_to "$1"
  p="$KIT_FOLDED"
  if [ "$2" -eq 1 ]; then
    case "/$p" in
      */.ssh | */.ssh/* | */.aws | */.aws/* | */.kube | */.kube/* | */.config/gh | */.config/gh/* | \
        */.git-credentials | */.docker/config.json) return 0 ;;
    esac
    return 1
  fi
  if [ -z "$HOME_CMP" ]; then
    h="${HOME:-}"
    h="${h//\\//}"
    [ -n "$h" ] || return 1
    kit_path_norm_to "$(msys_drive "$h")" /
    kit_fold_to "${KIT_NORMED%/}"
    HOME_CMP="$KIT_FOLDED"
  fi
  case "$p" in
    "$HOME_CMP"/.ssh | "$HOME_CMP"/.ssh/* | "$HOME_CMP"/.aws | "$HOME_CMP"/.aws/* | \
      "$HOME_CMP"/.kube | "$HOME_CMP"/.kube/* | "$HOME_CMP"/.config/gh | "$HOME_CMP"/.config/gh/* | \
      "$HOME_CMP"/.git-credentials | "$HOME_CMP"/.npmrc | "$HOME_CMP"/.docker/config.json) return 0 ;;
  esac
  return 1
}

# Caminho absoluto: nome (relativo ao projeto, se estiver dentro) e credencial da home.
secret_abs() {
  local p="$1" rel
  kit_fold_to "$p"
  rel="$KIT_FOLDED"
  case "$rel" in "$PROJECT_CMP"/?*) rel="${rel#"$PROJECT_CMP"/}" ;; esac
  secret_name "$rel" && return 0
  home_secret "$p" 0
}

# Um arquivo lido: resolvido, confere o caminho e, se existir, o alvo real (symlink); sem resolver,
# so pelo nome. $2: o texto como foi escrito, para a mensagem.
read_one() {
  local t="$1" shown="$2"
  if resolve_write "$t"; then
    secret_abs "$RW_PATH" && read_deny "$shown"
    if [ -e "$RW_PATH" ] || [ -L "$RW_PATH" ]; then
      kit_real_path_to "$RW_PATH"
      [ "$KIT_REAL" != "$RW_PATH" ] && secret_abs "$KIT_REAL" && read_deny "$shown"
    fi
  else
    secret_name "$t" && read_deny "$shown"
    home_secret "$t" 1 && read_deny "$shown"
  fi
  return 0
}

# Argumento lido. ~ e $HOME viram a home; glob com pasta resolvivel e expandido ali (sem arquivos
# ocultos, como o bash), senao vale o nome.
GLOB_M=()
glob_expand() {
  local IFS=''
  GLOB_M=("$1"$2)
}

read_target() {
  local t="$1" pre="" was=0 m
  case "$t" in '' | -) return 0 ;; esac
  if [ -n "${HOME:-}" ]; then
    case "$t" in
      '~' | '$HOME') t="${HOME//\\//}" ;;
      '~/'* | '$HOME/'*) t="${HOME//\\//}/${t#*/}" ;;
    esac
  fi
  case "$t" in
    *'$'* | *'`'* | '~'*) read_one "$t" "$1"; return 0 ;;
    *[*?[]*)
      case "$t" in
        /* | [A-Za-z]:/*) ;;
        [A-Za-z]:*) read_one "$t" "$1"; return 0 ;;
        *)
          [ "$CUR_OK" -eq 1 ] || { read_one "$t" "$1"; return 0; }
          pre="$CUR/" ;;
      esac
      shopt -q nullglob && was=1
      shopt -s nullglob
      glob_expand "$pre" "$t"
      [ "$was" -eq 1 ] || shopt -u nullglob
      for m in ${GLOB_M[@]+"${GLOB_M[@]}"}; do read_one "$m" "$1"; done
      return 0 ;;
  esac
  read_one "$t" "$1"
}

# Entrada por redirecionamento (<, N<, <>, <arq colado). Heredoc e here-string (<<, <<<) e
# duplicacao (<&) nao leem arquivo.
scan_read_redirects() {
  local tok rest
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    case "$tok" in
      *'<<'*)
        rest="${tok##*<}"
        [ -z "$rest" ] && [ "$#" -gt 0 ] && shift
        continue ;;
      *'<'*) ;;
      *) continue ;;
    esac
    rest="${tok##*<}"
    rest="${rest#>}"
    if [ -z "$rest" ] && [ "$#" -gt 0 ]; then
      rest="$1"
      shift
    fi
    case "$rest" in '&'*) continue ;; esac
    read_target "$rest"
  done
  return 0
}

# Opcoes de um comando que le: RD_VALOPT (letras curtas com valor), RD_LONGVAL (longas com valor,
# "|--a|--b|"), RD_SCRIPTOPT e RD_LONGSCRIPT (as que trazem o programa ou o padrao; marcam
# RD_SCRIPT=1), RD_BREAKOPT (letra que encerra o grupo, como o -i.bak do sed). Posicionais em RD_POS.
RD_VALOPT=""
RD_LONGVAL=""
RD_SCRIPTOPT=""
RD_LONGSCRIPT=""
RD_BREAKOPT=""
RD_FILEOPT=""
RD_SCRIPT=0
RD_POS=()
RD_FV=()
parse_read_args() {
  local tok k ch v opts_done=0
  RD_SCRIPT=0
  RD_POS=()
  RD_FV=()
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    if [ "$opts_done" -eq 0 ]; then
      case "$tok" in
        --) opts_done=1; continue ;;
        --*=*)
          case "$RD_LONGSCRIPT" in *"|${tok%%=*}|"*) RD_SCRIPT=1 ;; esac
          [ -n "$RD_FILEOPT" ] && [ "${tok%%=*}" = "--file" ] && RD_FV+=("${tok#*=}")
          continue ;;
        --*)
          case "$RD_LONGSCRIPT" in *"|$tok|"*) RD_SCRIPT=1 ;; esac
          case "$RD_LONGVAL" in
            *"|$tok|"*)
              [ -n "$RD_FILEOPT" ] && [ "$tok" = "--file" ] && [ "$#" -gt 0 ] && RD_FV+=("$1")
              [ "$#" -gt 0 ] && shift ;;
          esac
          continue ;;
        -?*)
          k=1
          while [ "$k" -lt "${#tok}" ]; do
            ch="${tok:$k:1}"
            case "|$RD_BREAKOPT|" in *"$ch"*) break ;; esac
            case "|$RD_SCRIPTOPT|" in *"$ch"*) RD_SCRIPT=1 ;; esac
            case "|$RD_VALOPT|" in
              *"$ch"*)
                v="${tok:$((k + 1))}"
                if [ -z "$v" ] && [ "$#" -gt 0 ]; then v="$1"; shift; fi
                # -f traz o programa ou os padroes de um arquivo: o arquivo e lido.
                case "|$RD_FILEOPT|" in *"$ch"*) RD_FV+=("$v") ;; esac
                break ;;
            esac
            k=$((k + 1))
          done
          continue ;;
      esac
    fi
    RD_POS+=("$tok")
  done
  return 0
}

# Comando que le os arquivos dos argumentos. Recebe o comando ja sem prefixos.
check_read() {
  [ "$READ_GROUP" != "0" ] || return 0
  local name="${1##*/}" tok n first=1 up=0
  name="${name%.exe}"
  RD_VALOPT=""
  RD_LONGVAL=""
  RD_SCRIPTOPT=""
  RD_LONGSCRIPT=""
  RD_BREAKOPT=""
  RD_FILEOPT=""
  case "$name" in
    cat | tac | head | tail | less | more | bat | batcat | nl | od | xxd | hexdump | strings | base64 | \
      cut | sort | source | . | grep | egrep | fgrep | rg | ag | sed | gsed | awk | gawk | mawk | nawk | \
      cp | scp | curl) ;;
    *) return 0 ;;
  esac
  scan_redirects 0 "$@"
  set -- ${ARGS_NR[@]+"${ARGS_NR[@]}"}
  shift
  if [ "$name" = "curl" ]; then
    for tok in "$@"; do
      if [ "$up" -eq 1 ]; then up=0; read_target "$tok"; continue; fi
      case "$tok" in
        -T | --upload-file) up=1 ;;
        -T?*) read_target "${tok#-T}" ;;
        --upload-file=*) read_target "${tok#*=}" ;;
        *@*) tok="${tok#*@}"; read_target "${tok#<}" ;;
      esac
    done
    return 0
  fi
  case "$name" in
    grep | egrep | fgrep)
      RD_VALOPT="ABCmefdD"
      RD_LONGVAL="|--regexp|--file|--after-context|--before-context|--context|--max-count|--directories|--devices|--include|--exclude|--exclude-dir|--exclude-from|--label|"
      RD_SCRIPTOPT="ef"
      RD_LONGSCRIPT="|--regexp|--file|"
      RD_FILEOPT="f" ;;
    rg)
      RD_VALOPT="ABCmefgtTjMEr"
      RD_LONGVAL="|--regexp|--file|--after-context|--before-context|--context|--max-count|--glob|--iglob|--type|--type-not|--threads|--max-columns|--encoding|--replace|--max-depth|--type-add|"
      RD_SCRIPTOPT="ef"
      RD_LONGSCRIPT="|--regexp|--file|"
      RD_FILEOPT="f" ;;
    ag)
      RD_VALOPT="ABCmGgp"
      RD_LONGVAL="|--after|--before|--context|--max-count|--file-search-regex|--depth|--path-to-ignore|--ignore|" ;;
    sed | gsed)
      RD_VALOPT="efl"
      RD_LONGVAL="|--expression|--file|--line-length|"
      RD_SCRIPTOPT="ef"
      RD_LONGSCRIPT="|--expression|--file|"
      RD_BREAKOPT="iI"
      RD_FILEOPT="f" ;;
    awk | gawk | mawk | nawk)
      RD_VALOPT="fvFe"
      RD_LONGVAL="|--file|--assign|--field-separator|--source|"
      RD_SCRIPTOPT="fe"
      RD_LONGSCRIPT="|--file|--source|"
      RD_FILEOPT="f" ;;
    cp)
      RD_VALOPT="tS"
      RD_LONGVAL="|--target-directory|--suffix|"
      RD_SCRIPTOPT="t"
      RD_LONGSCRIPT="|--target-directory|" ;;
    scp) RD_VALOPT="cDFiJloPSX" ;;
  esac
  parse_read_args "$@"
  for tok in ${RD_FV[@]+"${RD_FV[@]}"}; do read_target "$tok"; done
  n=${#RD_POS[@]}
  [ "$n" -gt 0 ] || return 0
  case "$name" in
    # O primeiro posicional e o padrao ou o programa, salvo quando veio por opcao.
    grep | egrep | fgrep | rg | ag | sed | gsed | awk | gawk | mawk | nawk)
      [ "$RD_SCRIPT" -eq 1 ] && first=0 ;;
    # Origens: todos menos o destino (o ultimo), salvo com -t. Um posicional so (cp .env{,.bak},
    # que as chaves partem) conta como origem.
    cp | scp)
      first=0
      if [ "$n" -gt 1 ] && { [ "$name" = "scp" ] || [ "$RD_SCRIPT" -eq 0 ]; }; then unset "RD_POS[$((n - 1))]"; fi ;;
    *) first=0 ;;
  esac
  for tok in ${RD_POS[@]+"${RD_POS[@]}"}; do
    if [ "$first" -eq 1 ]; then first=0; continue; fi
    read_target "$tok"
  done
  return 0
}

# 0 se o texto e um grupo de switches do cmd colados (/s/q, /f/s/q, /a:h/s).
win_switches() {
  local p IFS=/
  local -a parts=()
  read -r -a parts <<<"$1"
  for p in ${parts[@]+"${parts[@]}"}; do
    case "$p" in '' | ? | ?:*) ;; *) return 1 ;; esac
  done
  return 0
}

# Remocao do Windows: rd, rmdir, del e erase do cmd com /s; Remove-Item e os aliases do PowerShell
# com -Recurse (ou prefixo dele). Alvos: posicionais (lista com virgula inclusive), -Path e -LiteralPath.
# Sem alvo (itens vindos do pipeline), nega. O rm tambem passa aqui, pelo -Recurse do PowerShell.
check_win_rm() {
  local tok l nm rec=0 val=0 skip=0 cmdname
  local -a targets=() parts=()
  to_lower "${1##*/}"
  cmdname="${LC_OUT%.exe}"
  shift
  while [ "$#" -gt 0 ]; do
    tok="$1"
    shift
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    if [ "$val" -eq 1 ]; then val=0; targets+=("$tok"); continue; fi
    to_lower "$tok"
    l="$LC_OUT"
    case "$l" in
      /s | //s) rec=1; continue ;;
      /? | //? | /?:* | //?:*) continue ;;
      /*/*)
        if win_switches "$l"; then
          case "$l/" in */s/*) rec=1 ;; esac
          continue
        fi
        targets+=("$tok"); continue ;;
      -?*) ;;
      *) targets+=("$tok"); continue ;;
    esac
    nm="${l%%:*}"
    case "-recurse" in "$nm"*) [ "${#nm}" -ge 2 ] && rec=1; continue ;; esac
    case "$nm" in
      -lp | -pspath) [ "$nm" = "$l" ] && val=1 || targets+=("${tok#*:}"); continue ;;
    esac
    case "-path" in
      "$nm"*) [ "$nm" = "$l" ] && val=1 || targets+=("${tok#*:}"); continue ;;
    esac
    case "-literalpath" in
      "$nm"*) [ "$nm" = "$l" ] && val=1 || targets+=("${tok#*:}"); continue ;;
    esac
    case "$nm" in
      -fi* | -in* | -ex* | -cr* | -st*) [ "$nm" = "$l" ] && skip=1 ;;
    esac
  done
  [ "$rec" -eq 1 ] || return 0
  if [ "${#targets[@]}" -eq 0 ] && [ "$cmdname" != "rm" ]; then
    kit_deny_pretool "kit: remocao recursiva sem alvo explicito ($cmdname) bloqueada (itens vindos do pipeline nao podem ser conferidos). Passe os caminhos explicitamente."
  fi
  for tok in ${targets[@]+"${targets[@]}"}; do
    IFS=, read -r -a parts <<<"$tok"
    for l in ${parts[@]+"${parts[@]}"}; do
      [ -n "$l" ] || continue
      if rm_target_unsafe "$l"; then
        kit_deny_pretool "kit: remocao recursiva em '$l' bloqueada (fora do projeto, raiz, home ou alvo nao resolvivel)."
      fi
    done
  done
  return 0
}

# cmd /c ou /k: o resto e um comando.
check_cmd() {
  local -a w=("$@")
  local i=1 n=$# tok
  while [ "$i" -lt "$n" ]; do
    to_lower "${w[$i]}"
    case "$LC_OUT" in
      /c | //c | /k | //k)
        i=$((i + 1))
        [ "$i" -lt "$n" ] && check_segment "${w[@]:$i}"
        return 0 ;;
      # /c colado ao comando: cmd /c"rd /s x" chega como /crd.
      /c?* | //c?* | /k?* | //k?*)
        tok="${w[$i]#/}"
        tok="${tok#/}"
        tok="${tok:1}"
        i=$((i + 1))
        check_segment "$tok" ${w[@]+"${w[@]:$i}"}
        return 0 ;;
      /*) i=$((i + 1)) ;;
      *) return 0 ;;
    esac
  done
  return 0
}

# powershell/pwsh -Command: o resto e um comando (no powershell.exe, o primeiro posicional tambem).
# -EncodedCommand nega: o conteudo nao pode ser conferido. -File executa script: fora do guarda.
check_ps() {
  local -a w=("$@")
  local i=1 n=$# name kind="$1"
  while [ "$i" -lt "$n" ]; do
    to_lower "${w[$i]}"
    case "$LC_OUT" in
      -* | /*) ;;
      *)
        [ "$kind" = "powershell" ] && check_segment "${w[@]:$i}"
        return 0 ;;
    esac
    name="${LC_OUT#-}"
    name="${name#-}"
    name="${name#/}"
    case "$name" in
      c | cwa | commandwithargs | com | comm | comma | comman | command)
        i=$((i + 1))
        [ "$i" -lt "$n" ] && check_segment "${w[@]:$i}"
        return 0 ;;
      e | ec | en*)
        case "$name" in
          e | ec) name="encodedcommand" ;;
        esac
        case "encodedcommand" in
          "$name"*) kit_deny_pretool "kit: powershell -EncodedCommand bloqueado (conteudo opaco, o guarda nao confere). Passe o comando em texto com -Command." ;;
        esac
        i=$((i + 1)) ;;
      f | fi | fil | file) return 0 ;;
      i | int* | n* | sta | mta | l | lo | log | logi | login) i=$((i + 1)) ;;
      # Pasta de trabalho propria: alvos relativos deixam de ser resolviveis.
      wd | wo*) CUR_OK=0; i=$((i + 2)) ;;
      ex* | ep | w* | i* | o* | v* | ps* | settingsfile | config* | cu*) i=$((i + 2)) ;;
      *) i=$((i + 1)) ;;
    esac
  done
  return 0
}

# Interpretador com codigo na linha de comando. O guarda nao entende o codigo: com API que apaga
# arquivo ou dispara processo em qualquer ponto do texto, pede confirmacao.
INTERP_RE='rmtree|os\.(remove|system|popen|spawn|exec)|(^|[^a-z0-9_])(unlink|rmdir)|rmsync|fs\.rm\(|fs\.promises\.rm|rimraf|subprocess|child_process|execsync|spawnsync|execfilesync|(^|[^a-z0-9_.])system([[:space:]]|\()|fileutils\.rm|file\.delete|dir\.delete|shell_exec|passthru|proc_open|popen|deno\.(remove|run|command)|bun\.spawn'
check_interp() {
  local name="$1" tok inline=0
  shift
  case "$name" in
    python* | py)
      while [ "$#" -gt 0 ]; do
        tok="$1"
        shift
        case "$tok" in
          -W | -X) [ "$#" -gt 0 ] && shift ;;
          -W* | -X* | --*) ;;
          -*c*) inline=1; break ;;
          -*m*) break ;;
          -*) ;;
          *) break ;;
        esac
      done ;;
    # As opcoes acabam no primeiro posicional (o script); o que vem depois e argumento dele.
    node | bun)
      while [ "$#" -gt 0 ]; do
        tok="$1"
        shift
        case "$tok" in
          -e | -p | -pe | -ep | --eval | --print | --eval=* | --print=*) inline=1; break ;;
          -r | --require | --import | --loader | -C | --conditions) [ "$#" -gt 0 ] && shift ;;
          -*) ;;
          *) break ;;
        esac
      done ;;
    deno) [ "${1:-}" = "eval" ] && inline=1 ;;
    perl)
      while [ "$#" -gt 0 ]; do
        tok="$1"
        shift
        case "$tok" in
          --*) ;;
          -[MmIdDxV]*) ;;
          -*[eE]*) inline=1; break ;;
          -*) ;;
          *) break ;;
        esac
      done ;;
    ruby)
      while [ "$#" -gt 0 ]; do
        tok="$1"
        shift
        case "$tok" in
          -r | -I | -C | -E) [ "$#" -gt 0 ] && shift ;;
          --*) ;;
          -[rICEK]*) ;;
          -*e*) inline=1; break ;;
          -*) ;;
          *) break ;;
        esac
      done ;;
    php)
      while [ "$#" -gt 0 ]; do
        tok="$1"
        shift
        case "$tok" in
          -r | -R | -B | -E) inline=1; break ;;
          -*) ;;
          *) break ;;
        esac
      done ;;
  esac
  [ "$inline" -eq 1 ] || return 0
  has "$INTERP_RE" || return 0
  ask_later "kit: $name com codigo inline que apaga arquivo ou dispara outro processo (rmtree, os.remove, unlink, subprocess, child_process, rmSync, system...). O guarda nao confere esse codigo; confirme so depois de ler o que ele faz." \
    "kit: $name com codigo inline que apaga arquivo ou dispara outro processo bloqueado em bypassPermissions (nao ha como confirmar). Rode manualmente se for intencional."
}

# Comandos do cmd e do PowerShell, interpretadores com codigo inline. Recebe o comando ja sem prefixos.
check_other() {
  local name
  to_lower "${1##*/}"
  name="${LC_OUT%.exe}"
  case "$name" in
    cmd) check_cmd "$@" ;;
    powershell | pwsh) shift; check_ps "$name" "$@" ;;
    rd | rmdir | del | erase | remove-item | ri) check_win_rm "$@" ;;
    # cmd e PowerShell nao distinguem maiusculas: Rm, Git e Cd chegam aqui.
    rm) check_rm "$@"; check_win_rm "$@" ;;
    git) check_git "$@" ;;
    cd | pushd | popd) do_cd "$name" "${@:2}" ;;
    set-location | sl | chdir | push-location | pop-location) CUR_OK=0 ;;
    format | format.com)
      shift
      for name in "$@"; do
        case "$name" in [A-Za-z]: | [A-Za-z]:/*) kit_deny_pretool "kit: format de unidade bloqueado." ;; esac
      done ;;
    format-volume | clear-disk | remove-partition | initialize-disk)
      kit_deny_pretool "kit: ${1##*/} bloqueado (apaga disco ou particao). Rode manualmente se for intencional." ;;
    python | python[0-9]* | py | node | bun | deno | perl | ruby | php) shift; check_interp "$name" "$@" ;;
  esac
  return 0
}

# Um comando simples (ja separado de ;, &&, |...). sh -c/bash -c analisa o resto como comando.
# WRITE_ONLY=1: a leitura extra com o texto entre aspas mascarado, so de escrita e de leitura de segredo.
WRITE_ONLY=0
check_segment() {
  [ "$#" -gt 0 ] || return 0
  scan_redirects 1 "$@"
  if [ "$SECRET_HINT" -eq 1 ]; then scan_read_redirects "$@"; fi
  [ "$WRITE_ONLY" -eq 1 ] || check_chmod "$@"
  skip_prefix "$@"
  local -a w=("$@")
  if [ "$CMD_I" -ge "$#" ]; then
    [ "$WRITE_ONLY" -eq 1 ] || check_sql "" "$@"
    return 0
  fi
  local -a c=("${w[@]:$CMD_I}")
  local j=1 found=0
  [ "$WRITE_ONLY" -eq 1 ] || check_sql "${c[@]}"
  check_write_cmd "${c[@]}"
  if [ "$SECRET_HINT" -eq 1 ]; then check_read "${c[@]}"; fi
  if [ "$WRITE_ONLY" -eq 1 ]; then
    case "${c[0]}" in
      sh | bash | zsh | dash | ksh | */sh | */bash | */zsh | */dash | */ksh) ;;
      cd | pushd | popd) do_cd "${c[@]}"; return 0 ;;
      *) return 0 ;;
    esac
  fi
  case "${c[0]}" in
    cd | pushd | popd) do_cd "${c[@]}" ;;
    rm | */rm | rm.exe | */rm.exe) check_rm "${c[@]}"; check_win_rm "${c[@]}" ;;
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
    *) check_other "${c[@]}" ;;
  esac
  return 0
}

# Analisa um texto ja sem aspas, trecho a trecho, na ordem: cd muda a pasta dos trechos seguintes.
analyze() {
  local segs seg
  local -a words
  CUR="$START_DIR"
  CUR_OK=1
  # >|, >& e &> sao redirecionamento, nao pipe nem fundo: viram > antes da separacao.
  segs=${1//">|"/">"}
  segs=${segs//">&"/">"}
  segs=${segs//"&>"/">"}
  # ||, &&, $( e ;|&`(){} separam trechos. Separador repetido so gera linha vazia, que e pulada.
  seg='$('
  segs=${segs//"$seg"/$NL}
  for seg in ';' '|' '&' '`' '(' ')' '{' '}'; do
    segs=${segs//"$seg"/$NL}
  done
  while IFS= read -r seg; do
    case "$seg" in *[![:space:]]*) ;; *) continue ;; esac
    words=()
    read -r -a words <<<"$seg"
    [ "${#words[@]}" -gt 0 ] || continue
    check_segment "${words[@]}" # array nao vazio
  done <<<"$segs"
}

# Duas leituras: os comandos de dentro de $() e crases como trechos proprios, e o comando externo
# com cada substituicao trocada por $KITSUB (alvo nao resolvivel). Sem $(, <(, >( nem crase, o
# comando externo e o proprio texto.
analyze "$FLAT"
case "$FLAT" in
  *'$('* | *'<('* | *'>('* | *'`'*)
    OUTER="$FLAT"
    prev=""
    n=0
    while [ "$prev" != "$OUTER" ] && [ "$n" -lt 20 ]; do
      prev="$OUTER"
      OUTER="$(printf '%s' "$OUTER" | sed -E 's/[$<>]\([^()]*\)/$KITSUB/g')"
      n=$((n + 1))
    done
    OUTER="$(printf '%s' "$OUTER" | sed -E 's/`[^`]*`/$KITSUB/g; s/[$<>]\(/ $KITSUB /g; s/`/ $KITSUB /g')"
    [ "$OUTER" != "$FLAT" ] && analyze "$OUTER" ;;
esac

# Script de sed, perl ou awk, ou padrao de grep, entre aspas com ;, |, &, (), {}, crase ou > se
# partiria em trechos e o arquivo ficaria longe do comando. Mais uma leitura, so de escrita e de
# leitura de segredo, com esses caracteres trocados por _ dentro das aspas. A leitura de cima
# continua valendo para sh -c "echo > .env".
MASK_RE='(^|[^a-z0-9_])(g?sed|perl)(\.exe)?([[:space:]]|$)'
[ "$SECRET_HINT" -eq 1 ] && MASK_RE='(^|[^a-z0-9_])(g?sed|perl|[gmn]?awk|[ef]?grep|rg|ag)(\.exe)?([[:space:]]|$)'
case "$CMD" in
  *"$DQ"* | *"$SQ"*)
    if has "$MASK_RE"; then
      MASKED="$(printf '%s' "$CMD" | awk '
        { s = (NR > 1 ? "\n" : "") $0; o = ""; n = length(s)
          for (i = 1; i <= n; i++) {
            ch = substr(s, i, 1)
            if (ch == "\\" && q != "\047") {
              nx = substr(s, i + 1, 1)
              if (q != "" && index(";|&(){}`>", nx)) nx = "_"
              o = o ch nx; i++; continue
            }
            if (q == "") { if (ch == "\047" || ch == "\"") q = ch; o = o ch; continue }
            if (ch == q) { q = ""; o = o ch; continue }
            if (index(";|&(){}`>", ch)) ch = "_"
            o = o ch
          }
          printf "%s", o }')"
      flatten "$MASKED"
      WRITE_ONLY=1
      analyze "$FLAT_OUT"
      WRITE_ONLY=0
    fi ;;
esac

# Nenhum trecho negado: pede a confirmacao guardada. Em bypassPermissions a documentacao nao garante
# que o ask de hook vire pergunta, entao nega.
if [ -n "$ASK_MSG" ]; then
  [ "$MODE" = "bypassPermissions" ] && kit_deny_pretool "$ASK_BYPASS"
  kit_ask_pretool "$ASK_MSG"
fi

exit 0
