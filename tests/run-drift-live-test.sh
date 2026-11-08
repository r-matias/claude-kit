#!/usr/bin/env bash
# Teste ao vivo do /kit:drift: com uma SPEC concluida e divergente, uma com plano em andamento e uma
# sem plano, so a concluida vai para o kit:drift-checker; o DRIFT.md sai com a divergencia [D2], as
# outras duas em Puladas com o motivo, data e commit no cabecalho. A escrita do DRIFT.md vem do
# allowed-tools da skill (Write fora de --allowedTools e sem acceptEdits) e nada mais muda no repo.
# Custa uma sessao do Claude Code. Uso: tests/run-drift-live-test.sh [--keep]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)/plugins/kit"
FX="$HERE/reviewers"
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

d="$W/repo"
cp -r "$FX/repo" "$d"
cp -r "$FX/drift/limpo/." "$d/"
cp -r "$FX/drift/ruim/." "$d/"
sed 's/^- \[ \]/- [x]/' "$FX/plans/limpo.md" >"$d/docs/specs/apelido/PLAN.md"
mkdir -p "$d/docs/specs/em-andamento" "$d/docs/specs/sem-plano"
cp "$FX/repo/docs/specs/apelido/SPEC.md" "$d/docs/specs/em-andamento/SPEC.md"
cp "$FX/plans/limpo.md" "$d/docs/specs/em-andamento/PLAN.md"
cp "$FX/repo/docs/specs/apelido/SPEC.md" "$d/docs/specs/sem-plano/SPEC.md"
git -C "$d" -c init.defaultBranch=main init -q
git -C "$d" -c core.autocrlf=false add -A
git -C "$d" -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test commit -qm base
head="$(git -C "$d" rev-parse --short HEAD | tr -d '\r')"

echo "rodando /kit:drift em $d (alguns minutos)..."
(cd "$d" && timeout 1800 claude -p "/kit:drift" --plugin-dir "$PLUGIN" \
  --setting-sources project,local --allowedTools "Read" "Grep" "Glob" "Agent" \
  --max-turns 40 --output-format stream-json --verbose </dev/null >"$W/drift.jsonl" 2>"$W/drift.err")

calls="$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
  | if .name == "Agent" or .name == "Task" then "\(.name):\(.input.subagent_type // "")" else .name end' "$W/drift.jsonl" 2>/dev/null | tr -d '\r')"
checker_prompts="$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and (.name == "Agent" or .name == "Task")
  and .input.subagent_type == "kit:drift-checker") | .input.prompt' "$W/drift.jsonl" 2>/dev/null | tr -d '\r')"
final="$(jq -r 'select(.type == "result") | .result // empty' "$W/drift.jsonl" 2>/dev/null | tr -d '\r')"
R="$d/docs/specs/DRIFT.md"

n="$(grep -cE '^(Agent|Task):kit:drift-checker$' <<<"$calls")"
if [ "$n" = "1" ]; then ok "kit:drift-checker chamado uma vez"; else ko "kit:drift-checker chamado uma vez" "$n chamadas: $(tr '\n' ' ' <<<"$calls")"; fi
if grep -q 'docs/specs/apelido/SPEC.md' <<<"$checker_prompts" && ! grep -qE 'em-andamento|sem-plano' <<<"$checker_prompts"; then
  ok "checker recebeu só a SPEC concluída"
else ko "checker recebeu só a SPEC concluída" "$(head -c 300 <<<"$checker_prompts")"; fi
if [ -f "$R" ]; then ok "DRIFT.md gravado"; else ko "DRIFT.md gravado" "$(tail -n 10 <<<"$final")"; fi
[ -f "$R" ] || : >"$R"
RT="$(tr -d '\r' <"$R")"
if grep -qE "Gerado em [0-9]{4}-[0-9]{2}-[0-9]{2} no commit \`?$head" <<<"$RT"; then ok "cabeçalho com data e commit"; else ko "cabeçalho com data e commit" "$(head -n 3 <<<"$RT")"; fi
sec="$(awk '/^## .*apelido\/SPEC\.md/ { on = 1; next } /^## / { on = 0 } on' <<<"$RT")"
if grep -q '\[D2\]' <<<"$sec"; then ok "seção da SPEC concluída com [D2]"; else ko "seção da SPEC concluída com [D2]" "$(head -n 6 <<<"$sec")"; fi
if grep -qE 'corrigir: `?código' <<<"$sec"; then ok "divergência aponta corrigir: código"; else ko "divergência aponta corrigir: código" "$(head -n 6 <<<"$sec")"; fi
pul="$(awk '/^## Puladas/ { on = 1; next } /^## / { on = 0 } on' <<<"$RT")"
if grep -q 'em-andamento' <<<"$pul" && grep -q 'plano em andamento' <<<"$pul"; then ok "Puladas: em-andamento com motivo"; else ko "Puladas: em-andamento com motivo" "$pul"; fi
if grep -q 'sem-plano' <<<"$pul" && grep -q 'sem plano' <<<"$pul"; then ok "Puladas: sem-plano com motivo"; else ko "Puladas: sem-plano com motivo" "$pul"; fi
changed="$(git -C "$d" status --porcelain | tr -d '\r' | grep -v ' docs/specs/DRIFT.md$' || true)"
if [ -z "$changed" ]; then ok "só o DRIFT.md mudou"; else ko "só o DRIFT.md mudou" "$(tr '\n' ' ' <<<"$changed")"; fi
lines="$(grep -c . <<<"$final")"
if [ "$lines" -ge 1 ] && [ "$lines" -le 5 ]; then ok "resumo curto ($lines linhas)"; else ko "resumo curto" "$lines linhas"; fi
if grep -q 'DRIFT.md' <<<"$final" && grep -q '/kit:fix' <<<"$final"; then ok "resumo cita o DRIFT.md e o /kit:fix"; else ko "resumo cita o DRIFT.md e o /kit:fix" "$final"; fi

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
