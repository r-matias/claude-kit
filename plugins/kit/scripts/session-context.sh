#!/usr/bin/env bash
# SessionStart: injeta branch, arquivos alterados de cada repositorio, planos ativos e, apos
# compactacao, o snapshot salvo pelo pre-compact.sh. Avisa se o docs/codemap.md do /kit:map esta desatualizado.
# UserPromptSubmit (--plan-only): so a linha de planos ativos, se inject_plan_on_prompt for true.
# Sem jq, git ou com Claude Code abaixo da versao minima, avisa no inicio da sessao com o comando de correcao.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "${1:-}" = "--plan-only" ]; then
  kit_require_jq
  NOTES=""
else
  NOTES="$(kit_dependency_notes)"
  # Sem jq os guardas bloqueiam tudo, menos a instalacao do jq: o aviso vai ao usuario
  # (systemMessage) e ao Claude (additionalContext), em JSON montado sem jq.
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
      "$(kit_json_str "$(kit_jq_missing_msg)")" "$(kit_json_str "$NOTES")"
    exit 0
  fi
fi
kit_read_input

CWD="$(kit_cwd)"
ROOT="$(kit_session_root "$CWD")"
SID="$(kit_field '.session_id')"

plans_line() {
  local line="" d t f
  while IFS=$'\t' read -r d t f; do
    [ -n "$f" ] || continue
    line+="${line:+; }$(kit_rel_to "$ROOT" "$f") ($d/$t)"
  done < <(kit_active_plans "$ROOT" ${REPOS[@]+"${REPOS[@]}"} | head -n 3)
  printf '%s' "$line"
}

REPOS=()
command -v git >/dev/null 2>&1 && while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(kit_repos "$CWD" "$SID")

if [ "${1:-}" = "--plan-only" ]; then
  [ -f "$ROOT/.claude/kit.json" ] || exit 0
  [ "$(jq -r '.inject_plan_on_prompt // false' "$ROOT/.claude/kit.json" 2>/dev/null | tr -d '\r')" = "true" ] || exit 0
  line="$(plans_line)"
  [ -n "$line" ] && echo "Plano ativo do kit: $line"
  exit 0
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
  [ -n "$NOTES" ] && printf '%s\n' "$NOTES"
  exit 0
fi

echo "## Contexto do kit"
[ -n "$NOTES" ] && printf '%s\n' "$NOTES"
MAPNOTE="$(kit_codemap_note "$ROOT" ${REPOS[@]+"${REPOS[@]}"})"
[ -n "$MAPNOTE" ] && printf '%s\n' "$MAPNOTE"
if [ "${#REPOS[@]}" -eq 1 ]; then
  BRANCH="$(git -C "${REPOS[0]}" branch --show-current 2>/dev/null | tr -d '\r')"
  echo "Branch: ${BRANCH:-(detached)}"
  STATUS="$(git -C "${REPOS[0]}" status --short 2>/dev/null | tr -d '\r' | head -n 30)"
  if [ -n "$STATUS" ]; then
    echo
    echo "Alterados (git status --short, ate 30):"
    printf '%s\n' "$STATUS"
  fi
else
  for repo in ${REPOS[@]+"${REPOS[@]}"}; do
    name="$(kit_rel_to "$CWD" "$repo")"
    [ "$name" = "." ] && name="${repo##*/}"
    BRANCH="$(git -C "$repo" branch --show-current 2>/dev/null | tr -d '\r')"
    echo
    echo "### $name (branch: ${BRANCH:-detached})"
    STATUS="$(git -C "$repo" status --short 2>/dev/null | tr -d '\r' | head -n 15)"
    if [ -n "$STATUS" ]; then printf '%s\n' "$STATUS"; else echo "(sem alterações)"; fi
  done
fi

PLANS="$(kit_active_plans "$ROOT" ${REPOS[@]+"${REPOS[@]}"} | head -n 3)"
if [ -n "$PLANS" ]; then
  echo
  echo "Planos ativos (feitas/total):"
  while IFS=$'\t' read -r d t f; do
    echo "- $(kit_rel_to "$ROOT" "$f") ($d/$t)"
  done <<<"$PLANS"
  LATEST="$(printf '%s\n' "$PLANS" | head -n 1 | cut -f3)"
  echo
  echo "Tarefas pendentes de $(kit_rel_to "$ROOT" "$LATEST"):"
  grep -E '^[[:space:]]*[-*] \[ \]' "$LATEST" | tr -d '\r' | head -n 40
fi

SNAP="$ROOT/.claude/state/kit-snapshot.md"
if [ "$(kit_field '.source')" = "compact" ] && [ -f "$SNAP" ] && [ -n "$(find "$SNAP" -mmin -120 2>/dev/null)" ]; then
  echo
  echo "## Estado salvo antes da compactação"
  tr -d '\r' <"$SNAP"
fi
exit 0
