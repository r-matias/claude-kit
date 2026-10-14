#!/usr/bin/env bash
# PreToolUse/Edit|Write: nega escrita em segredos e em protected_paths do kit.json.
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

KIT_CEILING="$(kit_cwd)"

# Write de arquivo novo so e negado por item com "write": "deny"; Write sobre arquivo existente conta como edicao.
NEW_FILE=0
if [ "$TOOL" = "Write" ] && [ ! -e "$FILE" ]; then NEW_FILE=1; fi

# Vale o protected_paths do kit.json mais proximo e o dos kit.json acima dele (pasta-mae).
while IFS= read -r root; do
  [ -n "$root" ] || continue
  kit_use_root "$root"
  REL="$(kit_rel "$FILE")"
  while IFS=$'\t' read -r glob write message; do
    [ -n "$glob" ] || continue
    glob_match "$glob" "$REL" || continue
    [ "$NEW_FILE" -eq 1 ] && [ "$write" != "deny" ] && continue
    if [ -n "$message" ]; then
      kit_deny_pretool "kit: $REL é protegido. $message"
    fi
    if [ "$NEW_FILE" -eq 1 ]; then
      kit_deny_pretool "kit: $REL casa protected_paths ($glob) com write: deny no kit.json. Nem arquivo novo pode ser criado aqui."
    fi
    kit_deny_pretool "kit: $REL casa protected_paths ($glob) do kit.json. Gere um arquivo novo ou edite manualmente."
  done < <(kit_protected_entries)
done < <(kit_kit_roots "$FILE")

exit 0
