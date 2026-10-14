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

# Versao minima para onFailure: "block" nos guardas. Sem o comando ou sem versao legivel: nao avisa.
KIT_MIN_CLAUDE="2.1.295"
version_lt() {
  local IFS=.
  local -a a=($1) b=($2)
  local i
  for i in 0 1 2; do
    [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ] && return 0
    [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ] && return 1
  done
  return 1
}
VERSION_NOTE=""
if command -v claude >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then CV="$(timeout 5 claude --version 2>/dev/null)"; else CV="$(claude --version 2>/dev/null)"; fi
  CV="$(printf '%s' "$CV" | tr -d '\r' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
  if [ -n "$CV" ] && version_lt "$CV" "$KIT_MIN_CLAUDE"; then
    VERSION_NOTE="kit: Claude Code < $KIT_MIN_CLAUDE, guardas sem onFailure:block — rode claude update (versão atual: $CV)"
  fi
fi

if [ "${#REPOS[@]}" -eq 0 ]; then
  [ -n "$VERSION_NOTE" ] && echo "$VERSION_NOTE"
  exit 0
fi

echo "## Contexto do kit"
[ -n "$VERSION_NOTE" ] && echo "$VERSION_NOTE"
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
