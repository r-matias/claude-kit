#!/usr/bin/env bash
# PreToolUse/Edit|Write|MultiEdit|NotebookEdit: nega escrita em segredos, em guards.deny_write e em
# protected_paths do kit.json (este com excecao por guards.allow_write). Nome com sufixo .example,
# .sample, .template ou .dist nao e segredo.
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

ALLOW_HINT="Se este arquivo não é segredo, adicione o caminho em guards.allow_write no .claude/kit.json."
EXAMPLE_HINT="Arquivo de exemplo: use o sufixo .example, .sample, .template ou .dist."

check_path() {
  local file="$1" base cmp root rel glob write message allowed=0 broad=""
  base="$(kit_fold "${file##*/}")"
  if ! kit_is_example_name "$base"; then
    case "$base" in
      .env | .env.*) kit_deny_pretool "kit: escrita em arquivo de segredo (${file##*/}) bloqueada. $EXAMPLE_HINT" ;;
      *.pem | *.key) kit_deny_pretool "kit: escrita em chave/certificado (${file##*/}) bloqueada." ;;
    esac
  fi
  case "/$(kit_fold "$file")" in
    */secrets/*) kit_deny_pretool "kit: escrita em diretorio secrets/ bloqueada." ;;
  esac

  # Valem os guards e o protected_paths do kit.json mais proximo e dos kit.json acima dele (pasta-mae).
  # guards.deny_write bloqueia sempre; guards.allow_write (sem glob largo nem segredo) libera o protected_paths.
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    kit_use_root "$root"
    rel="$(kit_rel "$file")"
    cmp="$(kit_fold "$rel")"
    while IFS=$'	' read -r glob message; do
      [ -n "$glob" ] || continue
      glob_match "$(kit_fold "$glob")" "$cmp" || continue
      [ -n "$message" ] && kit_deny_pretool "kit: $rel é bloqueado. $message"
      kit_deny_pretool "kit: $rel casa guards.deny_write ($glob) do kit.json."
    done < <(kit_guard_deny_entries)
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      kit_glob_secret "$glob" && continue
      glob_match "$(kit_fold "$glob")" "$cmp" || continue
      if kit_glob_broad "$glob"; then broad="$glob"; continue; fi
      allowed=1
    done < <(kit_guard_allow_entries)
  done < <(kit_kit_roots "$file")
  [ "$allowed" -eq 1 ] && return 0
  if [ -n "$broad" ]; then
    ALLOW_HINT="guards.allow_write ignora \"$broad\": glob largo demais; liste o caminho exato."
  fi

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    kit_use_root "$root"
    rel="$(kit_rel "$file")"
    cmp="$(kit_fold "$rel")"
    while IFS=$'	' read -r glob write message; do
      [ -n "$glob" ] || continue
      glob_match "$(kit_fold "$glob")" "$cmp" || continue
      [ "$NEW_FILE" -eq 1 ] && [ "$write" != "deny" ] && continue
      if [ -n "$message" ]; then
        kit_deny_pretool "kit: $rel é protegido. $message $ALLOW_HINT"
      fi
      if [ "$NEW_FILE" -eq 1 ]; then
        kit_deny_pretool "kit: $rel casa protected_paths ($glob) com write: deny no kit.json. Nem arquivo novo pode ser criado aqui. $ALLOW_HINT"
      fi
      kit_deny_pretool "kit: $rel casa protected_paths ($glob) do kit.json. Gere um arquivo novo ou edite manualmente. $ALLOW_HINT"
    done < <(kit_protected_entries)
  done < <(kit_kit_roots "$file")
  return 0
}

check_path "$FILE"
REAL="$(real_path "$FILE")"
[ "$(kit_fold "$REAL")" != "$(kit_fold "$FILE")" ] && check_path "$REAL"

exit 0
