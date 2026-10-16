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
  printf '%s/%s' "$prefix" "${stack[@]+"${stack[*]}"}"
}

# Sistema pelo uname; sem uname no PATH, pelo $OSTYPE do proprio bash.
kit_uname() {
  local u
  u="$(uname -s 2>/dev/null)"
  if [ -z "$u" ]; then
    case "${OSTYPE:-}" in
      msys* | cygwin* | win*) u="MINGW" ;;
      darwin*) u="Darwin" ;;
      *) u="Linux" ;;
    esac
  fi
  printf '%s' "$u"
}

# Verdadeiro em Windows e macOS, onde o sistema de arquivos padrao nao diferencia maiusculas.
KIT_CI=""
kit_case_insensitive() {
  if [ -z "$KIT_CI" ]; then
    case "$(kit_uname)" in MINGW* | MSYS* | CYGWIN* | Darwin) KIT_CI=1 ;; *) KIT_CI=0 ;; esac
  fi
  [ "$KIT_CI" = "1" ]
}

# Texto em minusculas onde o sistema de arquivos nao diferencia maiusculas; igual nos demais.
kit_fold() {
  if kit_case_insensitive; then printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; else printf '%s' "$1"; fi
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
  start="$(kit_norm_path "$1")"
  [ -n "$start" ] || return 0
  if [ -d "$start" ]; then dir="$start"; else dir="$(dirname "$start")"; fi
  while [ -n "$dir" ] && [ ! -d "$dir" ]; do
    parent="$(dirname "$dir")"
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
    parent="$(dirname "$dir")"
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
# do kit.json do cwd. Um por linha, caminho absoluto. Cache por session_id em $TMPDIR.
kit_repos() {
  local cwd="$1" sid="${2:-}" own="" sig cache d list=""
  local tmp="${TMPDIR:-${TMP:-/tmp}}"
  if [ -f "$cwd/.claude/kit.json" ]; then sig="$cwd|$(cksum <"$cwd/.claude/kit.json")"; else sig="$cwd|none"; fi
  if [ -n "$sid" ]; then
    cache="$tmp/kit-repos-${sid//[^A-Za-z0-9_-]/_}"
    if [ -f "$cache" ] && [ "$(head -n 1 "$cache")" = "$sig" ]; then
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
# .md de "plan_dirs" do kit.json da raiz, filtrados pelo -mtime do find ($1: -14 ou +14).
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

# Planos parados: tarefa pendente e mais de 14 dias sem mudanca. Mesma saida de kit_plans_by_age.
# Uso: kit_stale_plans <raiz> [repositorio...]
kit_stale_plans() {
  kit_plans_by_age +14 "$@"
}

# Caminho de $2 relativo a $1 (ou o proprio $2 se estiver fora).
kit_rel_to() {
  if [ "$2" = "$1" ]; then printf '.'; return 0; fi
  if [ "${2#"$1"/}" != "$2" ]; then printf '%s' "${2#"$1"/}"; else printf '%s' "$2"; fi
}

# Valor de commands.<chave> no kit.json encontrado. Vazio se ausente.
kit_cmd() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r --arg k "$1" '.commands[$k] // empty' "$KIT_JSON" 2>/dev/null | tr -d '\r'
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

# Nome de arquivo de exemplo: termina em .example, .sample, .template ou .dist.
kit_is_example_name() {
  case "$(kit_fold "${1##*/}")" in *.example | *.sample | *.template | *.dist) return 0 ;; esac
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
  g="$(kit_fold "${1//\\//}")"
  case "/$g/" in */secrets/* | */keys/*) return 0 ;; esac
  base="${g##*/}"
  kit_is_example_name "$base" && return 1
  case "$base" in .env | .env.* | *.pem | *.key) return 0 ;; esac
  return 1
}

# Chaves folha de um JSON achatadas com ".", uma por linha, ordenadas. Retorna 1 se o JSON for invalido.
kit_json_keys() {
  local out
  out="$(jq -r '[paths(scalars) | map(tostring) | join(".")] | .[]' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | tr -d '\r' | sed '/^$/d' | LC_ALL=C sort -u
}

# Converte glob (**, *, ?, {a,b}) em regex ERE ancorada.
glob_to_regex() {
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
  printf '^%s$' "$out"
}

# Uso: glob_match <glob> <caminho-relativo>. Glob sem "/" tambem casa pelo nome do arquivo.
glob_match() {
  local re
  re="$(glob_to_regex "$1")"
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
    spec+="$(glob_to_regex "$g")"$'\n'
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
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
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

kit_deny_pretool() {
  jq -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}' ||
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
  case "$(kit_uname)" in
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    Darwin) echo macos ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    *) echo linux ;;
  esac
}

# Comando de instalacao de uma dependencia (jq, git, bash, claude, bwrap, socat) na plataforma dada.
kit_install_hint() {
  case "$1" in
    claude) echo "claude update"; return 0 ;;
  esac
  case "$2:$1" in
    *:bwrap) echo "sudo apt install bubblewrap" ;;
    *:socat) echo "sudo apt install socat" ;;
    windows:jq) echo "winget install jqlang.jq" ;;
    windows:*) echo "winget install Git.Git" ;;
    macos:*) echo "brew install $1" ;;
    *) echo "sudo apt install $1" ;;
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
      return 0
    fi
    n="$(git -C "$d" rev-list --count "$commit..HEAD" 2>/dev/null | tr -d '\r')"
    if [ -n "$n" ] && [ "$n" -gt "$limit" ]; then
      echo "kit: $(kit_rel_to "$root" "$f") está $n commits atrás (limite $limit); rode /kit:map --update"
    fi
    return 0
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
