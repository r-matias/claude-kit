#!/usr/bin/env bash
# Teste ao vivo de interface, num projeto com tela (tests/ui/repo):
# - init: /kit:init propoe o "ui" do kit.json e grava .claude/rules/kit-ui.md, sem acrescentar plugin
#   de terceiro ao settings. A captura roda de verdade com o kit.json gravado.
# - execute: /kit:execute num plano de uma tela roda a sondagem no checkpoint, a captura completa na
#   wave final e chama o kit:ui-reviewer; a tela entregue passa numa captura feita por fora.
# Confere no disco e no transcript (stream-json). Exige node e um navegador Chromium.
# Gravar em .claude/ pede aprovacao e claude -p nao tem quem aprove: se a sessao do init esbarra nisso
# e diz que nao gravou, as conferencias que dependem dos arquivos saem como "pulado", nao como falha.
# Custa duas sessoes do Claude Code; a do execute e longa. Uso: tests/run-ui-live-test.sh [--keep] [init|execute]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(cd "$HERE/.." && pwd)/plugins/kit"
UIS="$PLUGIN/scripts/ui.sh"
KEEP=0
FILTER=""
for a in "$@"; do
  case "$a" in --keep) KEEP=1 ;; *) FILTER="$a" ;; esac
done

command -v claude >/dev/null 2>&1 || { echo "claude CLI nao encontrada" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq nao encontrado" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node nao encontrado (a fixture e a captura usam node)" >&2; exit 1; }
bash "$UIS" status "$HERE/ui/repo" 2>/dev/null | grep -q '^navegador: ok' || { echo "nenhum navegador Chromium encontrado (a captura precisa de um)" >&2; exit 1; }

ALL_CASES="init execute"
CASES=""
for c in $ALL_CASES; do
  case "$c" in *"$FILTER"*) CASES="$CASES $c" ;; esac
done
[ -n "$CASES" ] || { echo "nenhum caso casa o filtro '$FILTER'; casos: $ALL_CASES" >&2; exit 1; }
want() { case " $CASES " in *" $1 "*) return 0 ;; esac; return 1; }

W="$(mktemp -d)"
if [ "$KEEP" = "1" ]; then echo "workspace mantido em $W"; else trap 'rm -rf "$W"' EXIT; fi
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  FALHA %s -- %s\n' "$1" "$2"; }

URL="http://127.0.0.1:41873"
url_up() { node -e 'const q = require("http").get(process.argv[1], { timeout: 1500 }, (r) => { r.resume(); process.exit(0); }); q.on("error", () => process.exit(1)); q.on("timeout", () => { q.destroy(); process.exit(1); });' "$1"; }
if url_up "$URL/"; then echo "a porta 41873 ja esta em uso; pare o que responde em $URL" >&2; exit 1; fi

USER_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
user_sum() { if [ -f "$USER_SETTINGS" ]; then cksum <"$USER_SETTINGS"; else echo ausente; fi; }
USER_SUM0="$(user_sum)"

gitq() { git -C "$1" -c init.defaultBranch=main -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test "${@:2}" >/dev/null 2>&1; }

# Uso: new_repo <nome>. Copia o projeto com tela e commita. Ecoa a pasta.
new_repo() {
  local d="$W/$1"
  cp -r "$HERE/ui/repo" "$d"
  printf '%s' "$d"
}

final_text() { jq -r 'select(.type == "result") | .result // empty' "$1" 2>/dev/null | tr -d '\r'; }

# Comandos de Bash e agents chamados, um por linha: "bash <comando>" ou "agent <tipo> <prompt>".
events() {
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
    | if .name == "Bash" then "bash\t" + ((.input.command // "") | gsub("[\t\n\r]"; " "))
      elif .name == "Agent" or .name == "Task" then "agent\t" + (.input.subagent_type // "general-purpose") + "\t" + ((.input.prompt // "") | gsub("[\t\n\r]"; " "))
      else empty end' "$1" 2>/dev/null | tr -d '\r'
}

INIT_PROMPT='/kit:init Respostas pré-aprovadas (execução não interativa; não há como perguntar):
- Máquina: não instale dependência.
- Grupos de permissão: todos os oferecidos.
- Gravação: sim, grave tudo o que propuser (arquivos do kit, .claude/settings.json, .claude/rules/kit-ui.md, CLAUDE.md e linhas do .gitignore).
- Instalação de language server: não instale nada.
- Notificações: nenhuma.
- Mapa: não rode o /kit:map.
- Marketplace do kit: r-matias/claude-kit.
- Monorepo: não.'

# Uso: run_init <pasta> <prompt>. Transcript em <pasta>.jsonl.
run_init() {
  (cd "$1" && timeout 1800 claude -p "$2" --plugin-dir "$PLUGIN" \
    --setting-sources project,local --permission-mode acceptEdits \
    --allowedTools "Bash" "Read" "Glob" "Grep" "Write" "Edit" "Write(./.claude/**)" "Edit(./.claude/**)" \
    --max-turns 120 --output-format stream-json --verbose </dev/null >"$1.jsonl" 2>"$1.err")
}

# 0 se a sessao teve a escrita em .claude/ negada por falta de aprovacao e nao gravou o kit.json.
write_denied() {
  [ ! -f "$1/.claude/kit.json" ] && jq -e 'select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)
    | .content | (if type == "string" then . else (map(.text // "") | join(" ")) end) | test("sensitive file|require approval")' "$1.jsonl" >/dev/null 2>&1
}

# Conferencias do init. Devolve 1 se a sessao nao pode gravar em .claude/.
check_init() {
  local d="$1" label="$2" K R text globs g f hit bad
  K="$d/.claude/kit.json"
  R="$d/.claude/rules/kit-ui.md"
  text="$(final_text "$d.jsonl")"
  if events "$d.jsonl" | grep -q $'^bash\t.*ui\.sh"\{0,1\} status'; then ok "$label: ui.sh status rodou"; else ko "$label: ui.sh status rodou" "sem a chamada no transcript"; fi
  if write_denied "$d"; then
    if grep -qF '.claude' <<<"$text" && grep -qiE 'não (foi|foram) gravad|não gravad|incompleto' <<<"$text"; then ok "$label: sem aprovação para gravar em .claude/, o relatório diz o que ficou sem gravar"
    else ko "$label: sem aprovação para gravar em .claude/, o relatório diz o que ficou sem gravar" "$(tail -n 8 <<<"$text")"; fi
    echo "  pulado $label: kit.json, rule e captura (a sessão não pôde gravar em .claude/; em claude -p não há quem aprove)"
    return 1
  fi
  if [ -f "$K" ] && jq -e '.ui | type == "object" and (.globs | type == "array" and length > 0)' "$K" >/dev/null 2>&1; then ok "$label: kit.json com ui.globs"
  else ko "$label: kit.json com ui.globs" "$(jq -c '.ui' "$K" 2>&1 | head -c 300) $(tail -n 5 <<<"$text")"; fi
  [ -f "$K" ] || printf '{}\n' >"$K"
  globs="$(jq -r '.ui.globs[]?' "$K" 2>/dev/null | tr -d '\r')"
  bad=""
  for f in web/index.html web/style.css web/tokens.css; do
    hit=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      bash -c '. "$1/lib.sh"; glob_match "$2" "$3"' _ "$PLUGIN/scripts" "$g" "$f" && { hit=1; break; }
    done <<<"$globs"
    [ "$hit" = "1" ] || bad+="$f "
  done
  if [ -n "$globs" ] && [ -z "$bad" ]; then ok "$label: ui.globs casa as telas e os estilos do projeto"
  else ko "$label: ui.globs casa as telas e os estilos do projeto" "sem glob: $bad; globs: $(tr '\n' ' ' <<<"$globs")"; fi
  if jq -e '(.ui.dev | type == "string" and test("npm run dev|node server\\.mjs")) and (.ui.url | test("^http://(127\\.0\\.0\\.1|localhost):41873/?$"))' "$K" >/dev/null 2>&1; then
    ok "$label: ui.dev e ui.url do servidor do projeto"
  else ko "$label: ui.dev e ui.url do servidor do projeto" "$(jq -c '{dev: .ui.dev, url: .ui.url}' "$K" 2>&1)"; fi
  if ! bash "$PLUGIN/scripts/setup.sh" guards "$K" 2>&1 | grep -q 'inválido: ui'; then ok "$label: setup guards não acusa nada no ui"
  else ko "$label: setup guards não acusa nada no ui" "$(bash "$PLUGIN/scripts/setup.sh" guards "$K" 2>&1 | grep 'ui' | tr '\n' ' ')"; fi
  if [ -f "$R" ] && grep -qx 'paths:' <(tr -d '\r' <"$R") && grep -qxF '<!-- kit:ui v2 -->' <(tr -d '\r' <"$R") && grep -qF 'web/tokens.css' "$R"; then
    ok "$label: .claude/rules/kit-ui.md com paths, cabeçalho kit:ui e os tokens do projeto"
  else ko "$label: .claude/rules/kit-ui.md com paths, cabeçalho kit:ui e os tokens do projeto" "$(head -n 12 "$R" 2>&1 | tr '\n' '|')"; fi
  bad=""
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    grep -qxF -- "$g" <(tr -d '\r' <"$R" 2>/dev/null) || bad+="[${g:0:40}] "
  done < <(tr -d '\r' <"$PLUGIN/skills/execute/ui-rules.md")
  if [ -z "$bad" ]; then ok "$label: a rule traz o bloco de ui-rules.md sem mudar uma palavra"; else ko "$label: a rule traz o bloco de ui-rules.md sem mudar uma palavra" "linhas ausentes: $bad"; fi
  if grep -qiE 'interface:\**[[:space:]]' <<<"$text" && grep -qF 'Pronto. Próximo: /kit:design, depois /kit:spec' <<<"$text"; then ok "$label: relatório com a linha de interface e a direção visual antes da SPEC"
  else ko "$label: relatório com a linha de interface e a direção visual antes da SPEC" "$(tail -n 12 <<<"$text")"; fi
  if ! ls "$d/.claude/rules/" 2>/dev/null | grep -q '^kit-design'; then ok "$label: o init não grava rule de direção"
  else ko "$label: o init não grava rule de direção" "$(ls "$d/.claude/rules/" | tr '\n' ' ')"; fi
  if (cd "$d" && bash "$UIS" capture --probe-only --name aceite >"$d.capture" 2>&1); then ok "$label: a captura roda com o kit.json gravado e sai sem achado"
  else ko "$label: a captura roda com o kit.json gravado e sai sem achado" "$(tail -n 6 "$d.capture" | tr '\n' ' ')"; fi
  if [ "$(git -C "$d" rev-list --count HEAD | tr -d '\r')" = "1" ]; then ok "$label: nenhum commit criado"; else ko "$label: nenhum commit criado" "$(git -C "$d" log --oneline | tr -d '\r')"; fi
  return 0
}

if want init; then
  d="$(new_repo init)"
  gitq "$d" init
  gitq "$d" add -A
  gitq "$d" commit -m init
  echo "rodando /kit:init em $W (alguns minutos)..."
  run_init "$d" "$INIT_PROMPT"
  echo "init num projeto com tela"
  if check_init "$d" "init"; then
    # A interface nao acrescenta plugin nem marketplace ao settings: a captura e do proprio kit.
    if [ -f "$d/.claude/settings.json" ] && ! grep -qiE 'dev-browser|playwright|puppeteer' "$d/.claude/settings.json"; then
      ok "init: a interface não acrescenta plugin de navegador ao settings"
    else ko "init: a interface não acrescenta plugin de navegador ao settings" "$(jq -c '{enabledPlugins, extraKnownMarketplaces}' "$d/.claude/settings.json" 2>&1 | head -c 500)"; fi
    if [ "$(bash "$UIS" status "$d" 2>/dev/null | tr -d '\r' | grep '^rule: ')" = "rule: ok" ]; then ok "init: ui.sh status diz rule: ok para a rule gravada"
    else ko "init: ui.sh status diz rule: ok para a rule gravada" "$(bash "$UIS" status "$d" 2>&1 | grep '^rule' | tr '\n' ' ')"; fi
  fi
fi

if want execute; then
  echo "execute num plano com uma tela"
  d="$(new_repo execute)"
  mkdir -p "$d/.claude" "$d/docs/specs/avisos"
  jq '.ui.globs = ["web/**/*.html", "web/**/*.css"]' "$HERE/ui/kit.json" >"$d/.claude/kit.json"
  cp "$HERE/ui/specs/avisos/SPEC.md" "$HERE/ui/specs/avisos/PLAN.md" "$d/docs/specs/avisos/"
  printf '.claude/state/\n' >"$d/.gitignore"
  gitq "$d" init
  gitq "$d" add -A
  gitq "$d" commit -m init
  P="$d/docs/specs/avisos/PLAN.md"
  T="$d.jsonl"
  echo "rodando /kit:execute em $d (pode levar bastante)..."
  (cd "$d" && timeout 3300 claude -p "/kit:execute docs/specs/avisos/PLAN.md" --plugin-dir "$PLUGIN" \
    --setting-sources project,local --permission-mode acceptEdits \
    --allowedTools "Bash" "Read" "Write" "Edit" "Glob" "Grep" "Agent" \
    --max-turns 200 --output-format stream-json --verbose </dev/null >"$T" 2>"$d.err")
  CODE=$?
  plan="$(tr -d '\r' <"$P")"
  events "$T" >"$W/events.tsv"

  [ "$CODE" -eq 0 ] && ok "claude -p terminou com exit 0" || ko "claude -p terminou com exit 0" "exit $CODE; $(tail -c 300 "$d.err")"
  if (cd "$d" && node --test >"$W/suite.out" 2>&1); then ok "node --test passa"; else ko "node --test passa" "$(tail -n 15 "$W/suite.out")"; fi
  pending="$(grep -E '^- \[ \]' <<<"$plan" || true)"
  if [ -z "$pending" ]; then ok "todas as caixas marcadas"; else ko "todas as caixas marcadas" "$pending"; fi

  probes="$(grep -c $'^bash\t.*ui\.sh"\{0,1\} capture.*--probe-only' "$W/events.tsv")"
  fulls="$(grep $'^bash\t.*ui\.sh"\{0,1\} capture' "$W/events.tsv" | grep -vc -- '--probe-only')"
  if [ "$probes" -ge 1 ]; then ok "sondagem no checkpoint da wave com tela ($probes chamadas com --probe-only)"; else ko "sondagem no checkpoint da wave com tela" "nenhuma chamada de ui.sh capture --probe-only"; fi
  if [ "$fulls" -ge 1 ]; then ok "captura completa na wave final ($fulls chamadas)"; else ko "captura completa na wave final" "nenhuma chamada de ui.sh capture sem --probe-only"; fi
  if grep $'^bash\t.*ui\.sh"\{0,1\} capture' "$W/events.tsv" | grep -q 'dados=vazio' && grep $'^bash\t.*ui\.sh"\{0,1\} capture' "$W/events.tsv" | grep -q 'dados=erro'; then
    ok "captura nas rotas da seção Telas, com os estados vazio e erro"
  else ko "captura nas rotas da seção Telas, com os estados vazio e erro" "$(grep $'^bash\t.*ui\.sh"\{0,1\} capture' "$W/events.tsv" | cut -c1-300 | tr '\n' '|')"; fi

  ur="$(grep -c $'^agent\tkit:ui-reviewer\t' "$W/events.tsv")"
  if [ "$ur" -ge 1 ] && grep $'^agent\tkit:ui-reviewer\t' "$W/events.tsv" | grep -q '\.claude/state/ui/'; then
    ok "kit:ui-reviewer chamado com a pasta da captura ($ur chamadas)"
  else ko "kit:ui-reviewer chamado com a pasta da captura" "chamadas: $ur; $(grep $'^agent\tkit:ui-reviewer\t' "$W/events.tsv" | cut -c1-300)"; fi
  cr="$(grep -c $'^agent\tkit:code-reviewer\t' "$W/events.tsv")"
  sr="$(grep -c $'^agent\tkit:security-reviewer\t' "$W/events.tsv")"
  if [ "$cr" -ge 2 ] && [ "$sr" -ge 1 ]; then ok "code-reviewer e security-reviewer seguem na wave final ($cr e $sr)"; else ko "code-reviewer e security-reviewer seguem na wave final" "code=$cr security=$sr"; fi

  # Ultima resposta do ui-reviewer: precisa terminar em aprovado. Com o agent em segundo plano, o
  # tool_result so traz o aviso de lancamento: a resposta e a ultima mensagem de texto do subagent.
  ureply="$(jq -rs '[.[] | select(.type == "assistant" and .subagent_type == "kit:ui-reviewer") | [.message.content[]? | select(.type == "text") | .text] | join("\n") | select(length > 0)] | last // ""' "$T" 2>/dev/null | tr -d '\r')"
  if [ -z "$ureply" ]; then
    uid="$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and (.name == "Agent" or .name == "Task") and .input.subagent_type == "kit:ui-reviewer") | .id' "$T" 2>/dev/null | tr -d '\r' | tail -n 1)"
    ureply="$(jq -r --arg id "$uid" 'select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .tool_use_id == $id)
      | .content | if type == "string" then . else (map(.text // "") | join("\n")) end' "$T" 2>/dev/null | tr -d '\r' |
      grep -v '^\[Subagent hand-back\]' | awk '/^agentId: / { exit } { print }')"
  fi
  verdict="$(printf '%s\n' "$ureply" | tr -d '`*.' | awk 'NF { l = $0 } END { print tolower(l) }' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  if [ "$verdict" = "aprovado" ]; then ok "a última revisão do kit:ui-reviewer termina em aprovado"; else ko "a última revisão do kit:ui-reviewer termina em aprovado" "última linha: '$verdict'"; fi

  il="$(grep -c '^  - Interface: ' <<<"$plan")"
  if [ "$il" -ge 2 ] && sed -n '/^- \[[xX]\] F1\./,/^- \[/p' <<<"$plan" | grep -q 'kit:ui-reviewer'; then ok "PLAN.md com as linhas Interface do checkpoint e da F1"
  else ko "PLAN.md com as linhas Interface do checkpoint e da F1" "$il linhas Interface; F1: $(sed -n '/^- \[[xX]\] F1\./,/^- \[/p' <<<"$plan" | head -n 6 | tr '\n' '|')"; fi

  FR="$d/.claude/state/ui/final/report.json"
  if [ -f "$FR" ] && jq -e '([.screens[].images[]] | length) >= 12 and .totals.findings == 0' "$FR" >/dev/null 2>&1; then ok "captura final do plano: imagens das três rotas e nenhum achado"
  else ko "captura final do plano: imagens das três rotas e nenhum achado" "$(jq -c '.totals' "$FR" 2>&1) $(ls "$d/.claude/state/ui" 2>&1 | tr '\n' ' ')"; fi

  # Aceite por fora: a tela entregue, capturada de novo, sem achado e com os textos de cada estado.
  if (cd "$d" && bash "$UIS" capture --name aceite --routes "/avisos,/avisos?dados=vazio,/avisos?dados=erro" >"$W/aceite.out" 2>&1); then ok "aceite: captura independente da tela entregue sai sem achado"
  else ko "aceite: captura independente da tela entregue sai sem achado" "$(grep -E 'achado|ui:' "$W/aceite.out" | head -n 6 | tr '\n' '|')"; fi
  miss=""
  for s in 'Nenhum aviso por enquanto.' 'Carregando avisos' 'Não foi possível carregar os avisos.' 'Tentar de novo'; do
    grep -rqF -- "$s" "$d/web" || miss+="[$s] "
  done
  grep -qF 'href="/avisos"' "$d/web/index.html" || miss+="[link Avisos no menu] "
  if [ -z "$miss" ]; then ok "aceite: os textos de cada estado e o link do menu existem"; else ko "aceite: os textos de cada estado e o link do menu existem" "$miss"; fi
  if ! grep -rqE '#[0-9a-fA-F]{3,6}\b' "$d/web/avisos.html" "$d/web/avisos.css" 2>/dev/null; then ok "aceite: nenhuma cor solta na tela nova (só tokens)"
  else ko "aceite: nenhuma cor solta na tela nova (só tokens)" "$(grep -rnE '#[0-9a-fA-F]{3,6}\b' "$d/web/avisos.html" "$d/web/avisos.css" 2>/dev/null | head -n 4 | tr '\n' '|')"; fi
  if ! url_up "$URL/"; then ok "o app que a captura subiu não ficou rodando"; else ko "o app que a captura subiu não ficou rodando" "$URL ainda responde"; fi
  if [ "$(git -C "$d" rev-list --count HEAD | tr -d '\r')" = "1" ]; then ok "nenhum commit criado"; else ko "nenhum commit criado" "$(git -C "$d" log --oneline | tr -d '\r')"; fi
fi

if [ "$USER_SUM0" = "$(user_sum)" ]; then ok "settings do usuário intacto"; else ko "settings do usuário intacto" "mudou"; fi

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
