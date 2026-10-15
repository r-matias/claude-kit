#!/usr/bin/env bash
# PreToolUse/Edit|Write|MultiEdit|NotebookEdit: nega escrita em segredos e em protected_paths do kit.json.
# O caminho e normalizado antes de casar (.., //, relativo ao cwd) e, se for symlink, o alvo final
# tambem e checado. Em Windows e macOS a comparacao ignora maiusculas. Erro inesperado bloqueia.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_guard_fail_closed
kit_require_jq_strict
kit_read_input

TOOL="$(kit_field '.tool_name')"
RAW="$(kit_field '.tool_input.file_path')"
[ -n "$RAW" ] || RAW="$(kit_field '.tool_input.notebook_path')"
[ -n "$RAW" ] || exit 0

CWD="$(kit_cwd)"
KIT_CEILING="$CWD"
PLATFORM="$(kit_platform)"

# Windows ignora espaco e ponto no fim de cada nome e trata "nome:fluxo" (ADS) como o proprio nome.
win_clean() {
  printf '%s' "$1" | sed -E 's#^([A-Za-z]):#\1|#; s#:[^/]*##g; s#^([A-Za-z])\|#\1:#; s#([^/.])[. ]+(/|$)#\1\2#g'
}

FILE="${RAW//\\//}"
[ "$PLATFORM" = "windows" ] && FILE="$(win_clean "$FILE")"
FILE="$(kit_path_norm "$FILE" "$CWD")"

# Alvo final de um symlink (encadeado ate 20 niveis) e pasta real do primeiro ancestral existente.
real_path() {
  local p="$1" t n=0 dir rest="" real
  while [ -L "$p" ] && [ "$n" -lt 20 ]; do
    t="$(readlink "$p" 2>/dev/null)" || break
    p="$(kit_path_norm "$t" "$(dirname "$p")")"
    n=$((n + 1))
  done
  dir="$(dirname "$p")"
  while [ ! -d "$dir" ]; do
    rest="/${dir##*/}$rest"
    [ "$(dirname "$dir")" = "$dir" ] && break
    dir="$(dirname "$dir")"
  done
  real="$(cd -P "$dir" 2>/dev/null && pwd -P)" || real=""
  if [ -n "$real" ] && command -v cygpath >/dev/null 2>&1; then real="$(cygpath -m "$real" 2>/dev/null)"; fi
  [ -n "$real" ] || real="$dir"
  printf '%s' "$(kit_path_norm "${real%/}$rest/${p##*/}" /)"
}

# Write de arquivo novo so e negado por item com "write": "deny"; Write sobre arquivo existente conta como edicao.
NEW_FILE=0
if [ "$TOOL" = "Write" ] && [ ! -e "$FILE" ]; then NEW_FILE=1; fi

check_path() {
  local file="$1" base cmp root rel glob write message
  base="$(kit_fold "${file##*/}")"
  case "$base" in
    .env.example | .env.sample | .env.template | .env.dist) ;;
    .env | .env.*) kit_deny_pretool "kit: escrita em arquivo de segredo (${file##*/}) bloqueada." ;;
    *.pem | *.key) kit_deny_pretool "kit: escrita em chave/certificado (${file##*/}) bloqueada." ;;
  esac
  case "/$(kit_fold "$file")" in
    */secrets/*) kit_deny_pretool "kit: escrita em diretorio secrets/ bloqueada." ;;
  esac

  # Vale o protected_paths do kit.json mais proximo e o dos kit.json acima dele (pasta-mae).
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    kit_use_root "$root"
    rel="$(kit_rel "$file")"
    cmp="$(kit_fold "$rel")"
    while IFS=$'\t' read -r glob write message; do
      [ -n "$glob" ] || continue
      glob_match "$(kit_fold "$glob")" "$cmp" || continue
      [ "$NEW_FILE" -eq 1 ] && [ "$write" != "deny" ] && continue
      if [ -n "$message" ]; then
        kit_deny_pretool "kit: $rel é protegido. $message"
      fi
      if [ "$NEW_FILE" -eq 1 ]; then
        kit_deny_pretool "kit: $rel casa protected_paths ($glob) com write: deny no kit.json. Nem arquivo novo pode ser criado aqui."
      fi
      kit_deny_pretool "kit: $rel casa protected_paths ($glob) do kit.json. Gere um arquivo novo ou edite manualmente."
    done < <(kit_protected_entries)
  done < <(kit_kit_roots "$file")
  return 0
}

check_path "$FILE"
REAL="$(real_path "$FILE")"
[ "$(kit_fold "$REAL")" != "$(kit_fold "$FILE")" ] && check_path "$REAL"

exit 0
