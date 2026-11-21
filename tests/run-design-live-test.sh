#!/usr/bin/env bash
# Teste ao vivo da direcao visual, no projeto com tela de tests/ui/repo (com kit.json e kit-ui.md):
# - app: /kit:design no escopo app gera ao menos 2 amostras em HTML autocontido na pasta de estado,
#   grava .claude/rules/kit-design.md com o cabecalho e os paths de ui.globs, o DESIGN.md com a
#   amostra escolhida ao lado, nao grava SPEC e nao muda codigo do projeto.
# - spec: /kit:spec redesenhar o painel (escopo pagina, so recomposicao) grava DESIGN.md, amostra e
#   SPEC.md na mesma pasta, com Padrao visual apontando a amostra, sem rule de direcao.
# As respostas das perguntas e a escolha da amostra vao no prompt: claude -p nao tem usuario.
# Em claude -p todo Write em .claude/ e negado (arquivo sensivel), mesmo com acceptEdits e a regra no
# --allowedTools. Negado: rule, DESIGN.md, amostra versionada e SPEC saem como "pulado"; as amostras
# sao conferidas pelo conteudo dos Write negados no transcript, mais o relatorio e o que nao mudou.
# Custa duas sessoes do Claude Code com 2 a 3 subagents cada. Uso: tests/run-design-live-test.sh [--keep] [app|spec]
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

ALL_CASES="app spec"
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

USER_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
user_sum() { if [ -f "$USER_SETTINGS" ]; then cksum <"$USER_SETTINGS"; else echo ausente; fi; }
USER_SUM0="$(user_sum)"

# Uso: new_repo <nome>. Projeto com tela, kit.json com ui, a rule de interface gravada como o init
# grava (cabecalho, paths e o bloco de ui-rules.md) e .claude/state/ ignorado. Commita e ecoa a pasta.
new_repo() {
  local d="$W/$1" g
  cp -r "$HERE/ui/repo" "$d"
  mkdir -p "$d/.claude/rules"
  cp "$HERE/ui/kit.json" "$d/.claude/kit.json"
  {
    printf -- '---\npaths:\n'
    jq -r '.ui.globs[]' "$HERE/ui/kit.json" | tr -d '\r' | while IFS= read -r g; do printf '  - "%s"\n' "$g"; done
    printf -- '---\n<!-- kit:ui v2 -->\n# Interface deste projeto\n\n'
    printf -- '- Biblioteca de componentes: nenhuma\n'
    printf -- '- Tema e tokens: `web/tokens.css` — cores, espaçamento, raio e fonte\n'
    printf -- '- Componentes compartilhados: nenhuma pasta; menu e cartões em `web/style.css`\n'
    printf -- '- Tela de referência: `web/index.html` — única tela, com o menu e os cartões\n'
    printf -- '- Direção visual: `.claude/rules/kit-design.md` (e `kit-design-<area>.md` numa área com direção própria), gravada pela `/kit:design`; quando existe, manda em fonte, paleta, composição e movimento\n'
    printf -- '- Para ver a tela: http://127.0.0.1:41873, subida por node server.mjs; a captura do kit percorre de 320 a 1920px\n\n'
    tr -d '\r' <"$PLUGIN/skills/execute/ui-rules.md"
  } >"$d/.claude/rules/kit-ui.md"
  printf '.claude/state/\n' >"$d/.gitignore"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" -c core.autocrlf=false add -A
  git -C "$d" -c core.autocrlf=false -c user.name=kit-test -c user.email=kit@test commit -qm init
  printf '%s' "$d"
}

# Uso: run_claude <pasta> <prompt>. Transcript em <pasta>.jsonl.
run_claude() {
  (cd "$1" && timeout 2400 claude -p "$2" --plugin-dir "$PLUGIN" \
    --setting-sources project,local --permission-mode acceptEdits \
    --allowedTools "Read" "Grep" "Glob" "Write" "Edit" "Agent" "Write(./.claude/**)" "Edit(./.claude/**)" \
    --max-turns 120 --output-format stream-json --verbose </dev/null >"$1.jsonl" 2>"$1.err")
}

final_text() { jq -r 'select(.type == "result") | .result // empty' "$1" 2>/dev/null | tr -d '\r'; }

# Tipos dos agents chamados, um por linha.
agents_called() {
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and (.name == "Agent" or .name == "Task"))
    | .input.subagent_type // "general-purpose"' "$1" 2>/dev/null | tr -d '\r'
}

# Maior numero de agents general-purpose chamados numa mesma mensagem. No stream-json cada bloco
# de conteudo chega num evento proprio, com o mesmo message.id: a contagem e por id.
max_parallel_gp() {
  jq -r 'select(.type == "assistant" and (.parent_tool_use_id // null) == null) | (.message.id // "m") as $m
    | .message.content[]? | select(.type == "tool_use" and (.name == "Agent" or .name == "Task") and ((.input.subagent_type // "general-purpose") == "general-purpose"))
    | $m' "$1" 2>/dev/null | tr -d '\r' | sort | uniq -c | sort -nr | awk 'NR == 1 { print $1 }'
}

# 0 se alguma escrita foi negada por falta de aprovacao.
write_denied() {
  jq -se '[.[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .is_error == true)
    | .content | (if type == "string" then . else (map(.text // "") | join(" ")) end)
    | test("sensitive file|requires? approval|Permission to use (Write|Edit) has been denied")] | any' "$1" >/dev/null 2>&1
}

# Uso: dump_attempts <transcript> <pasta>. Grava na pasta o conteudo de cada Write tentado em
# .claude/state/ui/design/ (a ultima tentativa de cada nome), para conferir a amostra que nao gravou.
dump_attempts() {
  local t="$1" out="$2" i=0 name
  mkdir -p "$out"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    jq -rjs --argjson i "$i" '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "Write")
      | .input | select((.file_path // "") | test("[\\\\/]\\.claude[\\\\/]state[\\\\/]ui[\\\\/]design[\\\\/].*\\.html$"))] | .[$i].content // empty' "$t" >"$out/$name"
    i=$((i + 1))
  done < <(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "Write")
    | .input.file_path // "" | select(test("[\\\\/]\\.claude[\\\\/]state[\\\\/]ui[\\\\/]design[\\\\/].*\\.html$")) | split("/") | last | split("\\") | last' "$t" 2>/dev/null | tr -d '\r')
}

# Uso: self_contained <arquivo>. 0 se o HTML tem o CSS no proprio arquivo, viewport, nenhum script
# externo e nenhuma folha de estilo local (folha por https e so a da fonte).
self_contained() {
  local html links
  html="$(tr '\r\n' '  ' <"$1")"
  grep -qi '<style' <<<"$html" || return 1
  grep -qiE "<meta[^>]*name=[\"']?viewport" <<<"$html" || return 1
  grep -qiE '<script[^>]*src=' <<<"$html" && return 1
  links="$(grep -oiE '<link[^>]*>' <<<"$html" | grep -i 'stylesheet' || true)"
  [ -z "$links" ] && return 0
  ! grep -viE "href=[\"']?https://" <<<"$links" | grep -q .
}

# Uso: check_samples <rotulo> <minimo> <onde> <arquivo>... Confere as amostras dadas.
check_samples() {
  local label="$1" min="$2" where="$3" n=0 bad="" f
  shift 3
  for f in "$@"; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    self_contained "$f" || bad+="$(basename "$f") "
  done
  if [ "$n" -ge "$min" ]; then ok "$label: $n amostras $where"; else ko "$label: ao menos $min amostras $where" "$n encontradas"; fi
  if [ "$n" -gt 0 ] && [ -z "$bad" ]; then ok "$label: cada amostra é HTML autocontido (CSS no arquivo, viewport, sem script externo)"
  else ko "$label: cada amostra é HTML autocontido (CSS no arquivo, viewport, sem script externo)" "fora: $bad"; fi
}

# Uso: check_denied <pasta> <rotulo>. Gravacao em .claude/ negada (claude -p nao tem quem aprove):
# confere as amostras pelo conteudo tentado e que o relatorio diz que nada foi gravado.
check_denied() {
  local d="$1" label="$2" text
  text="$(final_text "$d.jsonl")"
  echo "  pulado $label: gravação das amostras, rule, DESIGN.md e SPEC (a sessão não pôde gravar em .claude/; em claude -p não há quem aprove)"
  dump_attempts "$d.jsonl" "$d.tentativas"
  check_samples "$label" 2 "geradas (pelo conteúdo do Write negado)" "$d.tentativas"/*.html
  if grep -qF '.claude' <<<"$text" && grep -qiE 'não (foi|foram) gravad|não gravou|não gravei|negad|permiss' <<<"$text"; then ok "$label: o relatório diz que a gravação em .claude/ não aconteceu"
  else ko "$label: o relatório diz que a gravação em .claude/ não aconteceu" "$(tail -n 8 <<<"$text")"; fi
}

# Uso: same_text <a> <b>. 0 se iguais sem CR, sem espaco no fim de linha e sem linhas vazias no fim.
same_text() {
  local na nb
  na="$(tr -d '\r' <"$1" | sed 's/[[:space:]]*$//')"
  nb="$(tr -d '\r' <"$2" | sed 's/[[:space:]]*$//')"
  [ "$na" = "$nb" ]
}

# Uso: check_design <pasta> <rotulo> <DESIGN.md> <escopo esperado>. DESIGN.md e amostra ao lado.
check_design() {
  local d="$1" label="$2" D="$3" scope="$4" A same=0 f
  A="$(dirname "$D")/amostra.html"
  if [ -f "$D" ] && grep -qE "^## Escopo" "$D" && sed -n '/^## Escopo/,/^## /p' "$D" | grep -qi "$scope" &&
    grep -q '^## Componentes base' "$D" && grep -q '^## Telas afetadas' "$D" && grep -qF 'amostra.html' "$D"; then
    ok "$label: DESIGN.md com Escopo $scope, Componentes base, Telas afetadas e a amostra"
  else ko "$label: DESIGN.md com Escopo $scope, Componentes base, Telas afetadas e a amostra" "$(grep -n '^## \|^[a-z]' "$D" 2>&1 | head -n 12 | tr '\n' '|')"; fi
  for f in "$d"/.claude/state/ui/design/*/*.html; do
    [ -f "$f" ] && [ -f "$A" ] && same_text "$f" "$A" && { same=1; break; }
  done
  if [ "$same" = "1" ]; then ok "$label: amostra.html ao lado do DESIGN.md é cópia de uma amostra gerada"
  else ko "$label: amostra.html ao lado do DESIGN.md é cópia de uma amostra gerada" "$(ls "$(dirname "$D")" 2>&1 | tr '\n' ' ')"; fi
}

# Uso: check_untouched <pasta> <rotulo>. Nenhum arquivo do projeto mudou e nada novo fora de
# docs/specs/ e .claude/rules/kit-design*.md; nenhum commit.
check_untouched() {
  local d="$1" label="$2" extra
  if git -C "$d" diff --quiet HEAD; then ok "$label: nenhum arquivo versionado alterado"; else ko "$label: nenhum arquivo versionado alterado" "$(git -C "$d" diff --stat HEAD | tr '\n' ' ')"; fi
  extra="$(git -C "$d" ls-files --others --exclude-standard | tr -d '\r' | grep -vE '^docs/specs/|^\.claude/rules/kit-design[^/]*\.md$' || true)"
  if [ -z "$extra" ]; then ok "$label: nenhum arquivo novo fora de docs/specs/ e da rule de direção"; else ko "$label: nenhum arquivo novo fora de docs/specs/ e da rule de direção" "$(tr '\n' ' ' <<<"$extra")"; fi
  if [ "$(git -C "$d" rev-list --count HEAD | tr -d '\r')" = "1" ]; then ok "$label: nenhum commit criado"; else ko "$label: nenhum commit criado" "$(git -C "$d" log --oneline | tr -d '\r')"; fi
}

APP_PROMPT='/kit:design app
Respostas pré-aprovadas (execução não interativa; não há como perguntar, não chame AskUserQuestion):
- Quem usa: o pessoal da operação, no computador do escritório e no celular de quem está no galpão, para ver de relance os pedidos de hoje e as entregas atrasadas.
- O que incomoda: parece um template sem identidade; fonte de sistema, tudo com o mesmo peso, nada chama atenção para o que está atrasado.
- Marca: nada obrigatório (sem cor, logo ou fonte de marca).
- Tema: só claro.
- A direção vale para o app inteiro; não há área com direção própria.
- Escolha: fico com a primeira amostra gerada (n = 1), sem outra rodada. Esta é a minha escolha; grave a direção a partir dela.
- Gravação: sim, grave a rule de direção, o DESIGN.md e a amostra.'

SPEC_PROMPT='/kit:spec redesenhar o painel
Respostas pré-aprovadas (execução não interativa; não há como perguntar, não chame AskUserQuestion):
- Alvo: a página inicial do painel, web/index.html (rota /). Escopo página, não o app.
- O projeto não tem direção visual: é só recomposição com o padrão atual (tokens de web/tokens.css), não o piloto de uma direção do app. Fonte e paleta não mudam.
- O que incomoda: os dois cartões têm o mesmo peso e a entrega atrasada não se destaca; o número fica pequeno, escondido no texto miúdo.
- Tarefa principal: ver de relance quantos pedidos há hoje e se há entrega atrasada.
- O que não muda: o menu do topo, os ids pedidos e atrasadas (usados por web/painel.js) e a função resumo.
- Escolha: fico com a primeira amostra gerada (n = 1), sem outra rodada. Grave o DESIGN.md e a amostra e siga até a SPEC.
- Entrevista da SPEC: a tela não busca dados (o resumo é calculado na hora), então não tem carregando nem erro; vazio é "0 pedidos" e "Nenhuma"; sucesso é o número em destaque e, com entrega atrasada, o cartão de atrasadas em destaque de erro. Ação principal: nenhuma além de ler; o menu continua. Tela pequena: abaixo de 700px os cartões empilham, um por linha. Casos de borda: zero em tudo; muitos pedidos (número de 4 dígitos sem quebrar o cartão). Verificação: node --test passa e a rota / abre em 360x800 e 1920x1080 sem rolagem horizontal, com o número de cada cartão em destaque.
- Use o slug painel. Não há outras perguntas em aberto.'

if want app; then
  d="$(new_repo app)"
  echo "rodando /kit:design no escopo app em $W (alguns minutos)..."
  run_claude "$d" "$APP_PROMPT"
  echo "design no escopo app"
  text="$(final_text "$d.jsonl")"
  gp="$(agents_called "$d.jsonl" | grep -cx 'general-purpose')"
  par="$(max_parallel_gp "$d.jsonl")"
  if [ "$gp" -ge 2 ] && [ "${par:-0}" -ge 2 ]; then ok "app: amostras por subagents general-purpose na mesma mensagem ($gp chamadas, $par juntas)"
  else ko "app: amostras por subagents general-purpose na mesma mensagem" "chamadas: $gp; juntas: ${par:-0}; $(agents_called "$d.jsonl" | tr '\n' ' ')"; fi
  if agents_called "$d.jsonl" | grep -qx 'kit:investigator'; then ok "app: kit:investigator chamado para o inventário de componentes"
  else ko "app: kit:investigator chamado para o inventário de componentes" "$(agents_called "$d.jsonl" | tr '\n' ' ')"; fi
  if ! ls "$d"/.claude/state/ui/design/*/*.html >/dev/null 2>&1 && write_denied "$d.jsonl"; then
    check_denied "$d" "app"
  else
    check_samples "app" 2 "em .claude/state/ui/design/" "$d"/.claude/state/ui/design/*/*.html
    R="$d/.claude/rules/kit-design.md"
    globs_ok=1
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      grep -qF -- "\"$g\"" "$R" 2>/dev/null || grep -qE -- "^[[:space:]]*-[[:space:]]*$(sed 's/[.*]/\\&/g' <<<"$g")[[:space:]]*$" "$R" 2>/dev/null || globs_ok=0
    done < <(jq -r '.ui.globs[]' "$d/.claude/kit.json" | tr -d '\r')
    if [ -f "$R" ] && grep -qxF '<!-- kit:design v1 -->' <(tr -d '\r' <"$R") && grep -qx 'paths:' <(tr -d '\r' <"$R") && [ "$globs_ok" = "1" ]; then
      ok "app: kit-design.md com o cabeçalho kit:design e os paths de ui.globs"
    else ko "app: kit-design.md com o cabeçalho kit:design e os paths de ui.globs" "$(head -n 10 "$R" 2>&1 | tr '\n' '|')"; fi
    miss=""
    for k in Direção Tipografia Paleta Composição Movimento Acabamento 'O que evitar' Amostra; do
      grep -qE "^[-*[:space:]]*\**$k\**:" <(tr -d '\r' <"$R" 2>/dev/null) || miss+="[$k] "
    done
    if [ -z "$miss" ]; then ok "app: kit-design.md com os oito campos"; else ko "app: kit-design.md com os oito campos" "faltam: $miss"; fi
    if grep -i 'Tipografia' "$R" 2>/dev/null | grep -qiE 'empacot[^ ]* em `[^`]+`'; then ok "app: Tipografia diz de onde as fontes vêm no projeto"
    else ko "app: Tipografia diz de onde as fontes vêm no projeto" "$(grep -i 'Tipografia' "$R" 2>&1 | head -c 300)"; fi
    if bash "$UIS" status "$d" 2>/dev/null | tr -d '\r' | grep -qx 'direção: ok'; then ok "app: ui.sh status diz direção: ok"
    else ko "app: ui.sh status diz direção: ok" "$(bash "$UIS" status "$d" 2>&1 | grep '^direção' | tr '\n' ' ')"; fi
    D="$(find "$d/docs/specs" -name DESIGN.md 2>/dev/null | head -n 1)"
    [ -n "$D" ] || D="$d/docs/specs/sem-design/DESIGN.md"
    check_design "$d" "app" "$D" "app"
    if grep -qF 'docs/specs/' "$R" 2>/dev/null && grep -qF 'amostra.html' "$R" 2>/dev/null; then ok "app: campo Amostra da rule aponta a amostra versionada"
    else ko "app: campo Amostra da rule aponta a amostra versionada" "$(grep -i 'amostra' "$R" 2>&1 | head -c 300)"; fi
    if ! find "$d/docs/specs" -name SPEC.md 2>/dev/null | grep -q .; then ok "app: nenhuma SPEC gravada"; else ko "app: nenhuma SPEC gravada" "$(find "$d/docs/specs" -name SPEC.md)"; fi
    slug="$(basename "$(dirname "$D")")"
    if grep -qF "/kit:spec docs/specs/$slug/DESIGN.md" <<<"$text"; then ok "app: termina com o comando da /kit:spec pronto"
    else ko "app: termina com o comando da /kit:spec pronto" "$(tail -n 8 <<<"$text")"; fi
    if grep -qiE 'Custo:[*`[:space:]]*[0-9]+ subagents' <<<"$text"; then ok "app: resumo com a linha de custo"; else ko "app: resumo com a linha de custo" "$(tail -n 8 <<<"$text")"; fi
  fi
  check_untouched "$d" "app"
fi

if want spec; then
  d="$(new_repo spec)"
  echo "rodando /kit:spec redesenhar o painel em $W (alguns minutos)..."
  run_claude "$d" "$SPEC_PROMPT"
  echo "spec como porta do redesenho de uma página"
  text="$(final_text "$d.jsonl")"
  calls="$(agents_called "$d.jsonl")"
  gp="$(grep -cx 'general-purpose' <<<"$calls")"
  if [ "$gp" -ge 2 ]; then ok "spec: composições por subagents general-purpose ($gp chamadas)"; else ko "spec: composições por subagents general-purpose" "$(tr '\n' ' ' <<<"$calls")"; fi
  if ! ls "$d"/.claude/state/ui/design/*/*.html >/dev/null 2>&1 && write_denied "$d.jsonl"; then
    check_denied "$d" "spec"
  else
    check_samples "spec" 2 "em .claude/state/ui/design/" "$d"/.claude/state/ui/design/*/*.html
    D="$d/docs/specs/painel/DESIGN.md"
    S="$d/docs/specs/painel/SPEC.md"
    check_design "$d" "spec" "$D" "página"
    if [ -f "$S" ]; then ok "spec: SPEC.md na pasta do DESIGN.md"; else ko "spec: SPEC.md na pasta do DESIGN.md" "$(find "$d/docs" -type f 2>&1 | tr '\n' ' ') $(tail -n 8 <<<"$text")"; fi
    pv="$(tr -d '\r' <"$S" 2>/dev/null | grep -i 'Padrão visual:')"
    if grep -qF 'docs/specs/painel/amostra.html' <<<"$pv" && grep -qF 'DESIGN.md' <<<"$pv"; then ok "spec: Padrão visual aponta o DESIGN.md e a amostra"
    else ko "spec: Padrão visual aponta o DESIGN.md e a amostra" "${pv:-sem a linha}"; fi
    if grep -qx 'kit:spec-reviewer' <<<"$calls"; then ok "spec: kit:spec-reviewer chamado"; else ko "spec: kit:spec-reviewer chamado" "$(tr '\n' ' ' <<<"$calls")"; fi
  fi
  if ! ls "$d/.claude/rules/" 2>/dev/null | grep -q '^kit-design'; then ok "spec: recomposição não grava rule de direção"
  else ko "spec: recomposição não grava rule de direção" "$(ls "$d/.claude/rules/" | tr '\n' ' ')"; fi
  check_untouched "$d" "spec"
fi

if [ "$USER_SUM0" = "$(user_sum)" ]; then ok "settings do usuário intacto"; else ko "settings do usuário intacto" "mudou"; fi

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
