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

echo
echo "## Outros arquivos em .claude/"
if [ -d .claude ]; then
  find .claude -type f 2>/dev/null |
    grep -Ev '^\.claude/(settings(\.local)?\.json|skills/|commands/|agents/|rules/|hooks/|scripts/)' |
    sort | sed 's/^/- `/; s/$/`/'
fi
exit 0
