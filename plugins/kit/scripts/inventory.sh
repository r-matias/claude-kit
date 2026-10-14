#!/usr/bin/env bash
# Inventario da configuracao Claude Code de um repositorio, usado pelo modo adotar do /kit:init. Nao e hook.
# Uso: inventory.sh [diretorio-do-projeto]
set -u
command -v jq >/dev/null 2>&1 || { echo "inventory: jq nao encontrado" >&2; exit 2; }

ROOT="${1:-.}"
cd "$ROOT" || exit 2

frontmatter() {
  awk -v key="$2" '
    NR == 1 && $0 !~ /^---/ { exit }
    NR > 1 && /^---/ { exit }
    NR > 1 {
      sub(/\r$/, "")
      if (index($0, key ":") == 1) { v = substr($0, length(key) + 2); sub(/^[ \t]+/, "", v); gsub(/^["\x27]|["\x27]$/, "", v); print v; exit }
    }' "$1"
}

short() {
  local s="$1"
  [ "${#s}" -gt 160 ] && s="${s:0:157}..."
  printf '%s' "$s"
}

hooks_of() {
  jq -r '
    (.hooks // {}) | to_entries[] | .key as $ev | .value[]? | (.matcher // "*") as $m | .hooks[]? |
    "  - \($ev) [\($m)] \(.type // "command"): \(.command // .prompt // .url // "")\(if .args then " " + (.args | join(" ")) else "" end)\(if .timeout then " (timeout \(.timeout)s)" else "" end)"
  ' "$1" 2>/dev/null | tr -d '\r'
}

settings_summary() {
  local f="$1" label="$2"
  [ -f "$f" ] || return 0
  echo "- \`$label\`"
  if ! jq empty "$f" >/dev/null 2>&1; then
    echo "  - JSON invalido"
    return 0
  fi
  jq -r '
    "  - permissions: allow \((.permissions.allow // []) | length), ask \((.permissions.ask // []) | length), deny \((.permissions.deny // []) | length)",
    (if .enabledPlugins then "  - enabledPlugins: \(.enabledPlugins | to_entries | map(select(.value == true) | .key) | join(", "))" else empty end),
    (if .sandbox then "  - sandbox: \(.sandbox | tojson)" else empty end),
    (if .env then "  - env: \(.env | keys | join(", "))" else empty end),
    (if .statusLine then "  - statusLine: \(.statusLine.command // "")" else empty end)
  ' "$f" 2>/dev/null | tr -d '\r'
  local h
  h="$(hooks_of "$f")"
  if [ -n "$h" ]; then echo "  - hooks:"; printf '%s\n' "$h" | sed 's/^/  /'; fi
}

echo "# Inventario Claude Code: $(pwd)"
echo
echo "## Settings e hooks"
settings_summary ".claude/settings.json" ".claude/settings.json (projeto, versionado)"
settings_summary ".claude/settings.local.json" ".claude/settings.local.json (local, nao versionado)"
settings_summary "$HOME/.claude/settings.json" "~/.claude/settings.json (usuario: so leitura para o init)"
for f in .claude/hooks/* .claude/scripts/*; do
  [ -f "$f" ] && echo "- arquivo de hook/script: \`$f\` ($(wc -l <"$f" | tr -d ' ') linhas)"
done

echo
echo "## Skills"
found=0
for f in .claude/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  found=1
  name="$(frontmatter "$f" name)"; [ -n "$name" ] || name="$(basename "$(dirname "$f")")"
  dmi="$(frontmatter "$f" disable-model-invocation)"
  echo "- \`$name\` ($f, $(wc -l <"$f" | tr -d ' ') linhas${dmi:+, disable-model-invocation: $dmi}): $(short "$(frontmatter "$f" description)")"
done
[ "$found" -eq 1 ] || echo "- nenhuma"

echo
echo "## Commands"
found=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  found=1
  rel="${f#.claude/commands/}"
  echo "- \`/${rel%.md}\` ($f): $(short "$(frontmatter "$f" description)")"
done < <(find .claude/commands -name '*.md' -type f 2>/dev/null | sort)
[ "$found" -eq 1 ] || echo "- nenhum"

echo
echo "## Agents"
found=0
for f in .claude/agents/*.md; do
  [ -f "$f" ] || continue
  found=1
  name="$(frontmatter "$f" name)"; [ -n "$name" ] || name="$(basename "$f" .md)"
  tools="$(frontmatter "$f" tools)"
  echo "- \`$name\` ($f${tools:+, tools: $tools}): $(short "$(frontmatter "$f" description)")"
done
[ "$found" -eq 1 ] || echo "- nenhum"

echo
echo "## Rules"
found=0
for f in .claude/rules/*.md .claude/rules/**/*.md; do
  [ -f "$f" ] || continue
  found=1
  paths="$(awk 'NR == 1 && !/^---/ { exit } NR > 1 && /^---/ { exit } NR > 1 { sub(/\r$/, ""); print }' "$f" | sed -n '/^paths:/,$p' | tr -d '\n' | sed 's/^paths://; s/  */ /g')"
  echo "- \`$f\`${paths:+ paths:$paths}"
done
[ "$found" -eq 1 ] || echo "- nenhuma"

echo
echo "## CLAUDE.md"
found=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  found=1
  echo "- \`$f\` ($(wc -l <"$f" | tr -d ' ') linhas)"
done < <(
  {
    git ls-files -co --exclude-standard 2>/dev/null | grep -E '(^|/)(CLAUDE|CLAUDE\.local)\.md$'
    for f in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do [ -f "$f" ] && echo "$f"; done
  } | sort -u
)
[ "$found" -eq 1 ] || echo "- nenhum"

echo
echo "## MCP"
if [ -f .mcp.json ]; then
  jq -r '(.mcpServers // {}) | to_entries[] | "- `\(.key)`: \(.value.type // "stdio") \(.value.command // .value.url // "") \((.value.args // []) | join(" "))"' .mcp.json 2>/dev/null | tr -d '\r'
else
  echo "- nenhum .mcp.json"
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Proposito de uma skill do projeto comparado com as skills do kit (nome ou descricao).
kit_skill_for() {
  local t
  t="$(lower "$1 $2")"
  case "$t" in
    *épico* | *epico* | *epic*) echo epic ;;
    *spec* | *especifica*) echo spec ;;
    *planej* | *plan*) echo plan ;;
    *execut* | *implement*) echo execute ;;
    *hunt* | *debug* | *investig* | *diagnos*) echo hunt ;;
    *fix* | *corrig* | *conserta* | *bug*) echo fix ;;
  esac
}

kit_agent_for() {
  local t
  t="$(lower "$1 $2")"
  case "$t" in
    *secur* | *segur*) echo security-reviewer ;;
    *review* | *revis*) echo code-reviewer ;;
    *investig* | *explor*) echo investigator ;;
    *test*) echo test-writer ;;
  esac
}

echo
echo "## Riscos e sobreposições"
found=0

for f in .claude/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  name="$(frontmatter "$f" name)"; [ -n "$name" ] || name="$(basename "$(dirname "$f")")"
  desc="$(frontmatter "$f" description)"
  dmi="$(frontmatter "$f" disable-model-invocation)"
  k="$(kit_skill_for "$name" "$desc")"
  if [ -n "$k" ]; then
    found=1
    if [ "$dmi" = "true" ]; then
      risk="a skill do projeto tem disable-model-invocation: true e a do kit não, então o Claude escolhe sozinho \`kit:$k\` para pedidos como \"corrige esse bug\""
    else
      risk="duas skills com o mesmo propósito ficam visíveis e o Claude escolhe uma de forma imprevisível"
    fi
    echo "- [sobreposição] skill \`$name\` ($f) ↔ \`kit:$k\`. Risco: $risk. Recomendação: a skill do projeto é a dona; adicionar \`Skill(kit:$k)\` em \`permissions.deny\` do \`.claude/settings.json\` do projeto."
  fi
  if printf '%s' "$(lower "$name $desc")" | grep -qE 'deploy|release|backup|push|migra|publica|publish' && [ "$dmi" != "true" ]; then
    found=1
    echo "- [efeito colateral] skill \`$name\` ($f) parece ter efeito colateral e não tem disable-model-invocation: true; o Claude pode invocá-la sozinho."
  fi
done

for f in .claude/agents/*.md; do
  [ -f "$f" ] || continue
  name="$(frontmatter "$f" name)"; [ -n "$name" ] || name="$(basename "$f" .md)"
  k="$(kit_agent_for "$name" "$(frontmatter "$f" description)")"
  if [ -n "$k" ]; then
    found=1
    echo "- [sobreposição] agent \`$name\` ($f) ↔ \`kit:$k\`. Risco: dois agents com o mesmo papel; o Claude escolhe um de forma imprevisível. Recomendação: o agent do projeto é o dono; adicionar \`Agent(kit:$k)\` em \`permissions.deny\` do \`.claude/settings.json\` do projeto."
  fi
done

# Hooks do projeto: aviso mudo (texto no stdout sem additionalContext) e guarda que falha aberta sem jq.
for s in .claude/settings.json .claude/settings.local.json; do
  [ -f "$s" ] || continue
  while IFS=$'\t' read -r ev cmd; do
    [ -n "$cmd" ] || continue
    case "$ev" in PreToolUse | PostToolUse | Stop) ;; *) continue ;; esac
    script="$(printf '%s' "$cmd" | sed -e 's/\${CLAUDE_PROJECT_DIR}/./g' -e 's/\$CLAUDE_PROJECT_DIR/./g' -e 's/"//g' |
      grep -oE '[^ ]+\.(sh|bash|py|js|mjs|cjs|ts)' | head -n 1)"
    [ -n "$script" ] && [ -f "$script" ] || continue
    if grep -E '^[[:space:]]*(echo|printf)([[:space:]]|$)' "$script" | grep -vqE '>&2|>[[:space:]]*/dev/|>>?[[:space:]]*[^&[:space:]]' &&
      ! grep -q 'additionalContext' "$script"; then
      found=1
      echo "- [aviso possivelmente mudo] hook $ev \`$script\` ($s) imprime texto no stdout sem JSON additionalContext; com exit 0 esse texto não chega ao Claude. Recomendação: migrar para \`coupled_changes\` com \`level: warn\` ou trocar a saída para JSON \`additionalContext\`."
    fi
    if [ "$ev" = "PreToolUse" ] && grep -qE 'jq.*\|\|[[:space:]]*exit[[:space:]]+0' "$script"; then
      found=1
      echo "- [falha aberta] hook PreToolUse \`$script\` ($s) faz \`jq ... || exit 0\`: sem jq (ou com JSON inesperado) a guarda libera tudo. Recomendação: substituir pelo \`guard-files\` com \`protected_paths\` (mensagem por item) ou trocar para exit 2."
    fi
  done < <(jq -r '(.hooks // {}) | to_entries[] | .key as $ev | .value[]? | .hooks[]? |
    "\($ev)\t\(.command // "")\(if .args then " " + (.args | join(" ")) else "" end)"' "$s" 2>/dev/null | tr -d '\r')
done

if git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
  found=1
  echo "- [settings.local.json versionado] \`.claude/settings.local.json\` está no git; ele é pessoal e costuma ficar fora do repositório."
fi

for s in .claude/settings.json .claude/settings.local.json; do
  [ -f "$s" ] || continue
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    found=1
    echo "- [sintaxe antiga] regra \`$r\` em $s usa \`:*\`; a forma atual é \`Tool(prefixo *)\`."
  done < <(jq -r '(.permissions // {}) | [.allow, .ask, .deny] | map(. // []) | add | .[] | select(test(":\\*\\)$"))' "$s" 2>/dev/null | tr -d '\r')
done

secret_deny=0
for s in .claude/settings.json .claude/settings.local.json "$HOME/.claude/settings.json"; do
  [ -f "$s" ] || continue
  jq -e '(.permissions.deny // []) | any(test("^Read\\(.*(\\.env|secret|\\.pem|\\.key)"))' "$s" >/dev/null 2>&1 && secret_deny=1
done
if [ "$secret_deny" -eq 0 ]; then
  found=1
  echo "- [sem deny de segredos] nenhuma regra \`Read(...)\` em \`permissions.deny\` cobre \`.env\`, chaves ou \`secrets/\` (projeto, local ou usuário)."
fi
[ "$found" -eq 1 ] || echo "- nenhum"

echo
echo "## Outros arquivos em .claude/"
if [ -d .claude ]; then
  find .claude -type f 2>/dev/null |
    grep -Ev '^\.claude/(settings(\.local)?\.json|skills/|commands/|agents/|rules/|hooks/|scripts/)' |
    sort | sed 's/^/- `/; s/$/`/'
fi
exit 0
