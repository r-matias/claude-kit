#!/usr/bin/env bash
# Teste ao vivo de calibracao dos revisores: plano e diff com defeitos plantados (dependencia na
# mesma wave, Paralelo com arquivo em comum, migracao sem backup, caso de borda sem teste) precisam
# sair com o id e a severidade certos e veredito "reprovado"; plano e diff limpos precisam sair
# "aprovado" (pega rigidez excessiva). Le a resposta do subagent no transcript (stream-json).
# Custa quatro sessoes do Claude Code, em paralelo. Uso: tests/run-reviewers-live-test.sh [--keep]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)/plugins/kit"
FX="$HERE/reviewers"
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

# Uso: setup_case <nome> <plano> [diff]. Repo com o plano commitado; com diff, um segundo commit com a tarefa 2.
setup_case() {
  local d="$W/$1"
  cp -r "$FX/repo" "$d"
  cp "$FX/plans/$2.md" "$d/docs/specs/apelido/PLAN.md"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" -c core.autocrlf=false add -A
  git -C "$d" -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test commit -qm base
  if [ -n "${3:-}" ]; then
    cp -r "$FX/diffs/$3/." "$d/"
    git -C "$d" -c core.autocrlf=false add -A
    git -C "$d" -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test commit -qm "tarefa 2"
  fi
}

# Uso: run_review <nome> <prompt>. Grava o transcript em $W/<nome>.jsonl.
run_review() {
  (cd "$W/$1" && timeout 1200 claude -p "$2" --plugin-dir "$PLUGIN" \
    --setting-sources project,local --permission-mode acceptEdits --allowedTools "Agent" "Read" "Grep" "Glob" "Bash" \
    --max-turns 40 --output-format stream-json --verbose </dev/null >"$W/$1.jsonl" 2>"$W/$1.err")
}

# Resposta do subagent $2 no transcript $1 (o tool_result da ultima chamada); sem ela, o texto final.
review_text() {
  local id out
  id="$(jq -r --arg a "$2" 'select(.type == "assistant") | .message.content[]?
    | select(.type == "tool_use" and (.name == "Agent" or .name == "Task") and .input.subagent_type == $a) | .id' "$1" 2>/dev/null | tr -d '\r' | tail -n 1)"
  if [ -n "$id" ]; then
    out="$(jq -r --arg id "$id" 'select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .tool_use_id == $id)
      | .content | if type == "string" then . else (map(.text // "") | join("\n")) end' "$1" 2>/dev/null | tr -d '\r')"
  fi
  [ -n "${out:-}" ] || out="$(jq -r 'select(.type == "result") | .result // empty' "$1" 2>/dev/null | tr -d '\r')"
  # O tool_result traz um cabecalho de hand-back antes da resposta e agentId/usage depois dela.
  printf '%s\n' "$out" | grep -v '^\[Subagent hand-back\]' | awk '/^agentId: / { exit } { print }'
}

# Achados como "SEVERIDADE ids", um por linha (tolera marcador de lista, negrito e crases). Um achado
# pode citar mais de um id ("B1/M1") quando casa com duas regras.
findings() {
  tr -d '`*' | sed -E 's/^[[:space:]]*([-0-9.]+[[:space:]]+)?//' |
    grep -E '^(BLOCKER|MAJOR|MINOR)[[:space:]]*\[[^]]*\]' | sed -E 's/^(BLOCKER|MAJOR|MINOR)[[:space:]]*\[([^]]*)\].*/\1 \2/' | awk '{ s = $1; $1 = ""; gsub(/ /, ""); print s, $0 }'
}

verdict() {
  tr -d '`*.:!' | awk 'NF { l = $0 } END { print tolower(l) }' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

# Severidade igual a do id mais grave citado: B* e BLOCKER, M* e MAJOR, MINOR sem id de regra.
check_consistency() {
  local label="$1" f="$2" bad
  bad="$(awk '{ want = "MINOR"; n = split($2, ids, /[\/, ]+/)
    for (i = 1; i <= n; i++) { if (ids[i] ~ /^B[0-9]/) want = "BLOCKER"; else if (ids[i] ~ /^M[0-9]/ && want != "BLOCKER") want = "MAJOR" }
    if ($1 != want) print }' <<<"$f")"
  if [ -z "$bad" ]; then ok "$label: severidade de cada achado igual à do id"; else ko "$label: severidade de cada achado igual à do id" "$(tr '\n' ';' <<<"$bad")"; fi
}

# Uso: expect_bad <rotulo> <texto> <id>... Cada id precisa aparecer em algum achado; a severidade
# vem do check_consistency.
expect_bad() {
  local label="$1" text="$2" f v want
  shift 2
  f="$(findings <<<"$text")"
  for want in "$@"; do
    if awk -v w="$want" '{ n = split($2, ids, /[\/,]+/); for (i = 1; i <= n; i++) if (ids[i] == w) found = 1 } END { exit !found }' <<<"$f"; then
      ok "$label: achado [$want]"
    else ko "$label: achado [$want]" "achados: $(tr '\n' ';' <<<"$f")"; fi
  done
  check_consistency "$label" "$f"
  v="$(verdict <<<"$text")"
  if [ "$v" = "reprovado" ]; then ok "$label: veredito reprovado"; else ko "$label: veredito reprovado" "última linha: '$v'"; fi
}

expect_clean() {
  local label="$1" text="$2" f v serious
  f="$(findings <<<"$text")"
  serious="$(grep -E '^(BLOCKER|MAJOR) ' <<<"$f" || true)"
  if [ -z "$serious" ]; then ok "$label: nenhum BLOCKER ou MAJOR"; else ko "$label: nenhum BLOCKER ou MAJOR" "$(tr '\n' ';' <<<"$serious") -- $(grep -E 'BLOCKER|MAJOR' <<<"$text" | head -n 4 | tr '\n' ' ')"; fi
  v="$(verdict <<<"$text")"
  if [ "$v" = "aprovado" ]; then ok "$label: veredito aprovado"; else ko "$label: veredito aprovado" "última linha: '$v'"; fi
}

SPEC="docs/specs/apelido/SPEC.md"
PLAN="docs/specs/apelido/PLAN.md"
PLAN_PROMPT="Chame o subagent kit:plan-reviewer para revisar $PLAN contra $SPEC. Não revise você mesmo e não edite nada. Quando ele responder, repita a resposta dele literalmente, sem comentar."

setup_case plano-ruim ruim
setup_case plano-limpo limpo
setup_case diff-ruim limpo ruim
setup_case diff-limpo limpo limpo
echo "rodando as quatro revisões em $W (alguns minutos)..."
run_review plano-ruim "$PLAN_PROMPT" &
run_review plano-limpo "$PLAN_PROMPT" &
for c in diff-ruim diff-limpo; do
  base="$(git -C "$W/$c" rev-parse HEAD~1 | tr -d '\r')"
  run_review "$c" "Chame o subagent kit:code-reviewer para revisar o diff da tarefa 2 (wave 1) do plano $PLAN, com a SPEC em $SPEC. O diff é \`git diff $base HEAD\` e contém só a tarefa 2; a tarefa 1 fica num diff separado e está fora desta revisão. Não revise você mesmo e não edite nada. Quando ele responder, repita a resposta dele literalmente, sem comentar." &
done
wait

echo "plano com defeitos"
expect_bad "plano ruim" "$(review_text "$W/plano-ruim.jsonl" kit:plan-reviewer)" B1 B2 B5
echo "plano limpo"
expect_clean "plano limpo" "$(review_text "$W/plano-limpo.jsonl" kit:plan-reviewer)"
echo "diff com caso de borda sem teste"
expect_bad "diff ruim" "$(review_text "$W/diff-ruim.jsonl" kit:code-reviewer)" M1
echo "diff limpo"
expect_clean "diff limpo" "$(review_text "$W/diff-limpo.jsonl" kit:code-reviewer)"

for c in plano-ruim plano-limpo diff-ruim diff-limpo; do
  if git -C "$W/$c" diff --quiet HEAD && [ -z "$(git -C "$W/$c" status --porcelain | tr -d '\r')" ]; then ok "$c: nenhum arquivo alterado"; else ko "$c: nenhum arquivo alterado" "$(git -C "$W/$c" status --short | tr '\n' ' ')"; fi
done

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
