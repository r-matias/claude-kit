#!/usr/bin/env bash
# PostToolUse/Edit|Write: regras coupled_changes com level "warn" cujo "when" casa com o arquivo
# editado, e regras diff_deny com level "warn" com o padrao numa linha nova do arquivo, viram
# contexto para o Claude (additionalContext). Nunca bloqueia.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

FILE="$(kit_norm_path "$(kit_field '.tool_input.file_path')")"
[ -n "$FILE" ] || exit 0
KIT_CEILING="$(kit_cwd)"
SID="$(kit_field '.session_id')"
TMPBASE="${TMPDIR:-${TMP:-/tmp}}"
SEEN_ID="${SID:-sem-sessao}"
# So o id da sessao e saneado: o TEMP pode ter espaco ou ~ (C:\Users\RUNNER~1) e precisa ficar intacto.
SEEN="$TMPBASE/kit-advise-${SEEN_ID//[^A-Za-z0-9_.-]/_}"

# 0 se o caminho casa algum glob de uma lista de regra. Uso: rule_hit <campo-raiz> <indice> <campo> <caminho>
rule_hit() {
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    glob_match "$(kit_fold "$g")" "$(kit_fold "$4")" && return 0
  done < <(kit_rule_list "$1" "$2" "$3")
  return 1
}

# Linhas adicionadas no turno do arquivo editado, "linha<TAB>texto", em $TMPD/added. Calculado uma
# vez. Rastreado: diff contra a base do turno; nao rastreado: o arquivo inteiro; fora de git: nada.
TMPD=""
added_lines() {
  local dir top tracked base
  [ -z "$TMPD" ] || return 0
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT
  : >"$TMPD/added"
  [ -f "$FILE" ] || return 0
  dir="${FILE%/*}"
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
  [ -n "$top" ] || return 0
  tracked="$(git --literal-pathspecs -c core.quotepath=off -C "$dir" ls-files --full-name -- "${FILE##*/}" 2>/dev/null | tr -d '\r' | head -n 1)"
  if [ -n "$tracked" ]; then
    printf '%s\n' "$tracked" >"$TMPD/t"
    : >"$TMPD/u"
    base="$(kit_turn_base "$top" "$SID")"
    kit_added_lines "$top" "$base" "$TMPD/t" "$TMPD/u" | cut -f2- >"$TMPD/added"
  elif grep -Iq '' "$FILE" 2>/dev/null; then
    tr -d '\r' <"$FILE" | awk '{ print NR "\t" $0 }' >"$TMPD/added"
  fi
}

NOTES=()
while IFS= read -r root; do
  [ -n "$root" ] || continue
  kit_use_root "$root"
  REL="$(kit_rel "$FILE")"
  n="$(kit_rule_count coupled_changes)"
  for ((i = 0; i < ${n:-0}; i++)); do
    [ "$(kit_rule_str coupled_changes "$i" level block)" = "warn" ] || continue
    rule_hit coupled_changes "$i" when "$REL" || continue
    # O arquivo editado ja e o par (casa "require"): nada a lembrar.
    rule_hit coupled_changes "$i" require "$REL" && continue

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

  [ "$REL" = ".claude/kit.json" ] && continue
  n="$(kit_rule_count diff_deny)"
  for ((i = 0; i < ${n:-0}; i++)); do
    [ "$(kit_rule_str diff_deny "$i" level block)" = "warn" ] || continue
    pattern="$(kit_rule_str diff_deny "$i" pattern "")"
    [ -n "$pattern" ] || continue
    if [ -n "$(kit_rule_list diff_deny "$i" files | head -n 1)" ]; then
      rule_hit diff_deny "$i" files "$REL" || continue
    fi
    added_lines
    [ -s "$TMPD/added" ] || continue
    cut -f2- "$TMPD/added" >"$TMPD/text"
    lines="$(grep -nE -- "$pattern" "$TMPD/text" 2>/dev/null | cut -d: -f1 |
      awk 'NR == FNR { n[NR] = $1; next } { print n[$1] }' "$TMPD/added" - | paste -sd ',' - | sed 's/,/, /g')"
    [ -n "$lines" ] || continue

    # Mesmas linhas ja avisadas nesta sessao nao repetem; linha nova com o padrao avisa de novo. A
    # chave e o texto das linhas, nao o numero: edicao acima delas desloca o numero e nao e novidade.
    key="$root|diff_deny|$i|$REL|$(grep -E -- "$pattern" "$TMPD/text" 2>/dev/null | cksum)"
    if [ -f "$SEEN" ] && grep -qxF -- "$key" "$SEEN"; then continue; fi
    printf '%s\n' "$key" >>"$SEEN" 2>/dev/null

    msg="$(kit_rule_str diff_deny "$i" message "Padrão proibido em linha nova.")"
    NOTES+=("[kit] $msg | editado: $REL | linhas novas: $lines")
  done
done < <(kit_kit_roots "$FILE")

[ "${#NOTES[@]}" -gt 0 ] || exit 0
jq -cn --arg c "$(printf '%s\n' ${NOTES[@]+"${NOTES[@]}"})" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: ($c | rtrimstr("\n"))}}'
exit 0
