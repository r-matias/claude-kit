#!/usr/bin/env bash
# Funcoes comuns dos hooks do kit. Dependencias: bash, jq, git.

KIT_INPUT=""
KIT_JSON=""
KIT_ROOT=""

kit_require_jq() {
  command -v jq >/dev/null 2>&1 || exit 0
}

# Guardas de seguranca nao podem liberar por falta de dependencia: sem jq, bloqueiam.
kit_require_jq_strict() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "kit: jq não encontrado; instale o jq" >&2
    exit 2
  fi
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

# Planos ativos: docs/specs/**/PLAN.md na raiz e em cada repositorio, mais os .md de "plan_dirs"
# do kit.json da raiz; modificados nos ultimos 14 dias e com tarefa "- [ ]" pendente.
# Saida: "feitas<TAB>total<TAB>caminho", do mais recente para o mais antigo.
# Uso: kit_active_plans <raiz> [repositorio...]
kit_active_plans() {
  local root="$1" d f done total
  shift
  {
    for d in "$root" "$@"; do
      [ -d "$d/docs/specs" ] && find "$d/docs/specs" -name PLAN.md -type f -mtime -14 2>/dev/null
    done
    if [ -f "$root/.claude/kit.json" ]; then
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ -d "$root/${d#./}" ] && find "$root/${d#./}" -maxdepth 2 -name '*.md' -type f -mtime -14 2>/dev/null
      done < <(jq -r '(.plan_dirs // [])[]' "$root/.claude/kit.json" 2>/dev/null | tr -d '\r')
    fi
  } | awk '!seen[$0]++' | while IFS= read -r f; do
    grep -qE '^[[:space:]]*[-*] \[ \]' "$f" || continue
    done="$(grep -cE '^[[:space:]]*[-*] \[[xX]\]' "$f")"
    total="$(grep -cE '^[[:space:]]*[-*] \[[ xX]\]' "$f")"
    printf '%s\t%s\t%s\t%s\n' "$(date -r "$f" +%s 2>/dev/null || echo 0)" "$done" "$total" "$f"
  done | sort -t$'\t' -k1,1nr | cut -f2-
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
# mensagem) ou objeto {glob, message, write: allow|deny}.
kit_protected_entries() {
  [ -n "$KIT_JSON" ] || return 0
  jq -r '(.protected_paths // [])[] |
    if type == "string" then [., "allow", ""]
    elif type == "object" then [(.glob // ""), (.write // "allow"), (.message // "")]
    else empty end | @tsv' "$KIT_JSON" 2>/dev/null | tr -d '\r'
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
  local cmd="$1" files="$2"
  printf '%s' "${cmd//\{files\}/$files}"
}

# Executa um comando do manifesto na raiz do kit. Saida combinada vai para o arquivo $2.
kit_run() {
  (cd "$KIT_ROOT" && bash -c "$1") >"$2" 2>&1
}

kit_deny_pretool() {
  jq -cn --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}
