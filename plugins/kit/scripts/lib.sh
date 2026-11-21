#!/usr/bin/env bash
# Funcoes comuns dos hooks do kit. Dependencias: bash, jq, git.

KIT_INPUT=""
KIT_JSON=""
KIT_ROOT=""

kit_require_jq() {
  command -v jq >/dev/null 2>&1 || exit 0
}

# Mensagem unica de jq ausente: guardas e SessionStart.
kit_jq_missing_msg() {
  echo "kit: jq não encontrado — instale com $(kit_install_hint jq "$(kit_platform)") e reabra o Claude Code"
}

# Comandos exatos de instalacao do jq liberados pelo guard-bash sem jq, por plataforma.
kit_jq_install_cmds() {
  case "$(kit_platform)" in
    windows) echo "winget install jqlang.jq" ;;
    macos) echo "brew install jq" ;;
    *) printf '%s\n' "sudo apt install jq" "sudo apt-get install jq" "sudo dnf install jq" "sudo pacman -S jq" ;;
  esac
}

# 0 se o JSON cru de um PreToolUse/Bash tem como comando exatamente um dos comandos de instalacao
# do jq. Sem jq: a chave "command" precisa aparecer uma vez so, sem barra antes (fora de string),
# e o valor fecha logo depois do comando, entao nada pode vir junto.
kit_raw_is_jq_install() {
  local raw="$1" c re n
  raw="$(printf '%s' "$raw" | tr -d '\r\n')"
  n="$(printf '%s' "$raw" | grep -o '"command"' | wc -l | tr -d ' ')"
  [ "$n" = "1" ] || return 1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    re="(^|[^\\])\"command\"[[:space:]]*:[[:space:]]*\"${c//./\\.}\""
    printf '%s' "$raw" | grep -Eq -- "$re" && return 0
  done < <(kit_jq_install_cmds)
  return 1
}

# Guardas de seguranca nao podem liberar por falta de dependencia: sem jq, bloqueiam.
# Com --allow-jq-install (guard-bash), le o stdin cru e libera so o comando de instalacao do jq.
kit_require_jq_strict() {
  command -v jq >/dev/null 2>&1 && return 0
  if [ "${1:-}" = "--allow-jq-install" ] && kit_raw_is_jq_install "$(cat)"; then
    exit 0
  fi
  kit_jq_missing_msg >&2
  exit 2
}

# Texto como string JSON, sem jq: escapa barra, aspas, tab, CR e quebra de linha.
kit_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

kit_read_input() {
  KIT_INPUT="$(cat)"
}

# 0 se a entrada do hook e um objeto JSON. Guardas bloqueiam quando nao e.
kit_input_ok() {
  printf '%s' "$KIT_INPUT" | jq -e 'type == "object"' >/dev/null 2>&1
}

# Guardas: entrada vazia ou truncada bloqueia com exit 2.
kit_require_input() {
  kit_input_ok && return 0
  echo "kit: entrada do hook vazia ou ilegível; chamada bloqueada" >&2
  exit 2
}

# 0 se o arquivo e um objeto JSON valido. Uso: kit_json_ok <arquivo>
kit_json_ok() {
  jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

# 0 se protected_paths, guards.allow_write e guards.deny_write tem a forma que os guardas leem
# (lista, ou ausente). Uso: kit_guard_cfg_ok <arquivo>
kit_guard_cfg_ok() {
  jq -e '((.protected_paths // []) | type == "array")
    and ((.guards // {}) | type == "object")
    and (((.guards // {}).allow_write // []) | type == "array")
    and (((.guards // {}).deny_write // []) | type == "array")' "$1" >/dev/null 2>&1
}

# Le varios campos da entrada do hook com um jq so, cada um na variavel indicada. Como o kit_field:
# null e false viram vazio, CR sai e as quebras de linha do fim tambem. Retorna 1 se a entrada nao
# e um objeto JSON. Uso: kit_fields CMD '.tool_input.command' CWD '.cwd'
kit_fields() {
  local prog ok="" v n
  local -a names=()
  prog='def f: if . == null or . == false then "" elif type == "string" then . else tostring end;
    if type == "object" then "ok", "\u0000"'
  while [ $# -ge 2 ]; do
    names+=("$1")
    prog+=", ((try ($2) catch null) // null | f), \"\\u0000\""
    shift 2
  done
  prog+=' else empty end'
  {
    IFS= read -r -d '' ok
    for n in ${names[@]+"${names[@]}"}; do
      v=""
      IFS= read -r -d '' v
      v="${v//$'\r'/}"
      while [ "${v%$'\n'}" != "$v" ]; do v="${v%$'\n'}"; done
      printf -v "$n" '%s' "$v"
    done
  } < <(jq -j "$prog" 2>/dev/null <<<"$KIT_INPUT")
  [ "$ok" = "ok" ]
}

# Le um campo do JSON de entrada do hook. Uso: kit_field '.tool_input.command'
kit_field() {
  printf '%s' "$KIT_INPUT" | jq -r "$1 // empty" 2>/dev/null | tr -d '\r'
}

kit_norm_path() {
  printf '%s' "${1//\\//}"
}

# Caminho absoluto normalizado sem tocar no disco e sem realpath: \ vira /, // colapsa, . e ..
# resolvidos (mesmo por pasta inexistente). Relativo e resolvido contra $2. Aceita /x, C:/x e C:.
# Uso: kit_path_norm <caminho> [base]
kit_path_norm() {
  kit_path_norm_to "$@"
  printf '%s' "$KIT_NORMED"
}

# Igual ao kit_path_norm, com o resultado em KIT_NORMED (sem subshell).
KIT_NORMED=""
kit_path_norm_to() {
  local p="${1//\\//}" base="${2:-/}" prefix="" part IFS=/
  local -a parts=() stack=()
  case "$p" in [A-Za-z]:) p="$p/" ;; esac
  case "$p" in
    /* | [A-Za-z]:/*) ;;
    *) base="${base//\\//}"; p="${base%/}/$p" ;;
  esac
  case "$p" in [A-Za-z]:/*) prefix="${p:0:2}"; p="${p:2}" ;; esac
  read -r -a parts <<<"$p"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      '' | .) ;;
      ..) [ "${#stack[@]}" -gt 0 ] && unset "stack[$((${#stack[@]} - 1))]" ;;
      *) stack+=("$part") ;;
    esac
  done
  KIT_NORMED="$prefix/${stack[@]+"${stack[*]}"}"
}

# Os hooks rodam a cada chamada de ferramenta e, no Git Bash, criar um processo custa dezenas de
# milissegundos. As funcoes "_to" abaixo devolvem o resultado numa variavel, sem $( ) nem programa
# externo, para os lacos por regra do kit.json nao custarem um processo por item.

# Sistema pelo uname, lido uma vez em KIT_UNAME; sem uname no PATH, pelo $OSTYPE do proprio bash.
# Chamado no shell principal, os subshells herdam o valor.
KIT_UNAME=""
kit_uname_init() {
  [ -z "$KIT_UNAME" ] || return 0
  KIT_UNAME="$(uname -s 2>/dev/null)"
  if [ -z "$KIT_UNAME" ]; then
    case "${OSTYPE:-}" in
      msys* | cygwin* | win*) KIT_UNAME="MINGW" ;;
      darwin*) KIT_UNAME="Darwin" ;;
      *) KIT_UNAME="Linux" ;;
    esac
  fi
}

kit_uname() {
  kit_uname_init
  printf '%s' "$KIT_UNAME"
}

# Verdadeiro em Windows e macOS, onde o sistema de arquivos padrao nao diferencia maiusculas.
KIT_CI=""
kit_case_insensitive() {
  if [ -z "$KIT_CI" ]; then
    kit_uname_init
    case "$KIT_UNAME" in MINGW* | MSYS* | CYGWIN* | Darwin) KIT_CI=1 ;; *) KIT_CI=0 ;; esac
  fi
  [ "$KIT_CI" = "1" ]
}

# Texto em minusculas onde o sistema de arquivos nao diferencia maiusculas; igual nos demais.
# Resultado em KIT_FOLDED. Texto so com ASCII e trocado no proprio bash (o 3.2 nao tem ${x,,});
# com outro byte, vai pelo tr.
KIT_FOLDED=""
kit_fold_to() {
  local i
  KIT_FOLDED="$1"
  kit_case_insensitive || return 0
  case "$1" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) ;; *[![:ascii:]]*) ;; *) return 0 ;; esac
  if [ -n "${1//[[:ascii:]]/}" ]; then
    KIT_FOLDED="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    return 0
  fi
  for ((i = 0; i < 26; i++)); do
    KIT_FOLDED="${KIT_FOLDED//${KIT_ASCII_UPPER:$i:1}/${KIT_ASCII_LOWER:$i:1}}"
  done
}
KIT_ASCII_UPPER="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
KIT_ASCII_LOWER="abcdefghijklmnopqrstuvwxyz"

kit_fold() {
  kit_fold_to "$1"
  printf '%s' "$KIT_FOLDED"
}

# Pasta-mae de um caminho ja normalizado com "/", em KIT_PARENT, como o dirname: "/a" -> "/",
# "C:/a" -> "C:/", nome sem barra -> ".".
KIT_PARENT=""
kit_parent_to() {
  local p="$1"
  case "$p" in / | [A-Za-z]:/) KIT_PARENT="$p"; return 0 ;; esac
  p="${p%/}"
  case "$p" in
    */*)
      KIT_PARENT="${p%/*}"
      case "$KIT_PARENT" in '') KIT_PARENT="/" ;; [A-Za-z]:) KIT_PARENT="$KIT_PARENT/" ;; esac ;;
    *) KIT_PARENT="." ;;
  esac
}

# Guardas: saida inesperada (erro, variavel nao definida) bloqueia com exit 2, nunca libera.
kit_guard_fail_closed() {
  trap 'kit_rc=$?; if [ "$kit_rc" -ne 0 ] && [ "$kit_rc" -ne 2 ]; then echo "kit: erro interno no guarda (status $kit_rc); chamada bloqueada" >&2; exit 2; fi' EXIT
}

kit_cwd() {
  local c
  c="$(kit_field '.cwd')"
  [ -n "$c" ] || c="${CLAUDE_PROJECT_DIR:-$PWD}"
  kit_norm_path "$c"
}

# Pasta da sessao. Um .git abaixo dela pertence a um repositorio filho: a busca por kit.json
# continua subindo ate ela (nunca acima). Vazio = comportamento de repositorio unico.
KIT_CEILING=""

# Lista as raizes com .claude/kit.json a partir de um arquivo ou diretorio, da mais proxima para cima.
# Para no primeiro .git, exceto quando ele esta dentro de KIT_CEILING; nesse caso para no KIT_CEILING.
kit_kit_roots() {
  local start dir parent extended=0
  start="${1//\\//}"
  [ -n "$start" ] || return 0
  if [ -d "$start" ]; then dir="$start"; else kit_parent_to "$start"; dir="$KIT_PARENT"; fi
  while [ -n "$dir" ] && [ ! -d "$dir" ]; do
    kit_parent_to "$dir"
    parent="$KIT_PARENT"
    [ "$parent" = "$dir" ] && return 0
    dir="$parent"
  done
  while :; do
    [ -f "$dir/.claude/kit.json" ] && printf '%s\n' "$dir"
    [ "$extended" -eq 1 ] && [ "$dir" = "$KIT_CEILING" ] && return 0
    if [ -e "$dir/.git" ]; then
      if [ -n "$KIT_CEILING" ] && [ "${dir#"$KIT_CEILING"/}" != "$dir" ]; then
        extended=1
      else
        return 0
      fi
    fi
    kit_parent_to "$dir"
    parent="$KIT_PARENT"
    if [ "$parent" = "$dir" ] || [ "$parent" = "." ]; then return 0; fi
    dir="$parent"
  done
}

# Define KIT_JSON e KIT_ROOT com o kit.json mais proximo. Retorna 1 se nao encontrar.
find_kit_json() {
  local first
  first="$(kit_kit_roots "$1" | head -n 1)"
  [ -n "$first" ] || return 1
  KIT_ROOT="$first"
  KIT_JSON="$first/.claude/kit.json"
}

kit_use_root() {
  KIT_ROOT="$1"
  KIT_JSON="$1/.claude/kit.json"
}

# Repositorios git da sessao: o do proprio cwd e os filhos (ate 3 niveis) ou a lista "repos"
# do kit.json do cwd. Um por linha, caminho absoluto. Cache por session_id em $TMPDIR; com o
# terceiro argumento "refresh", descobre de novo e regrava o cache.
kit_repos() {
  local cwd="$1" sid="${2:-}" refresh="${3:-}" own="" sig cache d list=""
  local tmp="${TMPDIR:-${TMP:-/tmp}}"
  if [ -f "$cwd/.claude/kit.json" ]; then sig="$cwd|$(cksum <"$cwd/.claude/kit.json")"; else sig="$cwd|none"; fi
  if [ -n "$sid" ]; then
    cache="$tmp/kit-repos-${sid//[^A-Za-z0-9_-]/_}"
    if [ -z "$refresh" ] && [ -f "$cache" ] && [ "$(head -n 1 "$cache")" = "$sig" ]; then
      tail -n +2 "$cache"
      return 0
    fi
  fi

  own="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  own="$(kit_norm_path "$own")"
  [ -n "$own" ] && list+="$own"$'\n'

  if [ -f "$cwd/.claude/kit.json" ] && jq -e '(.repos // null) | type == "array"' "$cwd/.claude/kit.json" >/dev/null 2>&1; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      d="$cwd/${d#./}"
      d="${d%/}"
      [ -e "$d/.git" ] && list+="$d"$'\n'
    done < <(jq -r '.repos[]' "$cwd/.claude/kit.json" 2>/dev/null | tr -d '\r')
  else
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      d="$(kit_norm_path "$(dirname "$d")")"
      [ "$d" = "$cwd" ] && continue
      [ "$d" = "$own" ] && continue
      if [ -n "$own" ] && git -C "$own" check-ignore -q "$d" 2>/dev/null; then continue; fi
      list+="$d"$'\n'
    done < <(find "$cwd" -maxdepth 4 \( -name node_modules -o -name target -o -name dist -o -name build \
      -o -name vendor -o -name .venv \) -prune -o -name .git -prune -print 2>/dev/null | sort)
  fi

  list="$(printf '%s' "$list" | awk 'NF && !seen[$0]++')"
  if [ -n "$sid" ]; then
    { printf '%s\n' "$sig"; [ -n "$list" ] && printf '%s\n' "$list"; } >"$cache" 2>/dev/null
  fi
  [ -n "$list" ] && printf '%s\n' "$list"
  return 0
}

# Raiz da sessao: o repositorio git do cwd, ou o proprio cwd (pasta-mae sem git).
kit_session_root() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  if [ -n "$top" ]; then kit_norm_path "$top"; else printf '%s' "$1"; fi
}

# Planos com tarefa "- [ ]" pendente: docs/specs/**/PLAN.md na raiz e em cada repositorio, mais os
# .md de "plan_dirs" do kit.json da raiz, filtrados pelo -mtime do find ($1: -14 ou +13; o find
# trunca a idade em dias, entao +13 e "14 dias ou mais").
# Saida: "mtime<TAB>feitas<TAB>total<TAB>caminho", do mais recente para o mais antigo.
kit_plans_by_age() {
  local age="$1" root="$2" d f done total
  shift 2
  {
    for d in "$root" "$@"; do
      [ -d "$d/docs/specs" ] && find "$d/docs/specs" -name PLAN.md -type f -mtime "$age" 2>/dev/null
    done
    if [ -f "$root/.claude/kit.json" ]; then
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -d "$root/${d#./}" ] && find "$root/${d#./}" -maxdepth 2 -name '*.md' -type f -mtime "$age" 2>/dev/null
      done < <(jq -r '(.plan_dirs // [])[]' "$root/.claude/kit.json" 2>/dev/null | tr -d '\r')
    fi
  } | awk '!seen[$0]++' | while IFS= read -r f; do
    grep -qE '^[[:space:]]*[-*] \[ \]' "$f" || continue
    done="$(grep -cE '^[[:space:]]*[-*] \[[xX]\]' "$f")"
    total="$(grep -cE '^[[:space:]]*[-*] \[[ xX]\]' "$f")"
    printf '%s\t%s\t%s\t%s\n' "$(date -r "$f" +%s 2>/dev/null || echo 0)" "$done" "$total" "$f"
  done | sort -t$'\t' -k1,1nr
}

# Planos ativos: modificados nos ultimos 14 dias e com tarefa pendente.
# Saida: "feitas<TAB>total<TAB>caminho", do mais recente para o mais antigo.
# Uso: kit_active_plans <raiz> [repositorio...]
kit_active_plans() {
  kit_plans_by_age -14 "$@" | cut -f2-
}

# Planos parados: tarefa pendente e 14 dias ou mais sem mudanca. Mesma saida de kit_plans_by_age.
# Uso: kit_stale_plans <raiz> [repositorio...]
kit_stale_plans() {
  kit_plans_by_age +13 "$@"
}

# Caminho de $2 relativo a $1 (ou o proprio $2 se estiver fora).
kit_rel_to() {
  if [ "$2" = "$1" ]; then printf '.'; return 0; fi
  if [ "${2#"$1"/}" != "$2" ]; then printf '%s' "${2#"$1"/}"; else printf '%s' "$2"; fi
}

# Valor de commands.<chave>: string, ou objeto { "run", "files" }. cmd_run da o comando ("" se
# ausente ou de tipo errado); cmd_files, a lista de globs (vazia na forma string).
KIT_JQ_CMD='def cmd_run: if type == "string" then . elif type == "object" then ((.run // "") | if type == "string" then . else "" end) else "" end;
  def cmd_files: if type == "object" then ((.files // []) | if type == "array" then map(strings) elif type == "string" then [.] else [] end) else [] end;'

# Comando de commands.<chave> no kit.json encontrado. Vazio se ausente.
kit_cmd() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r --arg k "$1" "$KIT_JQ_CMD"' .commands[$k] | cmd_run' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# Globs de "files" de commands.<chave>, um por linha. Vazio na forma string.
kit_cmd_files() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r --arg k "$1" "$KIT_JQ_CMD"' .commands[$k] | cmd_files[]' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# Lista de strings de um campo array do kit.json, uma por linha.
kit_list() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r --arg k "$1" '(.[$k] // []) | if type == "array" then .[] else empty end' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# Numero de regras em um campo array de objetos do kit.json (coupled_changes, key_parity).
kit_rule_count() {
  [ -n "$KIT_JSON" ] || { echo 0; return 0; }
  jq -r --arg k "$1" '(.[$k] // []) | if type == "array" then length else 0 end' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# Lista de strings de um campo da regra. Uso: kit_rule_list <campo-raiz> <indice> <campo>
kit_rule_list() {
  jq -r --arg k "$1" --argjson i "$2" --arg f "$3" \
    '(.[$k][$i][$f] // []) | if type == "array" then .[] else . end' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# Valor string de um campo da regra, com padrao. Uso: kit_rule_str <campo-raiz> <indice> <campo> <padrao>
kit_rule_str() {
  jq -r --arg k "$1" --argjson i "$2" --arg f "$3" --arg d "$4" '.[$k][$i][$f] // $d' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# protected_paths como linhas "glob<TAB>write<TAB>message". Aceita string (write=allow, sem
# mensagem) ou objeto {glob, message, write: allow|deny}. O glob perde ./ e / iniciais e \ vira /.
kit_protected_entries() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r 'def norm: gsub("\\\\"; "/") | sub("^(\\./|/)+"; "");
    (.protected_paths // [])[] |
    if type == "string" then [norm, "allow", ""]
    elif type == "object" then [((.glob // "") | norm), (.write // "allow"), (.message // "")]
    else empty end | @tsv' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# guards.allow_write como um glob por linha; guards.deny_write como "glob<TAB>message". Item string ou
# objeto {glob, message}. Mesma normalizacao de glob do protected_paths.
kit_guard_allow_entries() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r 'def norm: gsub("\\\\"; "/") | sub("^(\\./|/)+"; "");
    (.guards.allow_write // [])[] |
    if type == "string" then norm elif type == "object" then (.glob // "") | norm else empty end |
    select(. != "")' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

kit_guard_deny_entries() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r 'def norm: gsub("\\\\"; "/") | sub("^(\\./|/)+"; "");
    (.guards.deny_write // [])[] |
    if type == "string" then [norm, ""]
    elif type == "object" then [((.glob // "") | norm), (.message // "")]
    else empty end | select(.[0] != "") | @tsv' "$KIT_JSON" 2>/dev/null | tr -d '\r'
}

# As regras de escrita de um kit.json num jq so, para o guard-files, uma por linha:
#   OK                              objeto com protected_paths e guards na forma certa
#   X                               protected_paths ou guards com tipo errado (so esta linha)
#   D<TAB>glob<TAB>mensagem         guards.deny_write
#   A<TAB>glob                      guards.allow_write
#   P<TAB>glob<TAB>write<TAB>msg    protected_paths (write: allow ou deny)
# Sem saida: o arquivo nao e um objeto JSON. Item sem glob fica de fora. Uso: kit_guard_rules <arquivo>
kit_guard_rules() {
  jq -r 'def norm: if type == "string" then gsub("\\\\"; "/") | sub("^(\\./|/)+"; "") else "" end;
    def text: if type == "string" then . else tostring end;
    if type != "object" then empty
    elif (((.protected_paths // []) | type == "array") and ((.guards // {}) | type == "object")
      and (((.guards // {}).allow_write // []) | type == "array")
      and (((.guards // {}).deny_write // []) | type == "array")) | not then "X"
    else "OK",
      ((.guards.deny_write // [])[]
        | (if type == "string" then [norm, ""] elif type == "object" then [(.glob | norm), ((.message // "") | text)] else empty end)
        | select(.[0] != "") | ["D"] + . | @tsv),
      ((.guards.allow_write // [])[]
        | (if type == "string" then norm elif type == "object" then (.glob | norm) else empty end)
        | select(. != "") | ["A", .] | @tsv),
      ((.protected_paths // [])[]
        | (if type == "string" then [norm, "allow", ""]
           elif type == "object" then [(.glob | norm), (if .write == "deny" then "deny" else "allow" end), ((.message // "") | text)]
           else empty end)
        | select(.[0] != "") | ["P"] + . | @tsv)
    end' "$1" 2>/dev/null
}

# Nome de arquivo de exemplo: termina em .example, .sample, .template ou .dist.
kit_is_example_name() {
  kit_fold_to "${1##*/}"
  case "$KIT_FOLDED" in *.example | *.sample | *.template | *.dist) return 0 ;; esac
  return 1
}

# 0 se o glob e largo demais para guards.allow_write (*, **, **/*, .env*, *.env e afins).
kit_glob_broad() {
  local g="${1//\\//}"
  g="${g#./}"
  g="${g#/}"
  while [ "${g#\*\*/}" != "$g" ]; do g="${g#\*\*/}"; done
  case "$g" in '' | '*' | '**' | '*.*' | '.*' | '.env*' | '*.env' | '*.env*') return 0 ;; esac
  [[ "$g" =~ ^(\*\*?/)*\*\*?$ ]] && return 0
  return 1
}

# 0 se o glob aponta para segredo de verdade (.env, .env.<x> sem sufixo de exemplo, *.pem, *.key,
# secrets/, keys/). Esses caminhos nao tem excecao em guards.allow_write.
kit_glob_secret() {
  local g base
  kit_fold_to "${1//\\//}"
  g="$KIT_FOLDED"
  case "/$g/" in */secrets/* | */keys/*) return 0 ;; esac
  base="${g##*/}"
  kit_is_example_name "$base" && return 1
  case "$base" in .env | .env.* | *.pem | *.key) return 0 ;; esac
  return 1
}

# Regras de escrita comuns ao guard-files (Edit, Write) e ao guard-bash (>, tee, sed -i, cp...):
# segredos, guards.deny_write e protected_paths, este com excecao por guards.allow_write. Quem
# chama define KIT_CEILING e KIT_NEW_FILE (1: o arquivo ainda nao existe). Bloqueio sai pelo
# kit_deny_pretool.
KIT_NEW_FILE=0
KIT_EXAMPLE_HINT="Arquivo de exemplo: use o sufixo .example, .sample, .template ou .dist."

# Windows ignora espaco e ponto no fim de cada nome e trata "nome:fluxo" (ADS) como o proprio nome.
# O sed so roda quando o caminho tem um desses casos.
kit_win_clean() {
  case "${1#[A-Za-z]:}" in
    *:* | *[.\ ]/* | *[.\ ]) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  printf '%s' "$1" | sed -E 's#^([A-Za-z]):#\1|#; s#:[^/]*##g; s#^([A-Za-z])\|#\1:#; s#([^/.])[. ]+(/|$)#\1\2#g'
}

# Alvo final de um symlink (encadeado ate 20 niveis) e pasta real do primeiro ancestral existente,
# em KIT_REAL. A pasta real sai de um cd -P no proprio shell (volta para a pasta de antes); no
# Windows, /c/x vira C:/x sem o cygpath, que so roda para as outras montagens.
KIT_REAL=""
KIT_RP_DIRS=()
KIT_RP_REALS=()
kit_real_path_to() {
  local p="$1" t n=0 dir rest="" real="" here="$PWD" d i
  while [ -L "$p" ] && [ "$n" -lt 20 ]; do
    t="$(readlink "$p" 2>/dev/null)" || break
    kit_parent_to "$p"
    kit_path_norm_to "$t" "$KIT_PARENT"
    p="$KIT_NORMED"
    n=$((n + 1))
  done
  kit_parent_to "$p"
  dir="$KIT_PARENT"
  while [ ! -d "$dir" ]; do
    rest="/${dir##*/}$rest"
    kit_parent_to "$dir"
    [ "$KIT_PARENT" = "$dir" ] && break
    dir="$KIT_PARENT"
  done
  # A pasta real de cada pasta existente e resolvida uma vez por chamada do hook.
  for ((i = 0; i < ${#KIT_RP_DIRS[@]}; i++)); do
    [ "${KIT_RP_DIRS[$i]}" = "$dir" ] && break
  done
  if [ "$i" -lt "${#KIT_RP_DIRS[@]}" ]; then
    kit_path_norm_to "${KIT_RP_REALS[$i]%/}$rest/${p##*/}" /
    KIT_REAL="$KIT_NORMED"
    return 0
  fi
  # Muda a pasta do shell e volta: quem chama nao pode depender de caminho relativo.
  if CDPATH='' cd -P -- "$dir" 2>/dev/null; then
    real="$PWD"
    CDPATH='' cd -- "$here" 2>/dev/null || cd / || true
  fi
  if [ -n "$real" ]; then
    kit_uname_init
    case "$KIT_UNAME" in
      MINGW* | MSYS* | CYGWIN*)
        case "$real" in
          /[A-Za-z] | /[A-Za-z]/*)
            d="${real:1:1}"
            for ((i = 0; i < 26; i++)); do
              [ "$d" = "${KIT_ASCII_LOWER:$i:1}" ] && d="${KIT_ASCII_UPPER:$i:1}" && break
            done
            real="$d:${real:2}"
            [ "${#real}" -eq 2 ] && real="$real/" ;;
          /*) command -v cygpath >/dev/null 2>&1 && real="$(cygpath -m "$real" 2>/dev/null)" ;;
        esac ;;
    esac
  fi
  [ -n "$real" ] || real="$dir"
  KIT_RP_DIRS+=("$dir")
  KIT_RP_REALS+=("$real")
  kit_path_norm_to "${real%/}$rest/${p##*/}" /
  KIT_REAL="$KIT_NORMED"
}

# Raizes de kit.json que valem para o caminho (a mais proxima e as de cima, ate a pasta-mae) e as
# regras de cada uma (kit_guard_rules). Cada kit.json e lido uma vez por chamada do hook.
KIT_ROOTS=()
KIT_RULES=()
KIT_RC_ROOTS=()
KIT_RC_RULES=()
KIT_LR_DIRS=()
KIT_LR_ROOTS=()
kit_load_rules() {
  local root r i dir roots
  KIT_ROOTS=()
  KIT_RULES=()
  # As raizes dependem so da primeira pasta existente acima do caminho: uma busca por pasta.
  dir="${1//\\//}"
  if [ ! -d "$dir" ]; then kit_parent_to "$dir"; dir="$KIT_PARENT"; fi
  while [ -n "$dir" ] && [ ! -d "$dir" ]; do
    kit_parent_to "$dir"
    [ "$KIT_PARENT" = "$dir" ] && break
    dir="$KIT_PARENT"
  done
  for ((i = 0; i < ${#KIT_LR_DIRS[@]}; i++)); do
    [ "${KIT_LR_DIRS[$i]}" = "$dir" ] && break
  done
  if [ "$i" -lt "${#KIT_LR_DIRS[@]}" ]; then
    roots="${KIT_LR_ROOTS[$i]}"
  else
    roots="$(kit_kit_roots "$dir")"
    roots="${roots//$'\r'/}"
    KIT_LR_DIRS+=("$dir")
    KIT_LR_ROOTS+=("$roots")
  fi
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for ((i = 0; i < ${#KIT_RC_ROOTS[@]}; i++)); do
      [ "${KIT_RC_ROOTS[$i]}" = "$root" ] && break
    done
    if [ "$i" -lt "${#KIT_RC_ROOTS[@]}" ]; then
      r="${KIT_RC_RULES[$i]}"
    else
      r="$(kit_guard_rules "$root/.claude/kit.json")"
      # O CR sai numa atribuicao simples: dentro de ( ) de array o bash nao expande o $'\r' do padrao.
      r="${r//$'\r'/}"
      KIT_RC_ROOTS+=("$root")
      KIT_RC_RULES+=("$r")
    fi
    KIT_ROOTS+=("$root")
    KIT_RULES+=("$r")
  done <<<"$roots"
}

# Caminho relativo a KIT_ROOT em KIT_REL (o proprio caminho se estiver fora) e em minusculas em KIT_CMP.
KIT_REL=""
KIT_CMP=""
kit_rel_of() {
  KIT_REL="$1"
  if [ -n "$KIT_ROOT" ] && [ "${1#"$KIT_ROOT"/}" != "$1" ]; then KIT_REL="${1#"$KIT_ROOT"/}"; fi
  kit_fold_to "$KIT_REL"
  KIT_CMP="$KIT_FOLDED"
}

# So o que se decide pelo nome: arquivo de segredo e pastas secrets/ e keys/. Vale tambem para
# alvo que nao da para resolver (variavel, ~, glob).
kit_check_write_name() {
  local file="$1" base
  kit_fold_to "${file##*/}"
  base="$KIT_FOLDED"
  if ! kit_is_example_name "$base"; then
    case "$base" in
      .env | .env.*) kit_deny_pretool "kit: escrita em arquivo de segredo (${file##*/}) bloqueada. $KIT_EXAMPLE_HINT" ;;
      *.pem | *.key) kit_deny_pretool "kit: escrita em chave/certificado (${file##*/}) bloqueada." ;;
    esac
  fi
  kit_fold_to "$file"
  case "/$KIT_FOLDED" in
    */secrets/*) kit_deny_pretool "kit: escrita em diretorio secrets/ bloqueada." ;;
    */keys/*) kit_deny_pretool "kit: escrita em diretorio keys/ bloqueada." ;;
  esac
  return 0
}

# Caminho absoluto ja normalizado.
kit_check_write() {
  local file="$1" rules tag glob a b allowed=0 broad="" i
  local hint="Se este arquivo não é segredo, adicione o caminho em guards.allow_write no .claude/kit.json."
  kit_check_write_name "$file"

  # Valem os guards e o protected_paths do kit.json mais proximo e dos kit.json acima dele (pasta-mae).
  # guards.deny_write bloqueia sempre; guards.allow_write (sem glob largo nem segredo) libera o protected_paths.
  kit_load_rules "$file"
  for ((i = 0; i < ${#KIT_ROOTS[@]}; i++)); do
    kit_use_root "${KIT_ROOTS[$i]}"
    rules="${KIT_RULES[$i]}"
    kit_rel_of "$file"
    # kit.json ilegivel: as regras nao podem ser conferidas. So o proprio kit.json pode ser escrito.
    if [ "$KIT_CMP" != ".claude/kit.json" ]; then
      case "$rules" in
        OK | OK$'\n'*) ;;
        X | X$'\n'*)
          kit_deny_pretool "kit: $KIT_JSON tem protected_paths ou guards com tipo errado (precisam ser lista); as regras não podem ser conferidas. Corrija o kit.json e tente de novo." ;;
        *)
          kit_deny_pretool "kit: $KIT_JSON não é JSON válido; protected_paths e guards não podem ser conferidos. Corrija o kit.json (jq . mostra o erro) e tente de novo." ;;
      esac
    fi
    case "$rules" in OK$'\n'*) ;; *) continue ;; esac
    # As linhas D (deny_write) vem antes das A (allow_write), como no kit_guard_rules.
    while IFS=$'\t' read -r tag glob a b; do
      case "$tag" in
        D)
          kit_fold_to "$glob"
          glob_match "$KIT_FOLDED" "$KIT_CMP" || continue
          [ -n "$a" ] && kit_deny_pretool "kit: $KIT_REL é bloqueado. $a"
          kit_deny_pretool "kit: $KIT_REL casa guards.deny_write ($glob) do kit.json." ;;
        A)
          kit_glob_secret "$glob" && continue
          kit_fold_to "$glob"
          glob_match "$KIT_FOLDED" "$KIT_CMP" || continue
          if kit_glob_broad "$glob"; then broad="$glob"; continue; fi
          allowed=1 ;;
      esac
    done <<<"$rules"
  done
  [ "$allowed" -eq 1 ] && return 0
  if [ -n "$broad" ]; then
    hint="guards.allow_write ignora \"$broad\": glob largo demais; liste o caminho exato."
  fi

  for ((i = 0; i < ${#KIT_ROOTS[@]}; i++)); do
    kit_use_root "${KIT_ROOTS[$i]}"
    rules="${KIT_RULES[$i]}"
    case "$rules" in OK$'\n'*) ;; *) continue ;; esac
    kit_rel_of "$file"
    while IFS=$'\t' read -r tag glob a b; do
      [ "$tag" = "P" ] || continue
      kit_fold_to "$glob"
      glob_match "$KIT_FOLDED" "$KIT_CMP" || continue
      [ "$KIT_NEW_FILE" -eq 1 ] && [ "$a" != "deny" ] && continue
      if [ -n "$b" ]; then
        kit_deny_pretool "kit: $KIT_REL é protegido. $b $hint"
      fi
      if [ "$KIT_NEW_FILE" -eq 1 ]; then
        kit_deny_pretool "kit: $KIT_REL casa protected_paths ($glob) com write: deny no kit.json. Nem arquivo novo pode ser criado aqui. $hint"
      fi
      kit_deny_pretool "kit: $KIT_REL casa protected_paths ($glob) do kit.json. Gere um arquivo novo ou edite manualmente. $hint"
    done <<<"$rules"
  done
  return 0
}

# kit_check_write no caminho e, se for symlink ou estiver sob um, no alvo final.
kit_check_write_path() {
  local real real_cmp
  kit_check_write "$1"
  kit_real_path_to "$1"
  real="$KIT_REAL"
  kit_fold_to "$real"
  real_cmp="$KIT_FOLDED"
  kit_fold_to "$1"
  if [ "$real_cmp" != "$KIT_FOLDED" ]; then kit_check_write "$real"; fi
  return 0
}

# Chaves folha de um JSON achatadas com ".", uma por linha, ordenadas. Retorna 1 se o JSON for invalido.
kit_json_keys() {
  local out
  out="$(jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | tr -d '\r' | sed '/^$/d' | LC_ALL=C sort -u
}

# Converte glob (**, *, ?, {a,b}) em regex ERE ancorada, em KIT_GLOB_RE.
KIT_GLOB_RE=""
glob_to_regex_to() {
  local g="$1" out="" i=0 c n len=${#1} brace=0
  while [ "$i" -lt "$len" ]; do
    c="${g:$i:1}"
    n="${g:$((i + 1)):1}"
    case "$c" in
      '*')
        if [ "$n" = '*' ]; then
          if [ "${g:$((i + 2)):1}" = '/' ]; then out+='(.*/)?'; i=$((i + 3)); continue; fi
          out+='.*'; i=$((i + 2)); continue
        fi
        out+='[^/]*' ;;
      '?') out+='[^/]' ;;
      '{') out+='('; brace=$((brace + 1)) ;;
      '}') if [ "$brace" -gt 0 ]; then out+=')'; brace=$((brace - 1)); else out+='\}'; fi ;;
      ',') if [ "$brace" -gt 0 ]; then out+='|'; else out+=','; fi ;;
      '.' | '+' | '(' | ')' | '|' | '^' | '$' | '[' | ']' | '\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
    i=$((i + 1))
  done
  KIT_GLOB_RE="^$out\$"
}

glob_to_regex() {
  glob_to_regex_to "$1"
  printf '%s' "$KIT_GLOB_RE"
}

# Uso: glob_match <glob> <caminho-relativo>. Glob sem "/" tambem casa pelo nome do arquivo.
glob_match() {
  local re
  glob_to_regex_to "$1"
  re="$KIT_GLOB_RE"
  [[ "$2" =~ $re ]] && return 0
  if [[ "$1" != */* ]]; then
    [[ "${2##*/}" =~ $re ]] && return 0
  fi
  return 1
}

# Filtra os caminhos do stdin (um por linha) que casam algum glob dos argumentos, com a mesma regra
# do glob_match. Cada glob vira regex uma vez so; o casamento roda num unico awk.
kit_glob_filter() {
  local g spec=""
  for g in "$@"; do
    [ -n "$g" ] || continue
    case "$g" in */*) spec+="P " ;; *) spec+="B " ;; esac
    glob_to_regex_to "$g"
    spec+="$KIT_GLOB_RE"$'\n'
  done
  [ -n "$spec" ] || return 0
  KIT_GLOB_SPEC="$spec" awk 'BEGIN { n = split(ENVIRON["KIT_GLOB_SPEC"], L, "\n")
      for (i = 1; i <= n; i++) if (L[i] != "") { k++; T[k] = substr(L[i], 1, 1); R[k] = substr(L[i], 3) } }
    { b = $0; sub(/.*\//, "", b)
      for (i = 1; i <= k; i++) if ($0 ~ R[i] || (T[i] == "B" && b ~ R[i])) { print; break } }'
}

# Caminho relativo a KIT_ROOT (ou o proprio caminho se estiver fora).
kit_rel() {
  local p
  p="$(kit_norm_path "$1")"
  if [ -n "$KIT_ROOT" ] && [ "${p#"$KIT_ROOT"/}" != "$p" ]; then
    printf '%s' "${p#"$KIT_ROOT"/}"
  else
    printf '%s' "$p"
  fi
}

kit_quote() {
  # Aspa e troca em variaveis: no bash 3.2, barra invertida escrita direto na troca de ${s//a/b}
  # entre aspas duplas sai literal e o comando quebra em nome com apostrofo.
  local s="$1" q="'" r="'\\''"
  printf "'%s'" "${s//$q/$r}"
}

# Substitui {files} por argumentos ja citados.
kit_subst_files() {
  local cmd="$1" files="$2" out=""
  # Sem ${cmd//...}: no bash 5.2 o & da substituicao vira o texto casado (patsub_replacement).
  while [[ "$cmd" == *"{files}"* ]]; do
    out+="${cmd%%"{files}"*}$files"
    cmd="${cmd#*"{files}"}"
  done
  printf '%s' "$out$cmd"
}

# Executa um comando do manifesto na raiz do kit. Saida combinada vai para o arquivo $2.
kit_run() {
  (cd "$KIT_ROOT" && "${BASH:-bash}" -c "$1") >"$2" 2>&1
}

# Frase fixa de todo deny: o contorno mais provavel e o proprio agente trocar de comando ou ferramenta.
KIT_DENY_NO_WORKAROUND="Nao tente outro comando, interpretador ou ferramenta para o mesmo efeito: explique ao usuario o que queria fazer e peca que ele rode manualmente se for intencional."

kit_deny_pretool() {
  local r="$1 $KIT_DENY_NO_WORKAROUND"
  jq -cn --arg r "$r" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' ||
    { echo "$r" >&2; exit 2; }
  exit 0
}

# Pede confirmacao ao usuario. Sem ninguem para responder (claude -p), o Claude Code nega.
kit_ask_pretool() {
  jq -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}' ||
    { echo "$1" >&2; exit 2; }
  exit 0
}

# Versao minima do Claude Code para onFailure: "block" nos guardas.
KIT_MIN_CLAUDE="2.1.295"

# Uso: kit_version_lt <a> <b>. Compara x.y.z numericamente; 0 se a < b.
kit_version_lt() {
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2; do
    [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ] && return 0
    [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ] && return 1
  done
  return 1
}

# Versao x.y.z do Claude Code no PATH. Vazio se o comando faltar ou a versao for ilegivel.
kit_claude_version() {
  local v
  command -v claude >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then v="$(timeout 5 claude --version 2>/dev/null)"; else v="$(claude --version 2>/dev/null)"; fi
  printf '%s' "$v" | tr -d '\r' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# windows (Git Bash/MSYS no Windows nativo), wsl, macos ou linux.
kit_platform() {
  kit_uname_init
  case "$KIT_UNAME" in
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    Darwin) echo macos ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    *) echo linux ;;
  esac
}

# Prefixo de instalacao do gerenciador de pacotes presente no Linux/WSL; apt se nenhum for achado.
kit_pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then echo "sudo apt install"
  elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install"
  elif command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S"
  elif command -v zypper >/dev/null 2>&1; then echo "sudo zypper install"
  elif command -v apk >/dev/null 2>&1; then echo "sudo apk add"
  else echo "sudo apt install"; fi
}

# Comando de instalacao de uma dependencia (jq, git, bash, claude, bwrap, socat) na plataforma dada.
kit_install_hint() {
  case "$1" in
    claude) echo "claude update"; return 0 ;;
  esac
  case "$2:$1" in
    *:bwrap) echo "$(kit_pkg_install) bubblewrap" ;;
    *:socat) echo "$(kit_pkg_install) socat" ;;
    windows:jq) echo "winget install jqlang.jq" ;;
    windows:*) echo "winget install Git.Git" ;;
    macos:*) echo "brew install $1" ;;
    *) echo "$(kit_pkg_install) $1" ;;
  esac
}

# Avisos de dependencia para o inicio da sessao, um por linha: jq, git e versao do Claude Code.
kit_dependency_notes() {
  local p v
  p="$(kit_platform)"
  command -v jq >/dev/null 2>&1 || kit_jq_missing_msg
  command -v git >/dev/null 2>&1 || echo "kit: git não encontrado; contexto e verificação desligados. Instale com \`$(kit_install_hint git "$p")\` e rode /kit:setup"
  v="$(kit_claude_version)"
  if [ -n "$v" ] && kit_version_lt "$v" "$KIT_MIN_CLAUDE"; then
    echo "kit: Claude Code < $KIT_MIN_CLAUDE, guardas sem onFailure:block — rode claude update (versão atual: $v) e depois /kit:setup"
  fi
  return 0
}

# UserPromptSubmit: grava o HEAD de cada repositorio no inicio do turno em <gitdir>/kit-turn-head
# ("session_id sha"). O verify-gate usa para enxergar o que foi commitado durante o turno.
# Uso: kit_turn_head_mark <session_id> [repositorio...]
kit_turn_head_mark() {
  local sid="$1" repo gd head
  shift
  [ -n "$sid" ] || return 0
  for repo in "$@"; do
    gd="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null | tr -d '\r')"
    head="$(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null | tr -d '\r')"
    [ -n "$gd" ] && [ -n "$head" ] || continue
    printf '%s %s\n' "$sid" "$head" >"$gd/kit-turn-head" 2>/dev/null
  done
  return 0
}

# Commit do inicio do turno gravado por esta sessao em <gitdir>/kit-turn-head, se ainda existe.
# Vazio sem marca, com marca de outra sessao ou commit sumido. Uso: kit_turn_mark <repo> <session_id>
kit_turn_mark() {
  local gd owner="" base=""
  [ -n "${2:-}" ] || return 0
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null | tr -d '\r')"
  [ -n "$gd" ] && [ -f "$gd/kit-turn-head" ] || return 0
  IFS=' ' read -r owner base <"$gd/kit-turn-head" || true
  [ -n "$base" ] && [ "$owner" = "$2" ] || return 0
  git -C "$1" cat-file -e "$base^{commit}" 2>/dev/null || return 0
  printf '%s' "$base"
}

# Base das linhas novas do turno: a marca do turno ou, sem ela, o HEAD. Vazio em repositorio sem
# commits. Uso: kit_turn_base <repo> <session_id>
kit_turn_base() {
  local b
  b="$(kit_turn_mark "$1" "${2:-}")"
  [ -n "$b" ] || b="$(git -C "$1" rev-parse --verify -q HEAD 2>/dev/null | tr -d '\r')"
  printf '%s' "$b"
}

# Linhas adicionadas desde <base> (working tree contra o commit; nao rastreado conta inteiro, binario
# fica de fora) como "caminho<TAB>linha<TAB>texto", caminho relativo ao repositorio. Os caminhos
# vem de dois arquivos, um por linha: rastreados e nao rastreados. Sem base, todos contam inteiros.
# Uso: kit_added_lines <repo> <base> <lista-rastreados> <lista-nao-rastreados>
kit_added_lines() {
  local repo="$1" base="$2"
  {
    if [ -n "$base" ]; then
      # Prefixos fixos: diff.mnemonicPrefix e diff.noprefix do usuario mudariam o "b/" do cabecalho.
      # Nome com espaco vem seguido de TAB na linha "+++".
      kit_path_batches "" git --literal-pathspecs -c core.quotepath=off -C "$repo" diff -U0 --no-color --no-ext-diff --no-renames \
        --src-prefix=a/ --dst-prefix=b/ "$base" -- <"$3" 2>/dev/null |
        awk '/^diff --git / { h = 0; f = ""; next }
          !h && /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); sub(/^b\//, "", f); next }
          /^@@ / { split($3, a, ","); n = substr(a[1], 2) + 0; h = 1; next }
          h && f != "" && f != "/dev/null" && /^\+/ { print f "\t" n "\t" substr($0, 2); n++ }'
      kit_whole_lines "$repo" <"$4"
    else
      cat "$4" "$3" | kit_whole_lines "$repo"
    fi
  } | tr -d '\r'
}

# Todas as linhas dos arquivos de texto lidos do stdin (um por linha, relativos a <repo>) como
# "caminho<TAB>linha<TAB>texto". Binario fica de fora. Uso: kit_whole_lines <repo> <lista
kit_whole_lines() {
  (
    cd "$1" 2>/dev/null || exit 0
    kit_path_batches "./" grep -Il '' -- 2>/dev/null | tr -d '\r' |
      kit_path_batches "" awk '{ f = FILENAME; sub(/^\.\//, "", f); print f "\t" FNR "\t" $0 }'
  )
}

# Roda o comando com os caminhos lidos do stdin (um por linha) acrescentados no fim, em lotes de ate
# ~8.000 caracteres: a linha de comando de um programa nativo do Windows (git.exe) nao passa de 32
# mil, e uma lista maior falha com "Argument list too long". <prefixo> entra antes de cada caminho.
# Uso: kit_path_batches <prefixo> comando [args...] <lista
kit_path_batches() {
  local pre="$1" p len=0
  local -a batch=()
  shift
  while IFS= read -r p <&3; do
    [ -n "$p" ] || continue
    if [ "${#batch[@]}" -gt 0 ] && [ $((len + ${#pre} + ${#p} + 3)) -gt 8000 ]; then
      "$@" ${batch[@]+"${batch[@]}"} </dev/null
      batch=()
      len=0
    fi
    batch+=("$pre$p")
    len=$((len + ${#pre} + ${#p} + 3))
  done 3<&0
  [ "${#batch[@]}" -eq 0 ] || "$@" ${batch[@]+"${batch[@]}"} </dev/null
  return 0
}

# Avisos de configuracao do kit.json da raiz e de cada repositorio, um por linha: JSON invalido,
# chave de verify_on_stop sem comando, verify_on_stop sem source_globs, comando "lint" fora do
# verify_on_stop e entrada de "repos" que nao e repositorio git.
# Uso: kit_config_notes <raiz> [repositorio...]
kit_config_notes() {
  local root="$1" d f rel k
  for d in "$@"; do
    f="$d/.claude/kit.json"
    [ -f "$f" ] || continue
    rel="$(kit_rel_to "$root" "$f")"
    if ! kit_json_ok "$f"; then
      echo "kit: $rel não é JSON válido; escrita nessa pasta fica bloqueada e o gate acusa até corrigir (jq . $rel mostra o erro)"
      continue
    fi
    while IFS= read -r k; do
      [ -n "$k" ] && echo "kit: $rel: verify_on_stop cita \"$k\", que não existe em commands; essa verificação não roda"
    done < <(jq -r "$KIT_JQ_CMD"' (.commands // {}) as $c | (.verify_on_stop // []) | if type == "array" then .[] | strings | select(($c[.] | cmd_run) == "") else empty end' "$f" 2>/dev/null | tr -d '\r')
    k="$(jq -r "$KIT_JQ_CMD"' (.commands // {}) as $c | select(((.source_globs // []) | length) == 0)
      | [(.verify_on_stop // []) | if type == "array" then .[] | strings else empty end | select(($c[.] | cmd_files | length) == 0)] as $s
      | if ($s | length) == 0 then empty
        elif ([(.verify_on_stop // [])[] | strings] | length) == ($s | length) then "nenhum comando"
        else "os comandos sem \"files\": " + ($s | join(", ")) end' "$f" 2>/dev/null | tr -d '\r')"
    [ -n "$k" ] && echo "kit: $rel: verify_on_stop sem source_globs; o gate não roda $k"
    if jq -e "$KIT_JQ_CMD"' ((.commands // {}).lint | cmd_run) != ""
      and ((.verify_on_stop // []) | if type == "array" then index("lint") == null else true end)' "$f" >/dev/null 2>&1; then
      echo "kit: $rel: commands tem \"lint\", mas ele não está em verify_on_stop; nenhum passo do kit roda o lint neste projeto (o /kit:init propõe como incluir)"
    fi
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      [ -e "$d/${k#./}/.git" ] || echo "kit: $rel: repos cita \"$k\", que não é repositório git; ignorado"
    done < <(jq -r '(.repos // []) | if type == "array" then .[] | strings else empty end' "$f" 2>/dev/null | tr -d '\r')
  done | awk '!seen[$0]++'
}

# Aviso de codemap desatualizado: procura docs/codemap.md com cabecalho "kit:map" na raiz e em cada
# repositorio e conta os commits desde o commit gravado. Limite em map.stale_after_commits do
# kit.json da raiz (padrao 50). Uso: kit_codemap_note <raiz> [repositorio...]
kit_codemap_note() {
  local root="$1" d f top commit n limit=50 v
  shift
  if [ -f "$root/.claude/kit.json" ]; then
    v="$(jq -r '(.map // {}).stale_after_commits // empty' "$root/.claude/kit.json" 2>/dev/null | tr -d '\r')"
    case "$v" in '' | *[!0-9]*) ;; *) limit="$v" ;; esac
  fi
  for d in "$root" "$@"; do
    f="$d/docs/codemap.md"
    [ -f "$f" ] || continue
    commit="$(head -n 5 "$f" | tr -d '\r' | grep -oE 'kit:map v[0-9]+ · [^ ]+ · [0-9a-f]{7,40}' | head -n 1 | awk '{ print $NF }')"
    [ -n "$commit" ] || continue
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
    [ -n "$top" ] || continue
    if ! git -C "$d" cat-file -e "$commit^{commit}" 2>/dev/null; then
      echo "kit: o commit do $(kit_rel_to "$root" "$f") ($commit) não está no histórico; rode /kit:map para remapear"
      continue
    fi
    n="$(git -C "$d" rev-list --count "$commit..HEAD" 2>/dev/null | tr -d '\r')"
    if [ -n "$n" ] && [ "$n" -gt "$limit" ]; then
      echo "kit: $(kit_rel_to "$root" "$f") está $n commits atrás (limite $limit); rode /kit:map --update"
    fi
  done
  return 0
}

# Raiz do kit.json mais proximo de $1 com bloco "notify" ligado (objeto). Vazio se ausente ou false.
kit_notify_root() {
  local r
  r="$(kit_kit_roots "$1" | head -n 1)"
  [ -n "$r" ] || return 0
  jq -e '(.notify // null) | type == "object"' "$r/.claude/kit.json" >/dev/null 2>&1 && printf '%s' "$r"
  return 0
}

# Le o bloco notify de $1/.claude/kit.json em KIT_NOTIFY_WAITING, KIT_NOTIFY_DONE, KIT_NOTIFY_MIN,
# KIT_NOTIFY_SOUND, KIT_NOTIFY_NTFY_ENV e KIT_NOTIFY_DISCORD_ENV. Chave ausente e desligada; sem
# "push", nenhum push; com "push", os nomes padrao das variaveis valem para o que faltar.
kit_notify_load() {
  local line
  line="$(jq -r '.notify as $n | (($n.push // null) | type == "object") as $p
    | [($n.waiting == true), ($n.done == true), ($n.done_min_seconds // 60), ($n.sound == true),
       (if $p then ($n.push.ntfy_topic_env // "KIT_NTFY_TOPIC") else "" end),
       (if $p then ($n.push.discord_webhook_env // "KIT_DISCORD_WEBHOOK") else "" end)]
    | map(tostring) | join("|")' "$1/.claude/kit.json" 2>/dev/null | tr -d '\r')"
  IFS='|' read -r KIT_NOTIFY_WAITING KIT_NOTIFY_DONE KIT_NOTIFY_MIN KIT_NOTIFY_SOUND KIT_NOTIFY_NTFY_ENV KIT_NOTIFY_DISCORD_ENV <<<"$line"
  case "${KIT_NOTIFY_MIN:-}" in '' | *[!0-9]*) KIT_NOTIFY_MIN=60 ;; esac
}

# Duracao em segundos como 45s, 3m07s ou 1h02m.
kit_duration() {
  local s="$1"
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"; fi
}

# Envia a notificacao pelo notify.sh --send com a config carregada por kit_notify_load. Em segundo
# plano e sem herdar stdout/stderr do hook, que termina sem esperar; com KIT_NOTIFY_DRY_RUN, roda
# na hora e o que seria executado vai para o stderr. Uso: kit_notify_send <titulo> <mensagem>
kit_notify_send() {
  local script
  script="$(dirname "${BASH_SOURCE[0]}")/notify.sh"
  if [ -n "${KIT_NOTIFY_DRY_RUN:-}" ]; then
    KIT_NOTIFY_TITLE="$1" KIT_NOTIFY_MSG="$2" KIT_NOTIFY_SOUND="$KIT_NOTIFY_SOUND" KIT_NOTIFY_NTFY_ENV="$KIT_NOTIFY_NTFY_ENV" \
      KIT_NOTIFY_DISCORD_ENV="$KIT_NOTIFY_DISCORD_ENV" "${BASH:-bash}" "$script" --send >&2
  else
    (KIT_NOTIFY_TITLE="$1" KIT_NOTIFY_MSG="$2" KIT_NOTIFY_SOUND="$KIT_NOTIFY_SOUND" KIT_NOTIFY_NTFY_ENV="$KIT_NOTIFY_NTFY_ENV" \
      KIT_NOTIFY_DISCORD_ENV="$KIT_NOTIFY_DISCORD_ENV" "${BASH:-bash}" "$script" --send </dev/null >/dev/null 2>&1 &)
  fi
  return 0
}

# UserPromptSubmit: marca o inicio do turno em <raiz>/.claude/state/turn-start (mtime = inicio,
# conteudo = session_id) quando notify.done esta ligado. Uso: kit_notify_turn_start <cwd> <session_id>
kit_notify_turn_start() {
  local root
  root="$(kit_notify_root "$1")"
  [ -n "$root" ] || return 0
  kit_notify_load "$root"
  [ "$KIT_NOTIFY_DONE" = "true" ] || return 0
  mkdir -p "$root/.claude/state" 2>/dev/null && printf '%s\n' "$2" >"$root/.claude/state/turn-start" 2>/dev/null
  return 0
}

# Fim de turno liberado pelo gate: notifica "concluido" se o turn-start e desta sessao e o turno
# durou ao menos notify.done_min_seconds. Consome o turn-start. Uso: kit_notify_done <cwd> <session_id>
kit_notify_done() {
  local root f owner start now dur name branch=""
  root="$(kit_notify_root "$1")"
  [ -n "$root" ] || return 0
  f="$root/.claude/state/turn-start"
  [ -f "$f" ] || return 0
  owner="$(head -n 1 "$f" 2>/dev/null | tr -d '\r')"
  [ -z "$owner" ] || [ -z "$2" ] || [ "$owner" = "$2" ] || return 0
  start="$(date -r "$f" +%s 2>/dev/null)"
  rm -f "$f"
  kit_notify_load "$root"
  [ "$KIT_NOTIFY_DONE" = "true" ] || return 0
  case "$start" in '' | *[!0-9]*) return 0 ;; esac
  now="$(date +%s)"
  dur=$((now - start))
  [ "$dur" -ge "$KIT_NOTIFY_MIN" ] || return 0
  name="${root##*/}"
  command -v git >/dev/null 2>&1 && branch="$(git -C "$root" branch --show-current 2>/dev/null | tr -d '\r')"
  kit_notify_send "Claude Code" "✅ $name${branch:+ ($branch)}: concluído em $(kit_duration "$dur")"
}
