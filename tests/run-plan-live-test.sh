#!/usr/bin/env bash
# Teste ao vivo do /kit:plan: lacuna tecnica vira Decisoes (origem kit) sem pergunta, no formato
# must_haves/Interfaces/waves/wave final; lacuna de
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
[ -f "$P" ] || : >"$P.vazio"
PF="$P"; [ -f "$P" ] || PF="$P.vazio"
heads="$(grep -E '^##+ ' "$PF" | tr -d '\r' | sed -E 's/^(##+ (must_haves|truths|artifacts|tests|Interfaces|Wave final|Wave [0-9]+|Decisões)).*/\1/' |
  grep -E '^##+ (must_haves|truths|artifacts|tests|Interfaces|Wave final|Wave [0-9]+|Decisões)$' | sed -E 's/Wave [0-9]+/Wave N/' | awk '!seen[$0]++' | paste -sd'|' -)"
if [ "$heads" = "## must_haves|### truths|### artifacts|### tests|## Interfaces|## Wave N|## Wave final|## Decisões" ]; then
  ok "seções na ordem: must_haves, Interfaces, waves, wave final, Decisões"
else ko "seções na ordem: must_haves, Interfaces, waves, wave final, Decisões" "$heads"; fi
# Cada tarefa numerada tem files, behavior, action, verify e done, nessa ordem.
bad_tasks="$(tr -d '\r' <"$PF" | awk '
  function flush() { if (t != "" && f != "files|behavior|action|verify|done") print t " -> " f }
  /^- \[[ xX]\] [0-9]+\. / { flush(); t = $0; f = ""; next }
  /^- \[|^## / { flush(); t = ""; f = ""; next }
  t != "" && match($0, /^  - (files|behavior|action|verify|done):/) { k = substr($0, 5, RLENGTH - 5); f = f (f == "" ? "" : "|") k }
  END { flush() }')"
ntasks="$(grep -cE '^- \[[ xX]\] [0-9]+\. ' "$PF")"
if [ "$ntasks" -gt 0 ] && [ -z "$bad_tasks" ]; then ok "$ntasks tarefas com files, behavior, action, verify e done"; else ko "tarefas com files, behavior, action, verify e done" "${bad_tasks:-nenhuma tarefa}"; fi
waves="$(grep -cE '^## Wave [0-9]+' "$PF")"
cps="$(grep -cE '^- \[ \] Checkpoint wave [0-9]+:' "$PF")"
pars="$(grep -cE '^Paralelo:' "$PF")"
if [ "$waves" -gt 0 ] && [ "$cps" = "$waves" ] && [ "$pars" = "$waves" ]; then ok "$waves waves, cada uma com Paralelo e checkpoint"; else ko "waves com Paralelo e checkpoint" "waves=$waves checkpoints=$cps paralelo=$pars"; fi
final="$(sed -n '/^## Wave final/,/^## [^W]/p' "$PF" | grep -oE '^- \[ \] F[0-9]+' | sed 's/.* //' | paste -sd' ' -)"
if [ "$final" = "F1 F2 F3" ]; then ok "wave final F1-F3, sem smoke (kit.json sem smoke)"; else ko "wave final F1-F3, sem smoke" "$final"; fi
stray="$(grep -E '\[[ xX]\]' "$PF" | grep -vE '^- \[[ xX]\] ([0-9]+\.|Checkpoint wave [0-9]+:|F[0-9]+\.) ' || true)"
if [ -z "$stray" ]; then ok "caixa só em tarefa, checkpoint e wave final"; else ko "caixa só em tarefa, checkpoint e wave final" "$stray"; fi
if sed -n '/^## Interfaces/,/^## /p' "$PF" | grep -q 'lastLoginAt'; then ok "Interfaces cita lastLoginAt"; else ko "Interfaces cita lastLoginAt" "ausente"; fi
if sed -n '/^## Decisões/,/^## [^D]/p' "$PF" | grep -qE '^- [0-9]{4}-[0-9]{2}-[0-9]{2} · kit · .+ — .+'; then
  ok "Decisões com data, origem kit e motivo"
else ko "Decisões com data, origem kit e motivo" "$(sed -n '/^## Decisões/,/^## [^D]/p' "$PF" | head -n 6)"; fi
if ! grep -qx 'AskUserQuestion' <<<"$calls"; then ok "nenhuma pergunta ao usuário"; else ko "nenhuma pergunta ao usuário" "AskUserQuestion chamado"; fi
if grep -qx 'Agent:kit:plan-reviewer\|Task:kit:plan-reviewer' <<<"$calls"; then ok "kit:plan-reviewer chamado"; else ko "kit:plan-reviewer chamado" "$(tr '\n' ' ' <<<"$calls")"; fi
if git -C "$d" diff --quiet HEAD -- src test data; then ok "nenhum código de produção alterado"; else ko "nenhum código de produção alterado" "$(git -C "$d" diff --stat HEAD -- src test data | tr '\n' ' ')"; fi
if git -C "$d" diff HEAD -- docs/data-model.md | grep -q '^+.*lastLogin'; then ok "doc de referência (data-model.md) atualizado"; else ko "doc de referência (data-model.md) atualizado" "sem linha nova com lastLogin"; fi
summary_lines="$(final_text "$d.jsonl" | grep -c .)"
if [ "$summary_lines" -ge 1 ] && [ "$summary_lines" -le 5 ]; then ok "resumo curto ($summary_lines linhas)"; else ko "resumo curto" "$summary_lines linhas"; fi

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
