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

# Sobe a partir de um arquivo ou diretorio ate a raiz do git procurando .claude/kit.json.
# Define KIT_JSON e KIT_ROOT. Retorna 1 se nao encontrar.
find_kit_json() {
  local start dir parent
  start="$(kit_norm_path "$1")"
  [ -n "$start" ] || return 1
  if [ -d "$start" ]; then dir="$start"; else dir="$(dirname "$start")"; fi
  while [ -n "$dir" ] && [ ! -d "$dir" ]; do
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && return 1
    dir="$parent"
  done
  while :; do
    if [ -f "$dir/.claude/kit.json" ]; then
      KIT_ROOT="$dir"
      KIT_JSON="$dir/.claude/kit.json"
      return 0
    fi
    [ -e "$dir/.git" ] && return 1
    parent="$(dirname "$dir")"
    if [ "$parent" = "$dir" ] || [ "$parent" = "." ]; then return 1; fi
    dir="$parent"
  done
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
