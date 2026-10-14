#!/usr/bin/env bash
# SessionStart: injeta branch, arquivos alterados e tarefas pendentes do PLAN.md mais recente.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

CWD="$(kit_cwd)"
command -v git >/dev/null 2>&1 || exit 0
TOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0

BRANCH="$(git -C "$TOP" branch --show-current 2>/dev/null)"
echo "## Contexto do kit"
echo "Branch: ${BRANCH:-(detached)}"

STATUS="$(git -C "$TOP" status --short 2>/dev/null | head -n 30)"
if [ -n "$STATUS" ]; then
  echo
  echo "Alterados (git status --short, ate 30):"
  printf '%s\n' "$STATUS"
fi

PLAN="$(ls -t "$TOP"/docs/specs/*/PLAN.md "$TOP"/docs/specs/*/*/PLAN.md 2>/dev/null | head -n 1)"
if [ -n "$PLAN" ]; then
  PENDING="$(grep -E '^[[:space:]]*[-*] \[ \]' "$PLAN" | head -n 40)"
  if [ -n "$PENDING" ]; then
    echo
    echo "Plano ativo: ${PLAN#"$TOP"/}"
    echo "Tarefas pendentes:"
    printf '%s\n' "$PENDING"
  fi
fi
exit 0
