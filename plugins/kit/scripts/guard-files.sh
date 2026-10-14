#!/usr/bin/env bash
# PreToolUse/Edit|Write: nega escrita em segredos e Edit em protected_paths do kit.json.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq_strict
kit_read_input

TOOL="$(kit_field '.tool_name')"
FILE="$(kit_norm_path "$(kit_field '.tool_input.file_path')")"
[ -n "$FILE" ] || exit 0

BASE="${FILE##*/}"
case "$BASE" in
  .env.example | .env.sample | .env.template | .env.dist) ;;
  .env | .env.*) kit_deny_pretool "kit: escrita em arquivo de segredo ($BASE) bloqueada." ;;
  *.pem | *.key) kit_deny_pretool "kit: escrita em chave/certificado ($BASE) bloqueada." ;;
esac
case "/$FILE" in
  */secrets/*) kit_deny_pretool "kit: escrita em diretorio secrets/ bloqueada." ;;
esac

find_kit_json "$FILE" || exit 0

# Write de arquivo novo e permitido; Write sobre arquivo existente conta como edicao.
if [ "$TOOL" = "Write" ] && [ ! -e "$FILE" ]; then
  exit 0
fi

REL="$(kit_rel "$FILE")"
while IFS= read -r glob; do
  [ -n "$glob" ] || continue
  if glob_match "$glob" "$REL"; then
    kit_deny_pretool "kit: $REL casa protected_paths ($glob) do kit.json. Gere um arquivo novo ou edite manualmente."
  fi
done < <(kit_list protected_paths)

exit 0
