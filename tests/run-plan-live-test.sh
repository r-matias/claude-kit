#!/usr/bin/env bash
# Teste ao vivo do /kit:plan: lacuna tecnica vira "Decisoes assumidas" sem pergunta; lacuna de
# produto vira pergunta e nao gera PLAN.md. Confere no disco e no transcript (stream-json).
# Custa duas sessoes do Claude Code (alguns minutos cada). Uso: tests/run-plan-live-test.sh [--keep]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)/plugins/kit"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

command -v claude >/dev/null 2>&1 || { echo "claude CLI nao encontrada" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq nao encontrado" >&2; exit 1; }

W="$(mktemp -d)"
if [ "$KEEP" = "1" ]; then echo "workspace mantido em $W"; else trap 'rm -rf "$W"' EXIT; fi
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FALHA %s -- %s\n' "$1" "$2"; }

# Uso: run_plan <slug>. Monta o repo com a SPEC do caso e roda /kit:plan. Ecoa a pasta.
run_plan() {
  local slug="$1" d
  d="$W/$slug"
  cp -r "$HERE/plan/repo" "$d"
  mkdir -p "$d/docs/specs/$slug"
  cp "$HERE/plan/specs/$slug/SPEC.md" "$d/docs/specs/$slug/SPEC.md"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" -c core.autocrlf=false add -A
  git -C "$d" -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test commit -qm init
  (cd "$d" && timeout 1200 claude -p "/kit:plan docs/specs/$slug/SPEC.md" --plugin-dir "$PLUGIN" \
    --setting-sources project,local --permission-mode acceptEdits --allowedTools "Read" "Grep" "Glob" "Write" "Edit" "Agent" \
    --max-turns 60 --output-format stream-json --verbose </dev/null >"$d.jsonl" 2>"$d.err")
  printf '%s' "$d"
}

# Nomes das ferramentas chamadas no transcript, uma por linha.
tools_called() {
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
    | if .name == "Agent" or .name == "Task" then "\(.name):\(.input.subagent_type // "")" else .name end' "$1" 2>/dev/null | tr -d '\r'
}

final_text() {
  jq -r 'select(.type == "result") | .result // empty' "$1" 2>/dev/null | tr -d '\r'
}

echo "lacuna tecnica"
d="$(run_plan lacuna-tecnica)"
P="$d/docs/specs/lacuna-tecnica/PLAN.md"
calls="$(tools_called "$d.jsonl")"
if [ -f "$P" ]; then ok "PLAN.md gravado"; else ko "PLAN.md gravado" "$(final_text "$d.jsonl" | tail -n 10)"; fi
if [ -f "$P" ] && awk '/^## Decisões assumidas/ {s = 1; next} /^## / {s = 0} s && /^- .+ — .+/ {n++} END {exit !(n > 0)}' "$P"; then
  ok "seção Decisões assumidas com decisão e motivo"
else ko "seção Decisões assumidas com decisão e motivo" "$( [ -f "$P" ] && sed -n '/## Decisões assumidas/,/^## [^D]/p' "$P" | head -n 10)"; fi
if ! grep -qx 'AskUserQuestion' <<<"$calls"; then ok "nenhuma pergunta ao usuário"; else ko "nenhuma pergunta ao usuário" "AskUserQuestion chamado"; fi
if grep -qx 'Agent:kit:plan-reviewer\|Task:kit:plan-reviewer' <<<"$calls"; then ok "kit:plan-reviewer chamado"; else ko "kit:plan-reviewer chamado" "$(tr '\n' ' ' <<<"$calls")"; fi
if git -C "$d" diff --quiet HEAD -- src test data; then ok "nenhum código de produção alterado"; else ko "nenhum código de produção alterado" "$(git -C "$d" diff --stat HEAD -- src test data | tr '\n' ' ')"; fi
if git -C "$d" diff HEAD -- docs/data-model.md | grep -q '^+.*lastLogin'; then ok "doc de referência (data-model.md) atualizado"; else ko "doc de referência (data-model.md) atualizado" "sem linha nova com lastLogin"; fi
summary_lines="$(final_text "$d.jsonl" | grep -c .)"
if [ "$summary_lines" -ge 1 ] && [ "$summary_lines" -le 7 ]; then ok "resumo curto ($summary_lines linhas)"; else ko "resumo curto" "$summary_lines linhas"; fi

echo "lacuna de produto"
d="$(run_plan lacuna-produto)"
P="$d/docs/specs/lacuna-produto/PLAN.md"
calls="$(tools_called "$d.jsonl")"
text="$(final_text "$d.jsonl")"
# Em claude -p o AskUserQuestion pode nao estar disponivel; vale a chamada ou a pergunta no texto final.
if grep -qx 'AskUserQuestion' <<<"$calls" || grep -q '?' <<<"$text"; then ok "pergunta ao usuário"; else ko "pergunta ao usuário" "$(tail -n 10 <<<"$text")"; fi
if grep -qiE 'tentativas|limite' <<<"$text$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.name == "AskUserQuestion") | .input | tostring' "$d.jsonl" 2>/dev/null)"; then
  ok "pergunta trata do limite de tentativas"
else ko "pergunta trata do limite de tentativas" "$(tail -n 10 <<<"$text")"; fi
if [ ! -f "$P" ]; then ok "PLAN.md não gravado antes da resposta"; else ko "PLAN.md não gravado antes da resposta" "$(head -n 20 "$P")"; fi

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
