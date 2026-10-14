#!/usr/bin/env bash
# Apoio do /kit:setup e do /kit:init. Nao e hook. Settings do usuario: ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json.
# O kit nunca altera um settings que ja existe: so cria o arquivo quando ele falta; senao, grava
# ao lado a sugestao do que somaria (kit-settings.suggested.json) para o usuario aplicar.
#
#   setup.sh check
#     Plataforma e dependencias (Claude Code >= minima, git, bash, jq). Exit 1 se faltar algo,
#     com o comando de instalacao de cada item.
#
#   setup.sh status
#     check mais as regras de usuario do kit no settings e o marketplace claude-kit. Exit 1 se a
#     maquina precisa do /kit:setup (dependencia faltando, settings ausente, ou regras ausentes sem
#     sugestao gerada). Usado pelo /kit:init antes de configurar o projeto.
#
#   setup.sh propose <todos|opt-in>
#     Template de usuario (sandbox.failIfUnavailable pela plataforma, enabledPlugins."kit@claude-kit"
#     true em todos, false em opt-in). Settings ausente: grava a proposta (settings.kit-proposta.json)
#     e imprime o diff. Settings existente: grava kit-settings.suggested.json so com o que somaria
#     (mais a troca de enabledPlugins do kit, se o escopo pedir) e imprime o diff do resultado.
#
#   setup.sh apply
#     So com settings ausente: grava a proposta como settings. Settings existente: recusa (exit 1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG/settings.json"
PROPOSAL="$CONFIG/settings.kit-proposta.json"
SUGGESTED="$CONFIG/kit-settings.suggested.json"
TEMPLATE="$HERE/../templates/user-settings.json"
PLUGIN_KEY="kit@claude-kit"

cmd_check() {
  local p v missing=0 t
  p="$(kit_platform)"
  case "$p" in
    windows) echo "plataforma: windows nativo — sem sandbox (failIfUnavailable: false). Para ter sandbox, use o WSL2." ;;
    wsl) echo "plataforma: wsl2 — sandbox disponível (failIfUnavailable: true)" ;;
    macos) echo "plataforma: macos — sandbox disponível (failIfUnavailable: true)" ;;
    *) echo "plataforma: linux — sandbox disponível (failIfUnavailable: true)" ;;
  esac

  v="$(kit_claude_version)"
  if ! command -v claude >/dev/null 2>&1; then
    echo "aviso claude: comando fora do PATH, versão não conferida (mínima $KIT_MIN_CLAUDE)"
  elif [ -z "$v" ]; then
    echo "aviso claude: versão ilegível, não conferida (mínima $KIT_MIN_CLAUDE)"
  elif kit_version_lt "$v" "$KIT_MIN_CLAUDE"; then
    echo "falta claude >= $KIT_MIN_CLAUDE (atual $v) — rode: $(kit_install_hint claude "$p")"
    missing=1
  else
    echo "ok claude $v"
  fi

  echo "ok bash ${BASH_VERSION%%(*}"
  for t in git jq; do
    if command -v "$t" >/dev/null 2>&1; then
      echo "ok $t $("$t" --version 2>/dev/null | tr -d '\r' | head -n 1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)"
    else
      echo "falta $t — instale: $(kit_install_hint "$t" "$p")"
      missing=1
    fi
  done
  return "$missing"
}

# Template ajustado a plataforma (failIfUnavailable), gravado em $1.
template_for_platform() {
  local fail
  if [ "$(kit_platform)" = "windows" ]; then fail=false; else fail=true; fi
  jq --argjson f "$fail" '.sandbox.failIfUnavailable = $f' "$TEMPLATE" | tr -d '\r' >"$1"
}

# Maquina pronta para o kit? check + regras de usuario do template presentes + marketplace conhecido.
# Valor existente diferente do template conta como escolha do usuario, nao como falta.
cmd_status() {
  local missing=0 tmp lost n mk="$CONFIG/plugins/known_marketplaces.json"
  cmd_check || missing=1
  if ! command -v jq >/dev/null 2>&1; then
    echo "falta settings: não conferido sem jq"
    return 1
  fi
  tmp="$(mktemp)"
  template_for_platform "$tmp"
  if [ ! -f "$SETTINGS" ]; then
    echo "falta settings: $SETTINGS não existe — rode /kit:setup"
    missing=1
  elif ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    echo "falta settings: $SETTINGS não é JSON válido"
    missing=1
  else
    lost="$(bash "$HERE/merge-json.sh" --check "$tmp" "$SETTINGS" 2>&1 >/dev/null | grep -E ': removido$|item removido' || true)"
    n="$(printf '%s' "$lost" | grep -c . || true)"
    if [ "$n" -eq 0 ]; then
      echo "ok settings"
    elif [ -f "$SUGGESTED" ]; then
      echo "aviso settings: $n regra(s) de usuário do kit ausentes; sugestão em $SUGGESTED (o kit não altera o settings existente)"
    else
      echo "falta settings: $n regra(s) de usuário do kit ausentes em $SETTINGS — rode /kit:setup para gerar a sugestão"
      missing=1
    fi
  fi
  rm -f "$tmp"
  if [ ! -f "$mk" ]; then
    echo "aviso marketplace: $mk não encontrado, não conferido"
  elif jq -e 'has("claude-kit")' "$mk" >/dev/null 2>&1; then
    echo "ok marketplace claude-kit"
  else
    echo "aviso marketplace: claude-kit não registrado — rode /plugin marketplace add r-matias/claude-kit"
  fi
  return "$missing"
}

cmd_propose() {
  local scope="${1:-}" enabled tmp cur
  case "$scope" in
    todos) enabled=true ;;
    opt-in) enabled=false ;;
    *) echo "uso: setup.sh propose <todos|opt-in>" >&2; return 2 ;;
  esac
  command -v jq >/dev/null 2>&1 || { echo "setup: jq não encontrado; rode setup.sh check" >&2; return 2; }
  if [ -f "$SETTINGS" ] && ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    echo "setup: $SETTINGS não é JSON válido; corrija antes" >&2
    return 2
  fi
  mkdir -p "$CONFIG"
  tmp="$(mktemp)"
  template_for_platform "$tmp"
  jq --arg k "$PLUGIN_KEY" --argjson e "$enabled" '.enabledPlugins[$k] = $e' "$tmp" | tr -d '\r' >"$tmp.full"
  mv "$tmp.full" "$tmp"

  if [ ! -f "$SETTINGS" ]; then
    rm -f "$SUGGESTED"
    jq . "$tmp" | tr -d '\r' >"$PROPOSAL"
    rm -f "$tmp"
    diff -u --label "$SETTINGS (novo)" --label "proposta" /dev/null "$PROPOSAL"
    echo "proposta: $PROPOSAL"
    return 0
  fi

  rm -f "$PROPOSAL"
  cur="$(jq -r --arg k "$PLUGIN_KEY" '(.enabledPlugins // {})[$k] | tostring' "$SETTINGS" 2>/dev/null | tr -d '\r')"
  bash "$HERE/merge-json.sh" --additions "$SETTINGS" "$tmp" |
    jq --arg k "$PLUGIN_KEY" --argjson e "$enabled" --arg cur "$cur" \
      'if $cur != "null" and $cur != ($e | tostring) then .enabledPlugins[$k] = $e else . end' | tr -d '\r' >"$SUGGESTED"
  rm -f "$tmp"
  if ! jq empty "$SUGGESTED" >/dev/null 2>&1; then rm -f "$SUGGESTED"; echo "setup: falha ao montar a sugestão" >&2; return 2; fi
  if jq -e '. == {}' "$SUGGESTED" >/dev/null 2>&1; then
    rm -f "$SUGGESTED"
    echo "nada a sugerir: $SETTINGS já tem as regras do kit"
    return 0
  fi
  [ "$cur" != "null" ] && [ "$cur" != "$enabled" ] &&
    echo "troca sugerida: enabledPlugins.\"$PLUGIN_KEY\": $cur -> $enabled"
  diff -u --label "$SETTINGS" --label "$SETTINGS com a sugestão" <(jq . "$SETTINGS" | tr -d '\r') \
    <(bash "$HERE/merge-json.sh" "$SETTINGS" "$SUGGESTED" 2>/dev/null |
      jq --slurpfile s "$SUGGESTED" --arg k "$PLUGIN_KEY" 'if ($s[0].enabledPlugins // {}) | has($k) then .enabledPlugins[$k] = $s[0].enabledPlugins[$k] else . end' | tr -d '\r')
  echo "sugestão: $SUGGESTED (o kit não altera $SETTINGS; aplique se quiser)"
  return 0
}

cmd_apply() {
  if [ -f "$SETTINGS" ]; then
    echo "setup: $SETTINGS já existe e o kit não altera settings existente; aplique a sugestão de $SUGGESTED se quiser" >&2
    return 1
  fi
  [ -f "$PROPOSAL" ] || { echo "setup: sem proposta; rode setup.sh propose" >&2; return 2; }
  jq empty "$PROPOSAL" >/dev/null 2>&1 || { echo "setup: proposta inválida" >&2; return 2; }
  mv "$PROPOSAL" "$SETTINGS"
  echo "gravado: $SETTINGS"
}

case "${1:-}" in
  check) cmd_check ;;
  status) cmd_status ;;
  propose) shift; cmd_propose "$@" ;;
  apply) cmd_apply ;;
  *) echo "uso: setup.sh check | status | propose <todos|opt-in> | apply" >&2; exit 2 ;;
esac
