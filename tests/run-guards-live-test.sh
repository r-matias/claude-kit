#!/usr/bin/env bash
# Teste ao vivo do onFailure: "block": com o script de um guarda ausente, a acao precisa ser
# bloqueada. O resultado e conferido no disco (arquivo-sonda criado ou nao), nao na resposta
# do modelo. Requer Claude Code >= 2.1.295. Uso: tests/run-guards-live-test.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SRC="$(cd "$HERE/.." && pwd)/plugins/kit"
MIN="2.1.295"

command -v claude >/dev/null 2>&1 || { echo "claude CLI nao encontrada" >&2; exit 1; }
CV="$(claude --version 2>/dev/null | tr -d '\r' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
if [ -z "$CV" ] || [ "$(printf '%s\n%s\n' "$CV" "$MIN" | sort -V | head -n 1)" != "$MIN" ]; then
  echo "Claude Code $MIN ou maior e necessario (encontrado: ${CV:-desconhecido})" >&2
  exit 1
fi

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

# Uso: check <rotulo> <script-a-remover|nenhum> <ferramenta Bash|Write> <deve-existir 0|1> [sem-onfailure]
check() {
  local label="$1" missing="$2" tool="$3" want="$4" mode="${5:-}" d plugin prompt out
  d="$(mktemp -d "$W/proj.XXXXXX")"
  git -C "$d" init -q
  plugin="$d.plugin"
  cp -r "$PLUGIN_SRC" "$plugin"
  [ "$missing" != "nenhum" ] && rm -f "$plugin/scripts/$missing"
  if [ "$mode" = "sem-onfailure" ]; then
    jq 'del(.. | .onFailure?)' "$plugin/hooks/hooks.json" >"$plugin/hooks/hooks.tmp" && mv "$plugin/hooks/hooks.tmp" "$plugin/hooks/hooks.json"
  fi
  if [ "$tool" = "Bash" ]; then
    prompt="Rode exatamente este comando com a ferramenta Bash, uma única vez: echo sonda > sonda.txt . Não tente de outro jeito se falhar. Depois responda só FIM."
  else
    prompt="Crie o arquivo sonda.txt com o conteúdo 'sonda' usando a ferramenta Write, uma única vez. Não tente de outro jeito se falhar. Depois responda só FIM."
  fi
  out="$(cd "$d" && timeout 300 claude -p "$prompt" --plugin-dir "$plugin" --setting-sources project,local \
    --permission-mode acceptEdits --allowedTools "$tool" --max-turns 3 </dev/null 2>&1)"
  if { [ "$want" = "1" ] && [ -f "$d/sonda.txt" ]; } || { [ "$want" = "0" ] && [ ! -f "$d/sonda.txt" ]; }; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FALHA %s -- sonda.txt %s; saida:\n%s\n' "$label" \
      "$([ -f "$d/sonda.txt" ] && echo "foi criado" || echo "nao foi criado")" "$(printf '%s' "$out" | tail -n 8)"
  fi
}

echo "Claude Code $CV"
check "guard-bash.sh ausente: Bash bloqueado" guard-bash.sh Bash 0
check "controle: guard-bash.sh presente, Bash liberado" nenhum Bash 1
check "guard-files.sh ausente: Write bloqueado" guard-files.sh Write 0
check "controle: guard-files.sh presente, Write liberado" nenhum Write 1
check "contraprova: guard-bash.sh ausente sem onFailure deixa passar" guard-bash.sh Bash 1 sem-onfailure

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
