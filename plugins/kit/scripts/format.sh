#!/usr/bin/env bash
# PostToolUse/Edit|Write: roda o formatter do primeiro glob de "format" que casar com o arquivo.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

FILE="$(kit_norm_path "$(kit_field '.tool_input.file_path')")"
[ -n "$FILE" ] && [ -f "$FILE" ] || exit 0
find_kit_json "$FILE" || exit 0

REL="$(kit_rel "$FILE")"
CMD=""
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  if glob_match "$glob" "$REL"; then
    CMD="$(jq -r --arg g "$glob" '.format[$g] // empty' "$KIT_JSON" | tr -d '\r')"
    break
  fi
done < <(jq -r '(.format // {}) | keys_unsorted[]' "$KIT_JSON" 2>/dev/null | tr -d '\r')

[ -n "$CMD" ] || exit 0
CMD="$(kit_subst_files "$CMD" "$(kit_quote "$REL")")"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
if ! kit_run "$CMD" "$OUT"; then
  {
    echo "kit format: falhou em $REL"
    echo "comando: $CMD"
    tail -n 30 "$OUT"
  } >&2
  exit 2
fi
exit 0
