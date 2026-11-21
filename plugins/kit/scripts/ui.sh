#!/usr/bin/env bash
# Apoio de interface do /kit:init e do /kit:execute. Nao e hook e nunca grava em settings.
#
#   ui.sh status [pasta]
#     O que o projeto tem de interface e como o kit consegue captura-la, uma linha por item:
#       ui: <N> arquivos de interface (<ext> <n>, ...)   ou   ui: nenhum arquivo de interface
#       ui globs: <globs das extensoes encontradas>
#       ui pastas: <pastas com mais arquivos de interface>
#       ui design: <biblioteca, tema ou tokens detectados (onde)>
#       node: ok <versao> | ausente | antigo <versao>
#       navegador: ok <nome> (<caminho>) | ausente
#       captura: comando | kit | nenhuma — ...
#       rule: ok | ausente | desatualizada — <motivo> | do projeto ...   (so com ui.globs no kit.json)
#       direção: ok | ausente | do projeto ... | paths fora de sincronia — <motivo>[; áreas: <area> (ok | do projeto), ...]
#         (so com ui.globs; estado da .claude/rules/kit-design.md e das kit-design-<area>.md, que so a /kit:design grava)
#     Extensoes e marcadores vem de templates/ui-markers.txt. So leitura: nao le nem grava settings.
#
#   ui.sh capture [--kit <kit.json>] [--name <nome>] [--routes <a,b>] [--probe-only] [--tiles N]
#                 [--steps <json | arquivo.json>] [--attach <http://host:porta> [--match <trecho da url>]]
#                 [--serve <pasta>] [--out <pasta>]
#     Roda ui-capture.mjs com o "ui" do kit.json: sobe o app se preciso, percorre as larguras, grava
#     imagens e report.json em .claude/state/ui/<nome>/ e imprime o resumo. --steps leva a tela ate um
#     estado (login, clique, campo preenchido) antes de medir. --serve captura os .html de uma pasta local
#     (amostras da /kit:design) servida em 127.0.0.1 so durante a captura, sem ui.url nem ui.dev; --routes
#     escolhe os arquivos. Saida: 0 sem achado, 1 com achado, 2 uso ou config, 3 sem meio de captura,
#     4 app nao respondeu, 5 captura incompleta.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MARKERS="$HERE/../templates/ui-markers.txt"
RULE_TPL="$HERE/../templates/kit-ui.rule.md"
RULES_BLOCK="$HERE/../skills/execute/ui-rules.md"
ENGINE="$HERE/ui-capture.mjs"
UI_MIN_NODE=16

ui_files() {
  local dir="$1"
  if git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$dir" -c core.quotepath=false ls-files -co --exclude-standard 2>/dev/null
  else
    (cd "$dir" && find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | sed 's|^\./||' | head -n 20000)
  fi | tr -d '\r'
}

# Versao do node, ou vazio se nao ha node.
ui_node_version() {
  command -v node >/dev/null 2>&1 || return 0
  node -e 'process.stdout.write(process.versions.node)' 2>/dev/null | tr -d '\r'
}

# Estado da .claude/rules/kit-ui.md do projeto frente ao template do kit, ao bloco de regras e a ui.globs.
ui_rule_state() {
  local rule="$1/.claude/rules/kit-ui.md" kit="$2" have want missing g
  [ -f "$rule" ] || { echo "ausente"; return 0; }
  have="$(tr -d '\r' <"$rule" | sed -n 's/^<!-- kit:ui v\([0-9][0-9]*\) -->$/\1/p' | head -n 1)"
  [ -n "$have" ] || { echo "do projeto (sem o cabeçalho kit:ui)"; return 0; }
  want="$(tr -d '\r' <"$RULE_TPL" | sed -n 's/^<!-- kit:ui v\([0-9][0-9]*\) -->$/\1/p' | head -n 1)"
  if [ "$have" -lt "${want:-0}" ] 2>/dev/null; then echo "desatualizada — versão $have, a do kit é $want"; return 0; fi
  missing="$(awk 'NR == FNR { sub(/\r$/, ""); have[$0] = 1; next } { sub(/\r$/, "") } $0 != "" && !($0 in have) { n++ } END { print n + 0 }' "$rule" "$RULES_BLOCK")"
  [ "$missing" = "0" ] || { echo "desatualizada — $missing linhas do bloco de regras diferentes das do kit"; return 0; }
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    grep -qF -- "\"$g\"" "$rule" || { echo "desatualizada — paths sem o glob $g de ui.globs"; return 0; }
  done < <(jq -r '.ui.globs[]? | strings' "$kit" 2>/dev/null | tr -d '\r')
  echo "ok"
}

# Globs do paths: do frontmatter de uma rule, um por linha, sem aspas. Aceita lista e forma inline.
ui_rule_paths() {
  awk '
    function emit(v) {
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'\''.*'\''$/) v = substr(v, 2, length(v) - 2)
      if (v != "") print v
    }
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^paths:/ {
      rest = $0; sub(/^paths:[ \t]*/, "", rest)
      if (rest == "") { inp = 1; next }
      inp = 0; sub(/^\[/, "", rest); sub(/\][ \t]*$/, "", rest)
      n = split(rest, parts, ","); for (i = 1; i <= n; i++) emit(parts[i])
      next
    }
    inp && /^[ \t]*-[ \t]/ { v = $0; sub(/^[ \t]*-/, "", v); emit(v); next }
    /^[^ \t]/ { inp = 0 }' "$1"
}

ui_has_design_header() {
  awk '{ sub(/\r$/, "") } /^<!-- kit:design v[0-9]+ -->$/ { f = 1; exit } END { exit !f }' "$1"
}

# Estado da direcao visual: .claude/rules/kit-design.md frente a ui.globs e as rules de area kit-design-<area>.md.
# So le; quem grava essas rules e a /kit:design.
ui_design_state() {
  local rules="$1/.claude/rules" kit="$2" rule state globs have g f area areas=""
  rule="$rules/kit-design.md"
  if [ ! -f "$rule" ]; then
    state="ausente"
  elif ! ui_has_design_header "$rule"; then
    state="do projeto (sem o cabeçalho kit:design)"
  else
    state="ok"
    globs="$(jq -r '.ui.globs[]? | strings' "$kit" 2>/dev/null | tr -d '\r')"
    have="$(ui_rule_paths "$rule")"
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      grep -qxF -- "$g" <<<"$have" || { state="paths fora de sincronia — sem o glob $g de ui.globs"; break; }
    done <<<"$globs"
    if [ "$state" = "ok" ]; then
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        grep -qxF -- "$g" <<<"$globs" || { state="paths fora de sincronia — glob $g fora de ui.globs"; break; }
      done <<<"$have"
    fi
  fi
  for f in "$rules"/kit-design-*.md; do
    [ -f "$f" ] || continue
    area="${f##*/kit-design-}"
    area="${area%.md}"
    if ui_has_design_header "$f"; then areas="$areas${areas:+, }$area (ok)"; else areas="$areas${areas:+, }$area (do projeto)"; fi
  done
  echo "$state${areas:+; áreas: $areas}"
}

cmd_status() {
  local dir files raw total exts globs dirs design deps pkg nv major doctor browser kit has_cmd=0 mode
  dir="$(cd "${1:-.}" 2>/dev/null && pwd)" || { echo "ui: pasta não encontrada: ${1:-.}" >&2; return 2; }
  [ -f "$MARKERS" ] || { echo "ui: tabela de marcadores ausente: $MARKERS" >&2; return 2; }
  files="$(ui_files "$dir")"
  raw="$(printf '%s\n' "$files" | awk -F'|' '
    NR == FNR {
      sub(/\r$/, "")
      if ($1 == "ext") { ne++; ext[ne] = $2 }
      else if ($1 == "arquivo") { np++; g = $2; gsub(/\./, "\\.", g); gsub(/\*/, ".*", g); pat[np] = "^" g "$"; lab[np] = $3 }
      next
    }
    $0 == "" { next }
    /(^|\/)(node_modules|dist|build|out|vendor|coverage|target|\.next|\.nuxt|\.svelte-kit|\.venv|\.git)\// { next }
    {
      path = $0; name = path; sub(/.*\//, "", name)
      low = tolower(name)
      if (low ~ /\.min\.css$/ || low ~ /\.(test|spec|stories)\.[a-z]+$/) next
      # Marcador de tema ou de token so vale em arquivo de estilo, de codigo de tela ou de dados
      # (variables.tf e tokens.py nao sao design).
      if (low ~ /\.(css|scss|sass|less|styl|js|jsx|mjs|cjs|ts|tsx|json|ya?ml)$/) for (i = 1; i <= np; i++) if (low ~ pat[i]) print "M|" lab[i] "|" path
      for (i = 1; i <= ne; i++) {
        e = "." ext[i]
        if (length(low) > length(e) && substr(low, length(low) - length(e) + 1) == e) {
          d = path
          if (d ~ /\//) sub(/\/[^\/]*$/, "", d); else d = "."
          print "E|" ext[i]; print "D|" d
          break
        }
      }
    }' "$MARKERS" -)"
  total="$(printf '%s\n' "$raw" | grep -c '^E|')"
  if [ "$total" -gt 0 ]; then
    exts="$(printf '%s\n' "$raw" | awk -F'|' '$1 == "E" { print $2 }' | sort | uniq -c | sort -k1,1nr -k2,2 | awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }')"
    globs="$(printf '%s\n' "$raw" | awk -F'|' '$1 == "E" { print $2 }' | sort | uniq -c | sort -k1,1nr -k2,2 | awk '{ printf "%s**/*.%s", (NR > 1 ? " " : ""), $2 }')"
    dirs="$(printf '%s\n' "$raw" | awk -F'|' '$1 == "D" { print $2 }' | sort | uniq -c | sort -k1,1nr -k2,2 | head -n 4 | awk '{ n = $1; $1 = ""; sub(/^ /, ""); printf "%s%s (%s)", (NR > 1 ? ", " : ""), $0, n }')"
    echo "ui: $total arquivos de interface ($exts)"
    echo "ui globs: $globs"
    echo "ui pastas: $dirs"
  else
    echo "ui: nenhum arquivo de interface"
  fi

  design="$(printf '%s\n' "$raw" | awk -F'|' '$1 == "M" && !seen[$2]++ { print $2 "|" $3 }')"
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r pkg; do
      [ -n "$pkg" ] && [ -f "$dir/$pkg" ] || continue
      deps="$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]' "$dir/$pkg" 2>/dev/null | tr -d '\r')"
      [ -n "$deps" ] || continue
      design+=$'\n'"$(printf '%s\n' "$deps" | awk -F'|' -v src="$pkg" '
        NR == FNR { sub(/\r$/, ""); if ($1 == "dep") { n++; dep[n] = $2; lab[n] = $3 } next }
        {
          for (i = 1; i <= n; i++) {
            d = dep[i]
            if (d ~ /\/\*$/) { p = substr(d, 1, length(d) - 1); hit = (substr($0, 1, length(p)) == p) } else hit = ($0 == d)
            if (hit && !seen[lab[i]]++) print lab[i] "|" src
          }
        }' "$MARKERS" -)"
    done < <(printf '%s\n' "$files" | grep -E '(^|/)package\.json$' | grep -vE '(^|/)node_modules/' | head -n 20)
  fi
  design="$(printf '%s\n' "$design" | awk -F'|' 'NF == 2 && !seen[$1]++ { printf "%s%s (%s)", (n++ ? ", " : ""), $1, $2 }')"
  [ -z "$design" ] || echo "ui design: $design"

  nv="$(ui_node_version)"
  major="${nv%%.*}"
  doctor=""
  if [ -z "$nv" ]; then
    echo "node: ausente"
  elif [ "${major:-0}" -lt "$UI_MIN_NODE" ] 2>/dev/null; then
    echo "node: antigo $nv (a captura do kit pede $UI_MIN_NODE ou mais novo)"
  else
    echo "node: ok $nv"
    doctor="$(node "$ENGINE" --doctor 2>/dev/null | tr -d '\r')"
  fi
  browser="$(printf '%s\n' "$doctor" | grep '^navegador: ' | head -n 1)"
  echo "${browser:-navegador: ausente}"

  kit="$dir/.claude/kit.json"
  if [ -f "$kit" ] && command -v jq >/dev/null 2>&1 && jq -e '(.ui.screenshot // "") | type == "string" and length > 0' "$kit" >/dev/null 2>&1; then has_cmd=1; fi
  if [ "$has_cmd" = "1" ]; then
    mode="comando (ui.screenshot do kit.json)"
  elif [ "${browser#navegador: ok}" != "$browser" ]; then
    mode="kit"
  else
    mode="nenhuma — revisão de interface só pelo código"
  fi
  echo "captura: $mode"
  if [ -f "$kit" ] && command -v jq >/dev/null 2>&1 && jq -e '(.ui | type) == "object" and ((.ui.globs // []) | length) > 0' "$kit" >/dev/null 2>&1; then
    echo "rule: $(ui_rule_state "$dir" "$kit")"
    echo "direção: $(ui_design_state "$dir" "$kit")"
  fi
  return 0
}

cmd_capture() {
  local nv major
  nv="$(ui_node_version)"
  major="${nv%%.*}"
  if [ -z "$nv" ]; then
    echo "ui: node não encontrado; sem captura (revisão de interface só pelo código)" >&2
    return 3
  fi
  if [ "${major:-0}" -lt "$UI_MIN_NODE" ] 2>/dev/null; then
    echo "ui: node $nv é antigo (a captura pede $UI_MIN_NODE ou mais novo); sem captura" >&2
    return 3
  fi
  KIT_BASH="$BASH"
  local engine="$ENGINE" a prev=""
  local -a args=()
  # Git Bash converte argumento com cara de caminho (/login) ao chamar um .exe: a conversao fica
  # desligada e so --kit, --out, --serve e o arquivo de --steps, que sao caminhos, sao convertidos aqui.
  if command -v cygpath >/dev/null 2>&1; then
    KIT_BASH="$(cygpath -m "$BASH")"
    engine="$(cygpath -m "$ENGINE")"
    for a in "$@"; do
      case "$prev" in
        --kit | --out | --serve) a="$(cygpath -m "$a")" ;;
        --steps) case "$a" in "["* | "{"*) ;; *) a="$(cygpath -m "$a")" ;; esac ;;
      esac
      args+=("$a")
      prev="$a"
    done
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  else
    args=("$@")
  fi
  export KIT_BASH
  node "$engine" ${args[@]+"${args[@]}"}
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  *) echo "uso: ui.sh status [pasta] | capture [--kit <kit.json>] [--name <nome>] [--routes <a,b>] [--probe-only] [--steps <json | arquivo>] [--attach <url> [--match <trecho>]] [--serve <pasta>] [--out <pasta>]" >&2; exit 2 ;;
esac
