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

check "/kit:fix em repo recem-criado (sem commits)" "$W/fresh" fix "(sem commits)"
check "/kit:fix fora de repo git" "$W/nogit" fix "(não é repo git)"
check "/kit:hunt em repo recem-criado" "$W/fresh" hunt "(sem commits)"
check "/kit:execute fora de repo git" "$W/nogit" execute "(não é repo git)"
check "/kit:init fora de repo git" "$W/nogit" init "(não é repo git)"

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
