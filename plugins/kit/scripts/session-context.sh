#!/usr/bin/env bash
# SessionStart: injeta branch, arquivos alterados de cada repositorio, planos ativos e, apos
# compactacao, o snapshot salvo pelo pre-compact.sh.
# UserPromptSubmit (--plan-only): so a linha de planos ativos, se inject_plan_on_prompt for true.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

CWD="$(kit_cwd)"
ROOT="$(kit_session_root "$CWD")"
SID="$(kit_field '.session_id')"

plans_line() {
  local line="" d t f
  while IFS=$'\t' read -r d t f; do
    [ -n "$f" ] || continue
    line+="${line:+; }$(kit_rel_to "$ROOT" "$f") ($d/$t)"
  done < <(kit_active_plans "$ROOT" "${REPOS[@]}" | head -n 3)
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

[ "${#REPOS[@]}" -gt 0 ] || exit 0

echo "## Contexto do kit"
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
  for repo in "${REPOS[@]}"; do
    name="$(kit_rel_to "$CWD" "$repo")"
    [ "$name" = "." ] && name="${repo##*/}"
    BRANCH="$(git -C "$repo" branch --show-current 2>/dev/null | tr -d '\r')"
    echo
    echo "### $name (branch: ${BRANCH:-detached})"
    STATUS="$(git -C "$repo" status --short 2>/dev/null | tr -d '\r' | head -n 15)"
    if [ -n "$STATUS" ]; then printf '%s\n' "$STATUS"; else echo "(sem alterações)"; fi
  done
fi

PLANS="$(kit_active_plans "$ROOT" "${REPOS[@]}" | head -n 3)"
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
