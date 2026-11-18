#!/usr/bin/env bash
# Teste ao vivo do /kit:plan: lacuna tecnica vira Decisoes (origem kit) sem pergunta, no formato
# must_haves/Interfaces/waves/wave final; lacuna de
# produto vira pergunta e nao gera PLAN.md. Tamanho: SPEC de 20 operacoes vira pergunta de quebra
# sem PLAN.md; com a Decisao "tamanho: manter" do usuario, grava sem perguntar. O /kit:spec com
# escopo grande pergunta a quebra em fatias e nao grava; com escopo pequeno grava a SPEC.md e chama o
# kit:spec-reviewer. Em projeto com tela: o plano de uma SPEC com a secao Telas cita o kit:ui-reviewer na
# F1 e tem truth para os estados; a SPEC de uma feature com tela sai com a secao Telas preenchida.
# Confere no disco e no transcript (stream-json).
# Custa oito sessoes do Claude Code (alguns minutos cada). Uso: tests/run-plan-live-test.sh [--keep]
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

# Uso: new_repo <nome> [spec da fixture] [linha extra em Decisões]. Copia o repo da fixture, poe a
# SPEC em docs/specs/<nome>/ e commita. Ecoa a pasta.
new_repo() {
  local d="$W/$1" s
  cp -r "$HERE/plan/repo" "$d"
  if [ -n "${2:-}" ]; then
    s="$d/docs/specs/$1/SPEC.md"
    mkdir -p "$d/docs/specs/$1"
    cp "$HERE/plan/specs/$2/SPEC.md" "$s"
    if [ -n "${3:-}" ]; then
      awk -v l="$3" '{ print } /^## Decisões/ { print l }' "$s" >"$s.tmp" && mv "$s.tmp" "$s"
    fi
  fi
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" -c core.autocrlf=false add -A
  git -C "$d" -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test commit -qm init
  printf '%s' "$d"
}

# Uso: run_claude <pasta> <prompt> [max-turns]. Grava o transcript em <pasta>.jsonl.
run_claude() {
  (cd "$1" && timeout 1800 claude -p "$2" --plugin-dir "$PLUGIN" \
    --setting-sources project,local --permission-mode acceptEdits --allowedTools "Read" "Grep" "Glob" "Write" "Edit" "Agent" \
    --max-turns "${3:-60}" --output-format stream-json --verbose </dev/null >"$1.jsonl" 2>"$1.err")
}

# Uso: run_plan <slug> [spec da fixture] [linha extra em Decisões] [max-turns]. Roda /kit:plan. Ecoa a pasta.
run_plan() {
  local d
  d="$(new_repo "$1" "${2:-$1}" "${3:-}")"
  run_claude "$d" "/kit:plan docs/specs/$1/SPEC.md" "${4:-60}"
  printf '%s' "$d"
}

# Texto do AskUserQuestion e da resposta final, para conferir a pergunta.
question_text() {
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.name == "AskUserQuestion") | .input | tostring' "$1" 2>/dev/null | tr -d '\r'
  final_text "$1"
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
if ! grep -q 'kit:ui-reviewer' "$PF"; then ok "plano sem tela não cita o kit:ui-reviewer"; else ko "plano sem tela não cita o kit:ui-reviewer" "$(grep -n 'kit:ui-reviewer' "$PF" | head -n 2)"; fi
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
if grep -qx 'AskUserQuestion' <<<"$calls" || grep -qE '\?|[Rr]esponda|[Ee]scolha' <<<"$text"; then ok "pergunta ao usuário"; else ko "pergunta ao usuário" "$(tail -n 10 <<<"$text")"; fi
if grep -qiE 'tentativas|limite' <<<"$text$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.name == "AskUserQuestion") | .input | tostring' "$d.jsonl" 2>/dev/null)"; then
  ok "pergunta trata do limite de tentativas"
else ko "pergunta trata do limite de tentativas" "$(tail -n 10 <<<"$text")"; fi
if [ ! -f "$P" ]; then ok "PLAN.md não gravado antes da resposta"; else ko "PLAN.md não gravado antes da resposta" "$(head -n 20 "$P")"; fi

echo "plano grande sem decisão"
d="$(run_plan grande)"
calls="$(tools_called "$d.jsonl")"
q="$(question_text "$d.jsonl")"
if grep -qx 'AskUserQuestion' <<<"$calls" || grep -qE '\?|[Rr]esponda|[Ee]scolha' <<<"$q"; then ok "pergunta ao usuário"; else ko "pergunta ao usuário" "$(tail -n 10 <<<"$q")"; fi
if grep -qi 'fatia' <<<"$q" && grep -qiE 'EPIC\.md|épico' <<<"$q" && grep -qi 'manter' <<<"$q"; then ok "pergunta propõe quebra em fatias, com manter"
else ko "pergunta propõe quebra em fatias, com manter" "$(tail -n 10 <<<"$q")"; fi
if [ ! -f "$d/docs/specs/grande/PLAN.md" ]; then ok "PLAN.md não gravado"; else ko "PLAN.md não gravado" "$(grep -cE '^- \[ \] [0-9]+\. ' "$d/docs/specs/grande/PLAN.md") tarefas"; fi
if [ -z "$(find "$d/docs/specs" -name EPIC.md)" ]; then ok "EPIC.md não gravado antes da resposta"; else ko "EPIC.md não gravado antes da resposta" "$(find "$d/docs/specs" -name EPIC.md)"; fi

echo "plano grande com Decisão do usuário"
d="$(run_plan grande-decidido grande "- 2026-10-01 · usuário · tamanho: manter num plano só — acima do limite, o suporte quer tudo num plano" 100)"
P="$d/docs/specs/grande-decidido/PLAN.md"
calls="$(tools_called "$d.jsonl")"
if [ -f "$P" ]; then ok "PLAN.md gravado"; else ko "PLAN.md gravado" "$(final_text "$d.jsonl" | tail -n 10)"; fi
[ -f "$P" ] || : >"$P"
ntasks="$(grep -cE '^- \[[ xX]\] [0-9]+\. ' "$P")"
nwaves="$(grep -cE '^## Wave [0-9]+' "$P")"
if [ "$ntasks" -gt 15 ] || [ "$nwaves" -gt 6 ]; then ok "plano acima do limite ($ntasks tarefas, $nwaves waves)"; else ko "plano acima do limite" "$ntasks tarefas, $nwaves waves"; fi
if ! grep -qx 'AskUserQuestion' <<<"$calls"; then ok "nenhuma pergunta ao usuário"; else ko "nenhuma pergunta ao usuário" "AskUserQuestion chamado"; fi
if sed -n '/^## Decisões/,/^## [^D]/p' "$P" | grep -q '· usuário · tamanho: manter'; then ok "Decisões do PLAN.md com tamanho: manter do usuário"
else ko "Decisões do PLAN.md com tamanho: manter do usuário" "$(sed -n '/^## Decisões/,/^## [^D]/p' "$P" | head -n 6)"; fi

echo "spec com escopo grande"
d="$(new_repo spec-grande)"
cp "$HERE/plan/specs/grande/SPEC.md" "$d/briefing.md"
run_claude "$d" "/kit:spec painel administrativo de usuários descrito em briefing.md. O briefing já responde tudo: escopo, decisões, casos de borda e verificação; não há perguntas em aberto."
calls="$(tools_called "$d.jsonl")"
q="$(question_text "$d.jsonl")"
if grep -qx 'AskUserQuestion' <<<"$calls" || grep -qE '\?|[Rr]esponda|[Ee]scolha' <<<"$q"; then ok "pergunta ao usuário"; else ko "pergunta ao usuário" "$(tail -n 10 <<<"$q")"; fi
if grep -qi 'fatia' <<<"$q" && grep -qiE 'EPIC\.md|épico' <<<"$q" && grep -qi 'manter' <<<"$q" && grep -qi 'reduzir' <<<"$q"; then
  ok "pergunta propõe quebra em fatias, manter ou reduzir"
else ko "pergunta propõe quebra em fatias, manter ou reduzir" "$(tail -n 10 <<<"$q")"; fi
written="$(find "$d/docs" \( -name SPEC.md -o -name EPIC.md \) 2>/dev/null)"
if [ -z "$written" ]; then ok "nenhuma SPEC.md ou EPIC.md gravada antes da resposta"; else ko "nenhuma SPEC.md ou EPIC.md gravada antes da resposta" "$written"; fi

echo "spec pequena com revisão"
d="$(new_repo spec-pequena)"
cp "$HERE/plan/specs/lacuna-tecnica/SPEC.md" "$d/briefing.md"
run_claude "$d" "/kit:spec último login no perfil, descrito em briefing.md. O briefing já responde tudo: escopo, decisões, casos de borda e verificação; não há perguntas em aberto. Use o slug ultimo-login."
calls="$(tools_called "$d.jsonl")"
S="$(find "$d/docs/specs" -name SPEC.md 2>/dev/null | head -n 1)"
if [ -n "$S" ]; then ok "SPEC.md gravada (${S#"$d"/})"; else ko "SPEC.md gravada" "$(final_text "$d.jsonl" | tail -n 10)"; fi
[ -n "$S" ] || S="$d/sem-spec.md"
for h in '## Objetivo' '## Escopo' '## Fora de escopo' '## Casos de borda' '## Verificação ponta a ponta'; do
  grep -qx "$h" <(tr -d '\r' <"$S" 2>/dev/null) || { ko "SPEC.md com as seções do formato" "falta $h"; h=x; break; }
done
[ "$h" = x ] || ok "SPEC.md com as seções do formato"
if ! grep -qx '## Telas' <(tr -d '\r' <"$S" 2>/dev/null); then ok "SPEC.md sem tela não tem a seção Telas"; else ko "SPEC.md sem tela não tem a seção Telas" "seção presente"; fi
if grep -qx 'Agent:kit:spec-reviewer\|Task:kit:spec-reviewer' <<<"$calls"; then ok "kit:spec-reviewer chamado"; else ko "kit:spec-reviewer chamado" "$(tr '\n' ' ' <<<"$calls")"; fi
if git -C "$d" diff --quiet HEAD -- src test data; then ok "nenhum código de produção alterado"; else ko "nenhum código de produção alterado" "$(git -C "$d" diff --stat HEAD -- src test data | tr '\n' ' ')"; fi
if final_text "$d.jsonl" | grep -q '/kit:plan'; then ok "recomenda o /kit:plan"; else ko "recomenda o /kit:plan" "$(final_text "$d.jsonl" | tail -n 5)"; fi

# Uso: new_ui_repo <nome> [com-spec]. Projeto com tela (tests/ui/repo) e o kit.json com "ui". Ecoa a pasta.
new_ui_repo() {
  local d="$W/$1"
  cp -r "$HERE/ui/repo" "$d"
  mkdir -p "$d/.claude"
  cp "$HERE/ui/kit.json" "$d/.claude/kit.json"
  if [ -n "${2:-}" ]; then
    mkdir -p "$d/docs/specs/avisos"
    cp "$HERE/ui/specs/avisos/SPEC.md" "$d/docs/specs/avisos/SPEC.md"
  fi
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" -c core.autocrlf=false add -A
  git -C "$d" -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test commit -qm init
  printf '%s' "$d"
}

echo "plano de feature com tela"
d="$(new_ui_repo plano-tela spec)"
run_claude "$d" "/kit:plan docs/specs/avisos/SPEC.md"
P="$d/docs/specs/avisos/PLAN.md"
calls="$(tools_called "$d.jsonl")"
if [ -f "$P" ]; then ok "PLAN.md gravado"; else ko "PLAN.md gravado" "$(final_text "$d.jsonl" | tail -n 10)"; fi
[ -f "$P" ] || : >"$P"
if grep -E '^- \[ \] F1\. ' "$P" | grep -q 'kit:ui-reviewer'; then ok "F1 cita o kit:ui-reviewer"; else ko "F1 cita o kit:ui-reviewer" "$(grep -E '^- \[ \] F1\. ' "$P")"; fi
truths="$(sed -n '/^### truths/,/^### artifacts/p' "$P")"
if grep -qiE 'nenhum aviso|vazio' <<<"$truths" && grep -qiE 'não foi possível|erro' <<<"$truths" && grep -qi 'carregando' <<<"$truths" && grep -qE '700|coluna|rolagem' <<<"$truths"; then
  ok "truths cobrem os estados vazio, carregando e erro e a tela pequena"
else ko "truths cobrem os estados vazio, carregando e erro e a tela pequena" "$(head -n 14 <<<"$truths")"; fi
# A tarefa que cria web/avisos.html tem behavior para os estados e action com o molde e os tokens.
tela="$(tr -d '\r' <"$P" | awk '/^- \[[ xX]\] [0-9]+\. / { on = 0; buf = "" } /^- \[[ xX]\] [0-9]+\. / { buf = $0 "\n"; next }
  /^- \[|^## / { if (on) printf "%s", buf; on = 0; buf = ""; next }
  { buf = buf $0 "\n"; if ($0 ~ /^  - files:.*web\/avisos\.html/) on = 1 } END { if (on) printf "%s", buf }')"
if grep -qiE 'nenhum aviso|vazio' <<<"$tela" && grep -qiE 'não foi possível|erro' <<<"$tela"; then ok "tarefa da tela com behavior para vazio e erro"
else ko "tarefa da tela com behavior para vazio e erro" "$(head -n 20 <<<"$tela")"; fi
if grep -E '^  - action:' <<<"$tela" | grep -q 'web/tokens\.css' && grep -E '^  - action:' <<<"$tela" | grep -qE 'web/(index\.html|style\.css):[0-9]+'; then
  ok "action da tela aponta os tokens e o molde arquivo:linha de uma tela existente"
else ko "action da tela aponta os tokens e o molde arquivo:linha de uma tela existente" "$(grep -E '^  - action:' <<<"$tela" | head -c 600)"; fi
if grep -qx 'Agent:kit:plan-reviewer\|Task:kit:plan-reviewer' <<<"$calls"; then ok "kit:plan-reviewer chamado"; else ko "kit:plan-reviewer chamado" "$(tr '\n' ' ' <<<"$calls")"; fi
if git -C "$d" diff --quiet HEAD -- web test; then ok "nenhum código de produção alterado"; else ko "nenhum código de produção alterado" "$(git -C "$d" diff --stat HEAD -- web test | tr '\n' ' ')"; fi

echo "spec de feature com tela"
d="$(new_ui_repo spec-tela)"
cp "$HERE/ui/specs/avisos/briefing.md" "$d/briefing.md"
run_claude "$d" "/kit:spec tela de avisos no painel, descrita em briefing.md. O briefing já responde tudo: escopo, telas, estados, decisões, casos de borda e verificação; não há perguntas em aberto. Use o slug avisos."
calls="$(tools_called "$d.jsonl")"
S="$(find "$d/docs/specs" -name SPEC.md 2>/dev/null | head -n 1)"
if [ -n "$S" ]; then ok "SPEC.md gravada (${S#"$d"/})"; else ko "SPEC.md gravada" "$(final_text "$d.jsonl" | tail -n 10)"; fi
[ -n "$S" ] || S="$d/sem-spec.md"
telas="$(tr -d '\r' <"$S" 2>/dev/null | sed -n '/^## Telas/,/^## [^T]/p')"
if [ -n "$telas" ] && grep -q '/avisos' <<<"$telas"; then ok "SPEC.md com a seção Telas e a rota da tela"; else ko "SPEC.md com a seção Telas e a rota da tela" "$(grep -n '^## ' "$S" 2>&1 | tr '\n' ' ')"; fi
if grep -qi 'Estados:' <<<"$telas" && grep -qi 'vazio' <<<"$telas" && grep -qi 'carregando' <<<"$telas" && grep -qi 'erro' <<<"$telas" &&
  grep -q 'Nenhum aviso por enquanto' <<<"$telas"; then ok "Telas com os estados vazio, carregando e erro e o texto de cada um"
else ko "Telas com os estados vazio, carregando e erro e o texto de cada um" "$(head -n 12 <<<"$telas")"; fi
if grep -qi 'Tela pequena:' <<<"$telas" && grep -q '700' <<<"$telas" && grep -qi 'Padrão visual:' <<<"$telas" && grep -q 'web/tokens\.css' <<<"$telas" && grep -qi 'ação principal' <<<"$telas"; then
  ok "Telas com ação principal, tela pequena e padrão visual apontando os tokens do projeto"
else ko "Telas com ação principal, tela pequena e padrão visual apontando os tokens do projeto" "$(head -n 12 <<<"$telas")"; fi
order="$(grep -nE '^## (Telas|Casos de borda|Verificação ponta a ponta)$' <(tr -d '\r' <"$S" 2>/dev/null) | sed 's/^[0-9]*:## //' | paste -sd'|' -)"
if [ "$order" = "Telas|Casos de borda|Verificação ponta a ponta" ]; then ok "Telas vem antes de Casos de borda"; else ko "Telas vem antes de Casos de borda" "$order"; fi
if sed -n '/^## Verificação ponta a ponta/,$p' "$S" 2>/dev/null | grep -qE '360|1920'; then ok "Verificação ponta a ponta abre a tela no menor e no maior tamanho"
else ko "Verificação ponta a ponta abre a tela no menor e no maior tamanho" "$(sed -n '/^## Verificação ponta a ponta/,$p' "$S" 2>&1 | head -n 6)"; fi
if grep -qx 'Agent:kit:spec-reviewer\|Task:kit:spec-reviewer' <<<"$calls"; then ok "kit:spec-reviewer chamado"; else ko "kit:spec-reviewer chamado" "$(tr '\n' ' ' <<<"$calls")"; fi
if git -C "$d" diff --quiet HEAD -- web test; then ok "nenhum código de produção alterado"; else ko "nenhum código de produção alterado" "$(git -C "$d" diff --stat HEAD -- web test | tr '\n' ' ')"; fi

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
