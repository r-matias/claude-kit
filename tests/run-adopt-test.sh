#!/usr/bin/env bash
# Teste de aceite ao vivo do modo adotar: roda /kit:init via `claude -p` num repo com CLAUDE.md, settings,
# skill, agent, rule e hooks proprios e confere por hash que CLAUDE.md, skills, agents, hooks, rules,
# MCP e settings.local.json nao mudaram, que o settings.json so ganhou itens (com backup identico ao
# original), que docs/claude-adoption.md foi gerado e que o deny de curl/wget fica de fora (a fixture
# tem uma skill que usa curl). Depois roda /kit:init num repositorio novo sem curl/wget: o deny entra, so os grupos marcados
# entram (permissions.groups no kit.json) e o settings do usuario nao muda.
# Custa duas sessoes do Claude Code (alguns minutos cada). Uso: tests/run-adopt-test.sh [--keep]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PLUGIN="$REPO/plugins/kit"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

command -v claude >/dev/null 2>&1 || { echo "claude CLI nao encontrada" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq nao encontrado" >&2; exit 1; }

# A fixture guarda a configuracao com nomes neutros para nao ser carregada no repo do kit.
materialize_adopt_repo() {
  local dest="$1"
  cp -r "$HERE/adopt/repo" "$dest"
  mv "$dest/_claude" "$dest/.claude"
  mv "$dest/_CLAUDE.md" "$dest/CLAUDE.md"
  mv "$dest/_mcp.json" "$dest/.mcp.json"
}

W="$(mktemp -d)"
P="$W/repo"
materialize_adopt_repo "$P"
gitq() { git -C "$P" -c user.name=kit-test -c user.email=kit@test -c init.defaultBranch=main -c core.autocrlf=false "$@" >/dev/null 2>&1; }
gitq init
gitq add -A
gitq add -f .claude/settings.local.json
gitq commit -m init
git -C "$P" ls-files | tr -d '\r' >"$W/tracked-before"
# Hash de todo arquivo rastreado: config do Claude Code e codigo do projeto.
(cd "$P" && tr '\n' '\0' <"$W/tracked-before" | xargs -0 sha256sum) | tr -d '\r' >"$W/hash-before"
grep -E ' [ *](CLAUDE\.md|\.mcp\.json|\.claude/.*)$' "$W/hash-before" | grep -vE ' [ *]\.claude/settings\.json$' >"$W/hash-config"
cp "$P/.claude/settings.json" "$W/settings.before"
# Settings do usuario: o init nunca grava nele.
USER_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
user_sum() { if [ -f "$USER_SETTINGS" ]; then cksum <"$USER_SETTINGS"; else echo ausente; fi; }
USER_SUM0="$(user_sum)"

PROMPT='/kit:init Respostas pré-aprovadas (execução não interativa; não há como perguntar):
- Classificação das peças: aceite os destinos que você propuser.
- Máquina: não instale dependência.
- Grupos de permissão: todos os oferecidos.
- Gravação: sim, grave tudo o que propuser (arquivos do kit, merge aditivo no .claude/settings.json e linhas do .gitignore).
- Instalação de language server: não instale nada.
- Mapa: não rode o /kit:map.
- Marketplace do kit: r-matias/claude-kit.
- i18n: sim; strings/pt.json, en.json e es.json precisam ter as mesmas chaves.
- Arquivos acoplados: sim; mudanças em src/views/** exigem atualização em manual/**.
- Monorepo: não.'

echo "rodando /kit:init em $P (pode levar alguns minutos)..."
(cd "$P" && timeout 1500 claude -p "$PROMPT" --plugin-dir "$PLUGIN" --setting-sources project,local --permission-mode acceptEdits --allowedTools "Bash" "Write" "Edit" "Write(./.claude/**)" "Edit(./.claude/**)" --max-turns 120 </dev/null >"$W/claude.out" 2>&1)
CODE=$?

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FALHA %s -- %s\n' "$1" "$2"; }

[ "$CODE" -eq 0 ] && ok "claude -p terminou com exit 0" || ko "claude -p terminou com exit 0" "exit $CODE"

missing=""
while IFS= read -r f; do [ -e "$P/$f" ] || missing+="$f "; done <"$W/tracked-before"
[ -z "$missing" ] && ok "nenhum arquivo existente removido" || ko "nenhum arquivo existente removido" "$missing"

[ "$(git -C "$P" rev-list --count HEAD | tr -d '\r')" = "1" ] && ok "nenhum commit criado" ||
  ko "nenhum commit criado" "$(git -C "$P" log --oneline | tr -d '\r')"

changed="$(cd "$P" && sha256sum -c --quiet "$W/hash-config" 2>/dev/null | tr -d '\r' | sed 's/: .*//' | paste -sd' ' -)"
n_config="$(wc -l <"$W/hash-config" | tr -d ' ')"
if [ -z "$changed" ] && [ "$n_config" -ge 10 ]; then ok "skills, agent, hooks, rule, CLAUDE.md, MCP e settings.local.json intactos (hash de $n_config arquivos)"
else ko "skills, agent, hooks, rule, CLAUDE.md, MCP e settings.local.json intactos" "alterados: ${changed:-nenhum} (conferidos: $n_config)"; fi
changed="$(cd "$P" && sha256sum -c --quiet "$W/hash-before" 2>/dev/null | tr -d '\r' | sed 's/: .*//' | grep -vxF -e .gitignore -e .claude/settings.json | paste -sd' ' -)"
[ -z "$changed" ] && ok "nenhum outro arquivo rastreado mudou" || ko "nenhum outro arquivo rastreado mudou" "$changed"

A="$P/docs/claude-adoption.md"
if [ -f "$A" ]; then
  ok "docs/claude-adoption.md gerado"
  miss=""
  for piece in no-rm-rf manual-check lint-hint block-generated review manual-sync fix publicar-previa status-api i18n-checker docs-search; do
    grep -qi -- "$piece" "$A" || miss+="$piece "
  done
  [ -z "$miss" ] && ok "relatorio cobre todas as pecas do inventario" || ko "relatorio cobre todas as pecas do inventario" "faltam: $miss"
  grep -q '^## Registro de kit-skip' "$A" && ok "relatorio segue o modelo do adopt.md" || ko "relatorio segue o modelo do adopt.md" "sem a secao 'Registro de kit-skip' (adopt.md nao foi lido?)"
  if grep -qF 'Skill(kit:fix)' "$A" && grep -qiE 'disable-model-invocation' "$A"; then ok "relatorio recomenda Skill(kit:fix) em deny e explica o motivo"; else ko "relatorio recomenda Skill(kit:fix) em deny e explica o motivo" "$(grep -n -i 'fix' "$A" | head -5)"; fi
  if grep -i 'lint-hint' "$A" | grep -qi 'mudo'; then ok "relatorio marca lint-hint como aviso possivelmente mudo"; else ko "relatorio marca lint-hint como aviso possivelmente mudo" "$(grep -n -i 'lint-hint' "$A" | head -3)"; fi
  if grep -i 'block-generated' "$A" | grep -qi 'falha aberta'; then ok "relatorio marca block-generated como falha aberta"; else ko "relatorio marca block-generated como falha aberta" "$(grep -n -i 'block-generated' "$A" | head -3)"; fi
else
  ko "docs/claude-adoption.md gerado" "arquivo ausente"
fi

K="$P/.claude/kit.json"
if jq -e '.commands | length > 0' "$K" >/dev/null 2>&1; then ok ".claude/kit.json criado com commands"; else ko ".claude/kit.json criado com commands" "ausente ou sem commands"; fi
if jq -e '[.key_parity[]?.files[]?] | any(test("strings/en.json"))' "$K" >/dev/null 2>&1; then ok "key_parity declarado para strings"; else ko "key_parity declarado para strings" "$(jq -c '.key_parity' "$K" 2>&1)"; fi
if jq -e '[.coupled_changes[]? | (.when[]?, .require[]?)] | (any(test("src/views")) and any(test("manual")))' "$K" >/dev/null 2>&1; then ok "coupled_changes declarado para telas e manual"; else ko "coupled_changes declarado para telas e manual" "$(jq -c '.coupled_changes' "$K" 2>&1)"; fi
if jq -e '[.protected_paths[]? | objects | select((.glob // "") | test("strings/generated")) | (.message // "")] | any(test("gerador|Edite"; "i"))' "$K" >/dev/null 2>&1; then
  ok "lista de bloqueio do projeto virou protected_paths com a mesma mensagem"
else ko "lista de bloqueio do projeto virou protected_paths com a mesma mensagem" "$(jq -c '.protected_paths' "$K" 2>&1)"; fi

S="$P/.claude/settings.json"
if bash "$PLUGIN/scripts/merge-json.sh" --check "$W/settings.before" "$S" 2>"$W/check.err"; then ok "settings.json só ganhou itens (nenhuma chave ou valor original sumiu ou mudou)"
else ko "settings.json só ganhou itens" "$(head -c 300 "$W/check.err")"; fi
bak="$(ls "$P"/.claude/settings.json.bak-kit-* 2>/dev/null | head -n 1)"
if [ -n "$bak" ] && cmp -s "$W/settings.before" "$bak"; then ok "backup do settings.json idêntico ao original"; else ko "backup do settings.json idêntico ao original" "${bak:-sem backup}"; fi
if jq -e --slurpfile b "$W/settings.before" '.hooks == $b[0].hooks' "$S" >/dev/null 2>&1; then ok "hooks do settings.json intocados"; else ko "hooks do settings.json intocados" "$(jq -c '.hooks' "$S" 2>&1 | head -c 300)"; fi
if jq -e '.enabledPlugins["kit@claude-kit"] == true and (.extraKnownMarketplaces["claude-kit"] != null)' "$S" >/dev/null 2>&1; then ok "settings.json habilita kit@claude-kit"; else ko "settings.json habilita kit@claude-kit" "$(jq -c '{enabledPlugins, extraKnownMarketplaces}' "$S" 2>&1)"; fi
if jq -e '(.permissions.deny // []) | index("Skill(kit:fix)") != null' "$S" >/dev/null 2>&1; then ok "settings.json traz Skill(kit:fix) em deny"; else ko "settings.json traz Skill(kit:fix) em deny" "$(jq -c '.permissions' "$S" 2>&1)"; fi
if jq -e '.enabledPlugins["typescript-lsp@claude-plugins-official"] == true' "$S" >/dev/null 2>&1; then ok "settings.json liga o plugin LSP oficial da linguagem"; else ko "settings.json liga o plugin LSP oficial da linguagem" "$(jq -c '.enabledPlugins' "$S" 2>&1)"; fi
if jq -e '[(.permissions.deny // [])[] | select(test("^Bash\\((curl|wget)"))] == []' "$S" >/dev/null 2>&1; then ok "settings.json sem deny de curl/wget (a skill status-api usa curl)"
else ko "settings.json sem deny de curl/wget (a skill status-api usa curl)" "$(jq -c '.permissions.deny' "$S" 2>&1)"; fi
if grep -qE 'curl/wget usados por [0-9]+ arquivos? do projeto[^;]*; deny não aplicado' "$W/claude.out"; then ok "relatório registra curl/wget usados e deny não aplicado"
else ko "relatório registra curl/wget usados e deny não aplicado" "$(tail -n 12 "$W/claude.out")"; fi
[ ! -e "$P/.claude/kit-settings.suggested.json" ] && ok "nenhum arquivo de sugestão gerado" || ko "nenhum arquivo de sugestão gerado" "kit-settings.suggested.json existe"
if grep -qF 'Próximo: /kit:spec' "$W/claude.out" && ! grep -qE 'run-skill-generator|/verify\b' "$W/claude.out"; then ok "relatório termina no /kit:spec, sem /run-skill-generator nem /verify"
else ko "relatório termina no /kit:spec, sem /run-skill-generator nem /verify" "$(tail -n 12 "$W/claude.out")"; fi

# Repositorio novo, sem .claude e sem curl/wget em lugar nenhum: o deny entra.
N="$W/novo"
cp -r "$HERE/plan/repo" "$N"
rm -rf "$N/.claude"
gitn() { git -C "$N" -c user.name=kit-test -c user.email=kit@test -c init.defaultBranch=main -c core.autocrlf=false "$@" >/dev/null 2>&1; }
gitn init
gitn add -A
gitn commit -m init
PROMPT_NOVO='/kit:init Respostas pré-aprovadas (execução não interativa; não há como perguntar):
- Máquina: não instale dependência.
- Grupos de permissão: marque segredos, git-destrutivo, push e curl-wget; desmarque sandbox e powershell.
- Gravação: sim, grave tudo o que propuser.
- Instalação de language server: não instale nada.
- Mapa: não rode o /kit:map.
- Marketplace do kit: r-matias/claude-kit.
- Monorepo: não.'
echo "rodando /kit:init num repositório novo sem curl em $N..."
(cd "$N" && timeout 1500 claude -p "$PROMPT_NOVO" --plugin-dir "$PLUGIN" --setting-sources project,local --permission-mode acceptEdits --allowedTools "Bash" "Write" "Edit" "Write(./.claude/**)" "Edit(./.claude/**)" --max-turns 80 </dev/null >"$W/novo.out" 2>&1)
if jq -e '(.permissions.deny // []) | (index("Bash(curl *)") != null and index("Bash(wget *)") != null)' "$N/.claude/settings.json" >/dev/null 2>&1; then
  ok "repositório novo sem curl/wget: settings.json com deny de curl e wget"
else ko "repositório novo sem curl/wget: settings.json com deny de curl e wget" "$(jq -c '.permissions.deny' "$N/.claude/settings.json" 2>&1)"; fi
if ! grep -qF 'deny não aplicado' "$W/novo.out"; then ok "repositório novo sem curl/wget: relatório sem aviso de deny não aplicado"
else ko "repositório novo sem curl/wget: relatório sem aviso de deny não aplicado" "$(grep -F 'deny não aplicado' "$W/novo.out")"; fi
if jq -e '(.permissions.groups | sort) == ["curl-wget", "git-destrutivo", "push", "segredos"]' "$N/.claude/kit.json" >/dev/null 2>&1 &&
  jq -e '(has("sandbox") | not) and ((.permissions.deny // []) | index("PowerShell") == null) and ((.permissions.deny // []) | index("Read(**/.env)") != null)' "$N/.claude/settings.json" >/dev/null 2>&1; then
  ok "repositório novo: só os grupos marcados entram e ficam em permissions.groups"
else ko "repositório novo: só os grupos marcados entram e ficam em permissions.groups" "$(jq -c '.permissions' "$N/.claude/kit.json" "$N/.claude/settings.json" 2>&1 | tr '
' ' ')"; fi
if [ "$(user_sum)" = "$USER_SUM0" ]; then ok "settings do usuário intacto depois dos dois /kit:init"; else ko "settings do usuário intacto depois dos dois /kit:init" "$USER_SETTINGS mudou"; fi

echo
echo "$PASS passaram, $FAIL falharam"
if [ "$FAIL" -gt 0 ] || [ "$KEEP" -eq 1 ]; then
  echo "workspace mantido para inspecao: $W (saida do claude em $W/claude.out)"
else
  rm -rf "$W"
fi
[ "$FAIL" -eq 0 ]
