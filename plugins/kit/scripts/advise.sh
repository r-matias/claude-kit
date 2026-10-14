#!/usr/bin/env bash
# PostToolUse/Edit|Write: regras coupled_changes com level "warn" cujo "when" casa com o arquivo
# editado viram contexto para o Claude (additionalContext). Nunca bloqueia.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

FILE="$(kit_norm_path "$(kit_field '.tool_input.file_path')")"
[ -n "$FILE" ] || exit 0
KIT_CEILING="$(kit_cwd)"
SID="$(kit_field '.session_id')"
TMPBASE="${TMPDIR:-${TMP:-/tmp}}"
SEEN="$TMPBASE/kit-advise-${SID:-sem-sessao}"
SEEN="${SEEN//[^A-Za-z0-9_.\/:-]/_}"

NOTES=()
while IFS= read -r root; do
  [ -n "$root" ] || continue
  kit_use_root "$root"
  REL="$(kit_rel "$FILE")"
  n="$(kit_rule_count coupled_changes)"
  for ((i = 0; i < ${n:-0}; i++)); do
    [ "$(kit_rule_str coupled_changes "$i" level block)" = "warn" ] || continue
    hit=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      if glob_match "$g" "$REL"; then hit=1; break; fi
    done < <(kit_rule_list coupled_changes "$i" when)
    [ "$hit" -eq 1 ] || continue

    key="$root|$i|$REL"
    if [ -f "$SEEN" ] && grep -qxF -- "$key" "$SEEN"; then continue; fi
    printf '%s\n' "$key" >>"$SEEN" 2>/dev/null

    msg="$(kit_rule_str coupled_changes "$i" message "Arquivos acoplados costumam mudar juntos.")"
    req="$(kit_rule_list coupled_changes "$i" require | paste -sd ',' - | sed 's/,/, /g')"
    hint="$(kit_rule_str coupled_changes "$i" hint "")"
    note="[kit] $msg | verificar: $req | editado: $REL"
    [ -n "$hint" ] && note+=" | dica: $hint"
    NOTES+=("$note")
  done
done < <(kit_kit_roots "$FILE")

[ "${#NOTES[@]}" -gt 0 ] || exit 0
jq -cn --arg c "$(printf '%s\n' "${NOTES[@]}")" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ($c | rtrimstr("\n"))}}'
exit 0
