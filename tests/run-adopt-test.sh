#!/usr/bin/env bash
# Teste de aceite ao vivo do modo adotar: roda /kit:init via `claude -p` num repo com .claude/ proprio
# e confere que so houve adicoes, que docs/claude-adoption.md foi gerado e que nada foi removido.
# Custa uma sessao do Claude Code (alguns minutos). Uso: tests/run-adopt-test.sh [--keep]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
PLUGIN="$REPO/plugins/kit"
MERGE="$PLUGIN/scripts/merge-json.sh"
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
gitq commit -m init
git -C "$P" ls-files | tr -d '\r' >"$W/tracked-before"

PROMPT='/kit:init Respostas pré-aprovadas (execução não interativa; não há como perguntar):
- Classificação das peças: aceite os destinos que você propuser.
- Gravação: sim, grave todas as adições propostas (.claude/kit.json, merge do .claude/settings.json, seções novas do CLAUDE.md e docs/claude-adoption.md).
- Marketplace do kit: r-matias/claude-kit.
- i18n: sim; strings/pt.json, en.json e es.json precisam ter as mesmas chaves.
- Arquivos acoplados: sim; mudanças em src/views/** exigem atualização em manual/**.
- Monorepo: não.'

echo "rodando /kit:init em $P (pode levar alguns minutos)..."
(cd "$P" && timeout 1500 claude -p "$PROMPT" --plugin-dir "$PLUGIN" --setting-sources project,local --permission-mode acceptEdits --allowedTools "Bash" "Write" "Edit" --max-turns 120 </dev/null >"$W/claude.out" 2>&1)
CODE=$?

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FALHA %s -- %s\n' "$1" "$2"; }

[ "$CODE" -eq 0 ] && ok "claude -p terminou com exit 0" || ko "claude -p terminou com exit 0" "exit $CODE"

missing=""
while IFS= read -r f; do [ -e "$P/$f" ] || missing+="$f "; done <"$W/tracked-before"
[ -z "$missing" ] && ok "nenhum arquivo existente removido" || ko "nenhum arquivo existente removido" "$missing"

[ "$(git -C "$P" rev-list --count HEAD | tr -d '\r')" = "1" ] && ok "nenhum commit criado (remocao exige confirmacao)" ||
  ko "nenhum commit criado (remocao exige confirmacao)" "$(git -C "$P" log --oneline | tr -d '\r')"

bad=""
while IFS= read -r f; do
  [ -e "$P/$f" ] || continue
  case "$f" in
    *.json)
      git -C "$P" show "HEAD:$f" >"$W/before.json"
      if ! bash "$MERGE" --check "$W/before.json" "$P/$f" 2>"$W/check.err"; then bad+="$f ($(tr '\n' ' ' <"$W/check.err")) "; fi ;;
    *)
      del="$(git -C "$P" diff --numstat HEAD -- "$f" | tr -d '\r' | awk '{ s += $2 } END { print s + 0 }')"
      [ "$del" = "0" ] || bad+="$f (-$del linhas) " ;;
  esac
done <"$W/tracked-before"
[ -z "$bad" ] && ok "arquivos existentes so receberam adicoes" || ko "arquivos existentes so receberam adicoes" "$bad"

A="$P/docs/claude-adoption.md"
if [ -f "$A" ]; then
  ok "docs/claude-adoption.md gerado"
  miss=""
  for piece in no-rm-rf manual-check review manual-sync i18n-checker docs-search; do
    grep -qi -- "$piece" "$A" || miss+="$piece "
  done
  [ -z "$miss" ] && ok "relatorio cobre todas as pecas do inventario" || ko "relatorio cobre todas as pecas do inventario" "faltam: $miss"
  grep -q '^## Registro de kit-skip' "$A" && ok "relatorio segue o modelo do adopt.md" || ko "relatorio segue o modelo do adopt.md" "sem a secao 'Registro de kit-skip' (adopt.md nao foi lido?)"
else
  ko "docs/claude-adoption.md gerado" "arquivo ausente"
fi

K="$P/.claude/kit.json"
if jq -e '.commands | length > 0' "$K" >/dev/null 2>&1; then ok ".claude/kit.json criado com commands"; else ko ".claude/kit.json criado com commands" "ausente ou sem commands"; fi
if jq -e '[.key_parity[]?.files[]?] | any(test("strings/en.json"))' "$K" >/dev/null 2>&1; then ok "key_parity declarado para strings"; else ko "key_parity declarado para strings" "$(jq -c '.key_parity' "$K" 2>&1)"; fi
if jq -e '[.coupled_changes[]? | (.when[]?, .require[]?)] | (any(test("src/views")) and any(test("manual")))' "$K" >/dev/null 2>&1; then ok "coupled_changes declarado para telas e manual"; else ko "coupled_changes declarado para telas e manual" "$(jq -c '.coupled_changes' "$K" 2>&1)"; fi

S="$P/.claude/settings.json"
if jq -e '.enabledPlugins["kit@claude-kit"] == true and (.extraKnownMarketplaces["claude-kit"] != null)' "$S" >/dev/null 2>&1; then ok "settings habilita kit@claude-kit"; else ko "settings habilita kit@claude-kit" "$(jq -c '{enabledPlugins, extraKnownMarketplaces}' "$S" 2>&1)"; fi
if jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test("no-rm-rf"))' "$S" >/dev/null 2>&1; then ok "hook original do projeto continua registrado"; else ko "hook original do projeto continua registrado" "entrada removida"; fi

echo
echo "$PASS passaram, $FAIL falharam"
if [ "$FAIL" -gt 0 ] || [ "$KEEP" -eq 1 ]; then
  echo "workspace mantido para inspecao: $W (saida do claude em $W/claude.out)"
else
  rm -rf "$W"
fi
[ "$FAIL" -eq 0 ]
