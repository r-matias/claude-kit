#!/usr/bin/env bash
# Teste ao vivo do /kit:execute num plano de 2 waves: a wave 1 tem 2 tarefas paralelas de arquivos
# disjuntos (vao para subagents ao mesmo tempo); a wave 2 marca como paralelas 2 tarefas que tocam
# o mesmo arquivo (precisam rodar em sequencia, com registro em Decisoes). Confere no disco, num
# teste de aceite proprio e no transcript (stream-json).
# Custa uma sessao longa do Claude Code (varios minutos). Uso: tests/run-execute-live-test.sh [--keep]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)/plugins/kit"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

command -v claude >/dev/null 2>&1 || { echo "claude CLI nao encontrada" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq nao encontrado" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node nao encontrado (a fixture usa node --test)" >&2; exit 1; }

W="$(mktemp -d)"
if [ "$KEEP" = "1" ]; then echo "workspace mantido em $W"; else trap 'rm -rf "$W"' EXIT; fi
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FALHA %s -- %s\n' "$1" "$2"; }

D="$W/repo"
cp -r "$HERE/execute/repo" "$D"
gitq() { git -C "$D" -c init.defaultBranch=main -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test "$@" >/dev/null 2>&1; }
gitq init
gitq add -A
gitq commit -m init
P="$D/docs/specs/util/PLAN.md"
T="$W/transcript.jsonl"

echo "rodando /kit:execute em $D (pode levar varios minutos)..."
(cd "$D" && timeout 2400 claude -p "/kit:execute docs/specs/util/PLAN.md" --plugin-dir "$PLUGIN" \
  --setting-sources project,local --permission-mode acceptEdits \
  --allowedTools "Bash" "Read" "Write" "Edit" "Glob" "Grep" "Agent" \
  --max-turns 150 --output-format stream-json --verbose </dev/null >"$T" 2>"$W/claude.err")
CODE=$?
plan="$(tr -d '\r' <"$P")"

[ "$CODE" -eq 0 ] && ok "claude -p terminou com exit 0" || ko "claude -p terminou com exit 0" "exit $CODE; $(tail -c 300 "$W/claude.err")"

# Done comprovado por fora: teste de aceite que o modelo nao viu.
mkdir -p "$D/aceite"
cp "$HERE/execute/aceite.test.js" "$D/aceite/"
if (cd "$D" && node --test aceite/aceite.test.js >"$W/aceite.out" 2>&1); then ok "teste de aceite independente passa"; else ko "teste de aceite independente passa" "$(tail -n 15 "$W/aceite.out")"; fi
rm -rf "$D/aceite"
if (cd "$D" && node --test >"$W/suite.out" 2>&1); then ok "node --test passa"; else ko "node --test passa" "$(tail -n 15 "$W/suite.out")"; fi

pending="$(grep -E '^- \[ \]' <<<"$plan" || true)"
if [ -z "$pending" ]; then ok "todas as caixas marcadas"; else ko "todas as caixas marcadas" "$pending"; fi

# Cada caixa [x] de tarefa e checkpoint tem Evidencia; checkpoint tem tambem Revisao.
bad_ev="$(awk '
  function flush() { if (box != "" && (!ev || (cp && !rv))) print box " (evidencia=" ev ", revisao=" rv ")" }
  /^- \[[xX]\] / { flush(); box = $0; ev = 0; rv = 0; cp = ($0 ~ /Checkpoint wave/); if ($0 ~ /^- \[[xX]\] F[0-9]/) box = ""; next }
  /^- |^#/ { flush(); box = "" ; next }
  box != "" && /^  - Evidência:/ { ev = 1 }
  box != "" && /^  - Revisão: kit:code-reviewer/ { rv = 1 }
  END { flush() }' <<<"$plan")"
if [ -z "$bad_ev" ]; then ok "tarefas com Evidência; checkpoints com Evidência e Revisão do code-reviewer"; else ko "tarefas com Evidência; checkpoints com Evidência e Revisão do code-reviewer" "$bad_ev"; fi

bases="$(grep -cE '^Base: [0-9a-f]{40}' <<<"$plan")"
if [ "$bases" = "2" ]; then ok "Base gravada nas 2 waves"; else ko "Base gravada nas 2 waves" "$bases linhas Base:"; fi

if sed -n '/^## Decisões/,/^## /p' <<<"$plan" | grep -E '· kit ·' | grep -qiE 'sequ|serial'; then
  ok "Decisões registra a wave 2 em sequência"
else ko "Decisões registra a wave 2 em sequência" "$(sed -n '/^## Decisões/,/^## /p' <<<"$plan")"; fi

# Eventos do transcript: "use <msg> <id> <nome> <texto do prompt>" e "result <id>", na ordem.
jq -r 'if .type == "assistant" then (.message.id // "m") as $m | .message.content[]? | select(.type == "tool_use")
    | "use\t\($m)\t\(.id)\t\(if .name == "Agent" or .name == "Task" then "agent:" + (.input.subagent_type // "general-purpose") else .name end)\t\((.input.prompt // "") | gsub("[\t\n\r]"; " "))"
  elif .type == "user" then .message.content[]? | select(.type == "tool_result") | "result\t\(.tool_use_id)"
  else empty end' "$T" 2>/dev/null | tr -d '\r' >"$W/events.tsv"

par_msg="$(awk -F'\t' '$1 == "use" && $4 == "agent:general-purpose" { n[$2]++ } END { for (m in n) if (n[m] >= 2) print m }' "$W/events.tsv" | head -n 1)"
if [ -n "$par_msg" ] && awk -F'\t' -v m="$par_msg" '$2 == m && $4 == "agent:general-purpose"' "$W/events.tsv" | grep -qi 'soma' &&
  awk -F'\t' -v m="$par_msg" '$2 == m && $4 == "agent:general-purpose"' "$W/events.tsv" | grep -qi 'maiusculas'; then
  ok "wave 1: tarefas 1 e 2 em subagents disparados juntos"
else ko "wave 1: tarefas 1 e 2 em subagents disparados juntos" "nenhuma mensagem com 2 subagents general-purpose (soma e maiusculas)"; fi

serial_bad="$(awk -F'\t' '$1 == "use" && $4 == "agent:general-purpose" && tolower($5) ~ /dobro|media/ { n[$2]++ } END { for (m in n) if (n[m] >= 2) print m }' "$W/events.tsv")"
if [ -z "$serial_bad" ]; then ok "wave 2: tarefas 3 e 4 não disparadas em paralelo"; else ko "wave 2: tarefas 3 e 4 não disparadas em paralelo" "mensagem $serial_bad"; fi

# A revisao do checkpoint 1 so pode comecar depois que os 2 subagents paralelos voltaram.
order_ok="$(awk -F'\t' -v m="$par_msg" '
  $1 == "use" && $2 == m && $4 == "agent:general-purpose" { want[$3] = 1; total++ }
  $1 == "result" && ($2 in want) { got++ }
  $1 == "use" && $4 == "agent:kit:code-reviewer" && !seen { seen = 1; print (total > 0 && got == total) ? "sim" : "nao"; exit }' "$W/events.tsv")"
if [ "$order_ok" = "sim" ]; then ok "revisão do checkpoint 1 só depois dos subagents paralelos"; else ko "revisão do checkpoint 1 só depois dos subagents paralelos" "${order_ok:-code-reviewer nao chamado}"; fi

cr="$(awk -F'\t' '$1 == "use" && $4 == "agent:kit:code-reviewer"' "$W/events.tsv" | grep -c .)"
sr="$(awk -F'\t' '$1 == "use" && $4 == "agent:kit:security-reviewer"' "$W/events.tsv" | grep -c .)"
if [ "$cr" -ge 3 ] && [ "$sr" -ge 1 ]; then ok "code-reviewer por wave e na F1 ($cr chamadas), security-reviewer na F1 ($sr)"; else ko "code-reviewer por wave e na F1, security-reviewer na F1" "code-reviewer=$cr security-reviewer=$sr"; fi

if [ "$(git -C "$D" rev-list --count HEAD | tr -d '\r')" = "1" ]; then ok "nenhum commit criado"; else ko "nenhum commit criado" "$(git -C "$D" log --oneline | tr -d '\r')"; fi

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
