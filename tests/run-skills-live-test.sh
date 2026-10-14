#!/usr/bin/env bash
# Teste ao vivo do carregamento das skills: os comandos ! de git precisam funcionar
# num repo recem-criado (sem commits) e fora de um repo git, sem erro de permissao.
# Custa algumas sessoes curtas do Claude Code. Uso: tests/run-skills-live-test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)/plugins/kit"
command -v claude >/dev/null 2>&1 || { echo "claude CLI nao encontrada" >&2; exit 1; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fresh" "$W/nogit"
git -C "$W/fresh" -c init.defaultBranch=main init -q

PASS=0
FAIL=0

# Uso: check <rotulo> <pasta> <skill> <texto-esperado>
check() {
  local label="$1" dir="$2" skill="$3" want="$4" out
  out="$(cd "$dir" && timeout 300 claude -p "/kit:$skill Teste de carga da skill: não investigue, não edite e não rode nada. Responda apenas com o conteúdo exato da seção 'Estado atual' que você recebeu, dentro de um bloco de código." \
    --plugin-dir "$PLUGIN" --setting-sources project,local --max-turns 2 </dev/null 2>&1)"
  if printf '%s' "$out" | grep -qF -- "$want" && ! printf '%s' "$out" | grep -qiE 'permission check failed|can.t be checked|Shell command'; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FALHA %s -- esperava "%s"; saida:\n%s\n' "$label" "$want" "$(printf '%s' "$out" | tail -n 15)"
  fi
}

# Uso: check_deny <rotulo> <settings-json> <esperado-skill> <esperado-agent>
check_deny() {
  local label="$1" settings="$2" want_skill="$3" want_agent="$4" d out
  d="$(mktemp -d "$W/deny.XXXXXX")"
  git -C "$d" init -q
  mkdir -p "$d/.claude"
  printf '%s' "$settings" >"$d/.claude/settings.json"
  out="$(cd "$d" && timeout 300 claude -p "Faça exatamente duas chamadas de ferramenta, nesta ordem: (1) a ferramenta Skill com skill 'kit:fix' e args 'teste de permissão: não investigue nem edite nada, só responda ok'; (2) a ferramenta Agent com subagent_type 'kit:code-reviewer' e prompt 'responda apenas ok, sem rodar nada'. Não faça mais nada. No fim responda só duas linhas: 'SKILL: BLOQUEADO' ou 'SKILL: EXECUTOU', e 'AGENT: BLOQUEADO' ou 'AGENT: EXECUTOU', conforme o resultado real de cada chamada." \
    --plugin-dir "$PLUGIN" --setting-sources project,local --allowedTools "Skill" "Agent" --max-turns 8 </dev/null 2>&1)"
  if printf '%s' "$out" | grep -qF "SKILL: $want_skill" && printf '%s' "$out" | grep -qF "AGENT: $want_agent"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FALHA %s -- esperava SKILL: %s e AGENT: %s; saida:\n%s\n' "$label" "$want_skill" "$want_agent" "$(printf '%s' "$out" | tail -n 10)"
  fi
}

check_deny "deny Skill(kit:fix) e Agent(kit:code-reviewer) bloqueiam" \
  '{"permissions":{"deny":["Skill(kit:fix)","Agent(kit:code-reviewer)"]}}' BLOQUEADO BLOQUEADO
check_deny "controle: sem deny a skill e o agent do kit executam" '{}' EXECUTOU EXECUTOU

check "/kit:fix em repo recem-criado (sem commits)" "$W/fresh" fix "(sem commits)"
check "/kit:fix fora de repo git" "$W/nogit" fix "(não é repo git)"
check "/kit:hunt em repo recem-criado" "$W/fresh" hunt "(sem commits)"
check "/kit:execute fora de repo git" "$W/nogit" execute "(não é repo git)"
check "/kit:init fora de repo git" "$W/nogit" init "(não é repo git)"

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
