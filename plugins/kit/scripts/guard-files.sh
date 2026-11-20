#!/usr/bin/env bash
# PreToolUse/Edit|Write|MultiEdit|NotebookEdit: nega escrita em segredos, em guards.deny_write e em
# protected_paths do kit.json (este com excecao por guards.allow_write). Nome com sufixo .example,
# .sample, .template ou .dist nao e segredo.
# O caminho e normalizado antes de casar (.., //, relativo ao cwd) e, se for symlink, o alvo final
# tambem e checado. Em Windows e macOS a comparacao ignora maiusculas. Erro inesperado bloqueia.
# As regras ficam no lib.sh (kit_check_write), as mesmas da escrita pelo shell no guard-bash.
# Roda a cada edicao, com limite de tempo: a entrada e lida num jq so, cada kit.json em outro, e o
# casamento por regra nao cria processo (no Git Bash cada um custa dezenas de milissegundos).
set -u
KIT_HERE="${BASH_SOURCE[0]%/*}"
[ "$KIT_HERE" != "${BASH_SOURCE[0]}" ] || KIT_HERE="."
. "$KIT_HERE/lib.sh"
kit_guard_fail_closed
kit_require_jq_strict
kit_read_input

TOOL=""
RAW=""
NOTEBOOK=""
CWD=""
if ! kit_fields TOOL '.tool_name' RAW '.tool_input.file_path' NOTEBOOK '.tool_input.notebook_path' CWD '.cwd'; then
  echo "kit: entrada do hook vazia ou ilegível; chamada bloqueada" >&2
  exit 2
fi
[ -n "$RAW" ] || RAW="$NOTEBOOK"
[ -n "$RAW" ] || exit 0

[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
CWD="${CWD//\\//}"
KIT_CEILING="$CWD"
# No shell principal: os subshells herdam o sistema ja lido.
kit_case_insensitive || true

FILE="${RAW//\\//}"
case "$KIT_UNAME" in MINGW* | MSYS* | CYGWIN*) FILE="$(kit_win_clean "$FILE")" ;; esac
FILE="$(kit_path_norm "$FILE" "$CWD")"

# Write de arquivo novo so e negado por item com "write": "deny"; Write sobre arquivo existente conta como edicao.
KIT_NEW_FILE=0
if [ "$TOOL" = "Write" ] && [ ! -e "$FILE" ]; then KIT_NEW_FILE=1; fi

kit_check_write_path "$FILE"

exit 0
