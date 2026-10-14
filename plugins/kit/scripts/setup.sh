#!/usr/bin/env bash
# Apoio do /kit:setup. Nao e hook. Settings do usuario: ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json.
#
#   setup.sh check
#     Plataforma e dependencias (Claude Code >= minima, git, bash, jq). Exit 1 se faltar algo,
#     com o comando de instalacao de cada item.
#
#   setup.sh propose <todos|opt-in>
#     Mescla templates/user-settings.json no settings do usuario e grava a proposta ao lado
#     (settings.kit-proposta.json). Ajusta sandbox.failIfUnavailable pela plataforma e fixa
#     enabledPlugins."kit@claude-kit" (true em todos, false em opt-in). Imprime o diff; conflitos no stderr.
#
#   setup.sh apply
#     Grava a proposta no settings e confere com merge-json.sh --check que so houve adicoes (a unica
#     troca aceita e enabledPlugins."kit@claude-kit"). Se a conferencia falhar, restaura o original.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG/settings.json"
PROPOSAL="$CONFIG/settings.kit-proposta.json"
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

cmd_propose() {
  local scope="${1:-}" enabled fail tmp
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
  if [ "$(kit_platform)" = "windows" ]; then fail=false; else fail=true; fi
  mkdir -p "$CONFIG"
  tmp="$(mktemp)"
  jq --argjson f "$fail" '.sandbox.failIfUnavailable = $f' "$TEMPLATE" | tr -d '\r' >"$tmp"
  bash "$HERE/merge-json.sh" "$SETTINGS" "$tmp" |
    jq --arg k "$PLUGIN_KEY" --argjson e "$enabled" '.enabledPlugins[$k] = $e' | tr -d '\r' >"$PROPOSAL"
  local code=$?
  rm -f "$tmp"
  [ "$code" -eq 0 ] && jq empty "$PROPOSAL" >/dev/null 2>&1 || { rm -f "$PROPOSAL"; echo "setup: falha ao montar a proposta" >&2; return 2; }

  if [ -f "$SETTINGS" ]; then
    diff -u --label "$SETTINGS" --label "proposta" <(jq . "$SETTINGS" | tr -d '\r') "$PROPOSAL"
  else
    diff -u --label "$SETTINGS (novo)" --label "proposta" /dev/null "$PROPOSAL"
  fi
  echo "proposta: $PROPOSAL"
  return 0
}

cmd_apply() {
  local before lost
  [ -f "$PROPOSAL" ] || { echo "setup: sem proposta; rode setup.sh propose" >&2; return 2; }
  before="$(mktemp)"
  if [ -f "$SETTINGS" ]; then cp "$SETTINGS" "$before"; else rm -f "$before"; fi
  cp "$PROPOSAL" "$SETTINGS"
  lost="$(bash "$HERE/merge-json.sh" --check "$before" "$SETTINGS" 2>&1 >/dev/null | grep -vF "\$.enabledPlugins.$PLUGIN_KEY: ")"
  if [ -n "$lost" ]; then
    if [ -f "$before" ]; then cp "$before" "$SETTINGS"; else rm -f "$SETTINGS"; fi
    rm -f "$before"
    echo "setup: a gravação removeria ou alteraria valores; settings restaurado" >&2
    printf '%s\n' "$lost" >&2
    return 1
  fi
  rm -f "$before" "$PROPOSAL"
  echo "gravado: $SETTINGS"
}

case "${1:-}" in
  check) cmd_check ;;
  propose) shift; cmd_propose "$@" ;;
  apply) cmd_apply ;;
  *) echo "uso: setup.sh check | propose <todos|opt-in> | apply" >&2; exit 2 ;;
esac
