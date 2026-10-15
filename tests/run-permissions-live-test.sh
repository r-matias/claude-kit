#!/usr/bin/env bash
# Teste ao vivo das regras de permissao que o kit usa, com um plugin minimo (tests/permissions/plugin):
# - allowed-tools de skill com Bash(bash "${CLAUDE_PLUGIN_ROOT}/...") e com ${CLAUDE_SKILL_DIR}/../.. liberam o script;
# - Read(${CLAUDE_PLUGIN_ROOT}/**) libera a leitura de arquivo do plugin fora do projeto;
# - sem allowed-tools, o mesmo Bash e o mesmo Read sao negados (controle);
# - Agent(<plugin>:<agent>) em permissions.deny bloqueia o subagent; Agent(<agent>) sem o prefixo nao.
# Roda em modo default, em que pedido de permissao no -p vira negacao. Custa algumas sessoes curtas.
# Uso: tests/run-permissions-live-test.sh [--keep]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$HERE/permissions/plugin"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

command -v claude >/dev/null 2>&1 || { echo "claude CLI nao encontrada" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq nao encontrado" >&2; exit 1; }

W="$(mktemp -d)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FALHA %s -- %s\n' "$1" "$2"; }

# Uso: run_claude <pasta> <saida> <prompt>
run_claude() {
  mkdir -p "$1"
  git -C "$1" init -q >/dev/null 2>&1
  (cd "$1" && timeout 300 claude -p "$3" --plugin-dir "$PLUGIN" --setting-sources project,local \
    --permission-mode default --model haiku --max-turns 6 --output-format stream-json --verbose </dev/null >"$2" 2>&1)
}
result_of() { grep '"type":"result"' "$1" | tail -n 1 | jq -r '.result // empty' 2>/dev/null; }
denied() { grep '"type":"result"' "$1" | tail -n 1 | jq -e --arg t "$2" '[.permission_denials[]?.tool_name] | index($t) != null' >/dev/null 2>&1; }

echo "claude $(claude --version 2>/dev/null | head -n 1)"
echo "rodando sessoes (alguns minutos)..."
for sk in viaroot viaskill noperm viarootread noread; do
  run_claude "$W/$sk" "$W/$sk.json" "/probe:$sk" &
done
for v in scoped bare; do
  mkdir -p "$W/agent-$v/.claude"
  case "$v" in scoped) r='Agent(probe:helper)' ;; bare) r='Agent(helper)' ;; esac
  jq -n --arg r "$r" '{permissions: {deny: [$r]}}' >"$W/agent-$v/.claude/settings.json"
  run_claude "$W/agent-$v" "$W/agent-$v.json" "Use a ferramenta Agent com subagent_type probe:helper e diga exatamente o que ela devolveu, ou o erro." &
done
wait

grep -qx 'MARK-root' "$W/viaroot/marks.txt" 2>/dev/null && ! denied "$W/viaroot.json" Bash &&
  ok 'allowed-tools Bash(bash "${CLAUDE_PLUGIN_ROOT}/...") libera o script' ||
  ko 'allowed-tools Bash(bash "${CLAUDE_PLUGIN_ROOT}/...") libera o script' "$(result_of "$W/viaroot.json" | head -c 200)"
grep -qx 'MARK-skill' "$W/viaskill/marks.txt" 2>/dev/null && ! denied "$W/viaskill.json" Bash &&
  ok 'allowed-tools Bash(bash "${CLAUDE_SKILL_DIR}/../../...") libera o script' ||
  ko 'allowed-tools Bash(bash "${CLAUDE_SKILL_DIR}/../../...") libera o script' "$(result_of "$W/viaskill.json" | head -c 200)"
[ ! -e "$W/noperm/marks.txt" ] && denied "$W/noperm.json" Bash &&
  ok "controle: sem allowed-tools o mesmo Bash e negado" ||
  ko "controle: sem allowed-tools o mesmo Bash e negado" "$(result_of "$W/noperm.json" | head -c 200)"
result_of "$W/viarootread.json" | grep -qF '#!/usr/bin/env bash' && ! denied "$W/viarootread.json" Read &&
  ok 'allowed-tools Read(${CLAUDE_PLUGIN_ROOT}/**) libera a leitura do plugin' ||
  ko 'allowed-tools Read(${CLAUDE_PLUGIN_ROOT}/**) libera a leitura do plugin' "$(result_of "$W/viarootread.json" | head -c 200)"
denied "$W/noread.json" Read &&
  ok "controle: sem allowed-tools a leitura do plugin e negada" ||
  ko "controle: sem allowed-tools a leitura do plugin e negada" "$(result_of "$W/noread.json" | head -c 200)"
grep -qF "denied by permission rule 'Agent(probe:helper)'" "$W/agent-scoped.json" && ! grep -qF 'PROBE-OK' "$W/agent-scoped.json" &&
  ok "Agent(probe:helper) em deny bloqueia o subagent do plugin" ||
  ko "Agent(probe:helper) em deny bloqueia o subagent do plugin" "$(result_of "$W/agent-scoped.json" | head -c 200)"
grep -qF 'PROBE-OK' "$W/agent-bare.json" &&
  ok "Agent(helper) sem o prefixo do plugin nao bloqueia (use Agent(kit:<nome>))" ||
  ko "Agent(helper) sem o prefixo do plugin nao bloqueia" "$(result_of "$W/agent-bare.json" | head -c 200)"

echo
echo "$PASS passaram, $FAIL falharam"
if [ "$FAIL" -gt 0 ] || [ "$KEEP" -eq 1 ]; then echo "workspace mantido: $W"; else rm -rf "$W"; fi
[ "$FAIL" -eq 0 ]
