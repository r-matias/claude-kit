#!/usr/bin/env bash
# PreCompact: grava em <raiz>/.claude/state/kit-snapshot.md o estado de trabalho de cada repositorio
# e os planos ativos, para o session-context.sh reinjetar apos a compactacao. Nunca bloqueia.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

CWD="$(kit_cwd)"
ROOT="$(kit_session_root "$CWD")"
SID="$(kit_field '.session_id')"

REPOS=()
command -v git >/dev/null 2>&1 && while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(kit_repos "$CWD" "$SID")

mkdir -p "$ROOT/.claude/state" 2>/dev/null || exit 0
SNAP="$ROOT/.claude/state/kit-snapshot.md"
{
  echo "Snapshot do kit em $(date '+%Y-%m-%d %H:%M') (gatilho: $(kit_field '.trigger'))."
  if [ "${#REPOS[@]}" -eq 0 ]; then
    echo
    echo "Nenhum repositório git na sessão."
  fi
  for repo in "${REPOS[@]}"; do
    name="$(kit_rel_to "$CWD" "$repo")"
    [ "$name" = "." ] && name="${repo##*/}"
    echo
    echo "### $name (branch: $(git -C "$repo" branch --show-current 2>/dev/null | tr -d '\r'))"
    mod="$(git -c core.quotepath=off -C "$repo" diff --name-only 2>/dev/null | tr -d '\r' | head -n 20)"
    stg="$(git -c core.quotepath=off -C "$repo" diff --name-only --cached 2>/dev/null | tr -d '\r' | head -n 20)"
    echo "Modificados: ${mod:+$'\n'}${mod:-nenhum}"
    echo "Staged: ${stg:+$'\n'}${stg:-nenhum}"
  done
  PLANS="$(kit_active_plans "$ROOT" "${REPOS[@]}" | head -n 3)"
  if [ -n "$PLANS" ]; then
    echo
    echo "Planos ativos (feitas/total):"
    while IFS=$'\t' read -r d t f; do
      echo "- $(kit_rel_to "$ROOT" "$f") ($d/$t)"
      grep -E '^[[:space:]]*[-*] \[ \]' "$f" | tr -d '\r' | head -n 20 | sed 's/^[[:space:]]*/  /'
    done <<<"$PLANS"
  fi
} >"$SNAP" 2>/dev/null
exit 0
