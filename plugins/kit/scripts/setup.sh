#!/usr/bin/env bash
# Apoio do /kit:setup e do /kit:init. Nao e hook. Settings do usuario: ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json.
# Settings existente so recebe merge aditivo (merge-json.sh --apply): backup ao lado, nada removido,
# valor existente mantido. A unica troca possivel e enabledPlugins."kit@claude-kit", pelo escopo escolhido.
#
#   setup.sh check
#     Plataforma e dependencias (Claude Code >= minima, git, bash, jq; no Linux/WSL2 tambem bwrap e
#     socat do sandbox). Exit 1 se faltar algo, com o comando de instalacao de cada item.
#
#   setup.sh status
#     check mais as regras de usuario do kit no settings e o marketplace claude-kit. Exit 1 se a
#     maquina precisa do setup (dependencia faltando, settings ausente ou regra do kit ausente).
#     Usado pelo /kit:init antes de configurar o projeto.
#
#   setup.sh propose <todos|opt-in>
#     Template de usuario ajustado a plataforma (PowerShell em deny so no Windows nativo; bloco
#     sandbox so onde ha sandbox) com enabledPlugins."kit@claude-kit" true em todos, false em opt-in.
#     Grava a proposta (settings.kit-proposta.json) e imprime o diff do settings como ficaria.
#
#   setup.sh apply
#     Grava a proposta: cria o settings ou faz o merge aditivo com backup. Exit 1 se o merge perderia algo.
#
#   setup.sh lsp [pasta]
#     Plugins LSP oficiais das linguagens do projeto (pelos manifestos rastreados), um por linha:
#     "lsp <plugin> <binario>: ok", "... falta — instale: <comando>" ou "... falta — sem instalação
#     automática nesta plataforma". Linguagem sem plugin oficial nao aparece.
#
#   setup.sh plans [pasta]
#     Planos com tarefa pendente e mais de 14 dias sem mudanca, um por linha.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG/settings.json"
PROPOSAL="$CONFIG/settings.kit-proposta.json"
TEMPLATE="$HERE/../templates/user-settings.json"
PLUGIN_KEY="kit@claude-kit"
PLUGIN_PATH='["enabledPlugins","kit@claude-kit"]'
LSP_MARKETPLACE="claude-plugins-official"

# Linux e WSL2: o sandbox do Claude Code precisa de bwrap (bubblewrap) e socat. Lista os ausentes.
sandbox_missing() {
  local t out=""
  case "$(kit_platform)" in linux | wsl) ;; *) return 0 ;; esac
  for t in bwrap socat; do command -v "$t" >/dev/null 2>&1 || out+="$t "; done
  printf '%s' "${out% }"
}

# Ubuntu 24.04+ restringe user namespaces sem privilegio via AppArmor; o bwrap pode falhar mesmo instalado.
USERNS_SYSCTL="${KIT_USERNS_SYSCTL:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}"
userns_restricted() {
  case "$(kit_platform)" in linux | wsl) ;; *) return 1 ;; esac
  [ "$(cat "$USERNS_SYSCTL" 2>/dev/null | tr -d '[:space:]')" = "1" ]
}

cmd_check() {
  local p v missing=0 t sbm
  p="$(kit_platform)"
  sbm="$(sandbox_missing)"
  case "$p" in
    windows) echo "plataforma: windows nativo — sem sandbox (failIfUnavailable: false). Para ter sandbox, use o WSL2." ;;
    macos) echo "plataforma: macos — sandbox disponível (failIfUnavailable: true)" ;;
    *)
      local name="linux"
      [ "$p" = "wsl" ] && name="wsl2"
      if [ -n "$sbm" ]; then
        echo "plataforma: $name — sandbox exige bwrap e socat (failIfUnavailable: false até instalar)"
      else
        echo "plataforma: $name — sandbox disponível (failIfUnavailable: true)"
      fi ;;
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
  for t in $sbm; do
    echo "falta $t (sandbox) — instale: $(kit_install_hint "$t" "$p")"
    missing=1
  done
  if userns_restricted; then
    echo "aviso sandbox: o AppArmor restringe user namespaces (Ubuntu 24.04+) e o bwrap pode falhar; veja a seção de sandbox no Linux da documentação do Claude Code"
  fi
  return "$missing"
}

# Template ajustado a plataforma, gravado em $1. PowerShell em deny so no Windows nativo, onde os
# guardas do kit nao a cobrem. Bloco sandbox (e o ask de dangerouslyDisableSandbox) so onde ha
# sandbox: macOS, ou Linux/WSL2 com bwrap e socat; sem ele, failIfUnavailable travaria todo Bash.
template_for_platform() {
  local p sb=true
  p="$(kit_platform)"
  if [ "$p" = "windows" ] || [ -n "$(sandbox_missing)" ]; then sb=false; fi
  jq --arg p "$p" --argjson sb "$sb" '
    (if $p == "windows" then .permissions.deny += ["PowerShell"] else . end)
    | (if $sb then .sandbox.failIfUnavailable = true
       else del(.sandbox) | .permissions.ask -= ["Bash(dangerouslyDisableSandbox:true)"] end)' "$TEMPLATE" | tr -d '\r' >"$1"
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
    echo "falta settings: $SETTINGS não existe"
    missing=1
  elif ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    echo "falta settings: $SETTINGS não é JSON válido"
    missing=1
  else
    # Falta o que o merge aditivo acrescentaria; deny que sombrearia allow/ask do usuario nao conta.
    "${BASH:-bash}" "$HERE/merge-json.sh" "$SETTINGS" "$tmp" >"$tmp.m" 2>/dev/null
    lost="$("${BASH:-bash}" "$HERE/merge-json.sh" --check "$tmp.m" "$SETTINGS" 2>&1 >/dev/null | grep -E ': removido$|item removido' || true)"
    rm -f "$tmp.m"
    n="$(printf '%s' "$lost" | grep -c . || true)"
    if [ "$n" -eq 0 ]; then
      echo "ok settings"
    else
      echo "falta settings: $n regra(s) de usuário do kit ausentes em $SETTINGS"
      missing=1
    fi
  fi
  rm -f "$tmp"
  if [ ! -f "$mk" ]; then
    echo "aviso marketplace: $mk não encontrado, não conferido"
  elif jq -e 'has("claude-kit")' "$mk" >/dev/null 2>&1; then
    echo "ok marketplace claude-kit"
  else
    echo "aviso marketplace: claude-kit não registrado"
  fi
  return "$missing"
}

cmd_propose() {
  local scope="${1:-}" enabled tmp
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
  jq --arg k "$PLUGIN_KEY" --argjson e "$enabled" '.enabledPlugins[$k] = $e' "$tmp" | tr -d '\r' >"$PROPOSAL"
  rm -f "$tmp"
  "${BASH:-bash}" "$HERE/merge-json.sh" --preview --prefer "$PLUGIN_PATH" "$SETTINGS" "$PROPOSAL"
  echo "proposta: $PROPOSAL"
  return 0
}

cmd_apply() {
  local code
  [ -f "$PROPOSAL" ] || { echo "setup: sem proposta; rode setup.sh propose" >&2; return 2; }
  jq empty "$PROPOSAL" >/dev/null 2>&1 || { echo "setup: proposta inválida" >&2; return 2; }
  "${BASH:-bash}" "$HERE/merge-json.sh" --apply --prefer "$PLUGIN_PATH" "$SETTINGS" "$PROPOSAL"
  code=$?
  [ "$code" -eq 0 ] && rm -f "$PROPOSAL"
  return "$code"
}

# Plugins LSP oficiais por linguagem (marketplace claude-plugins-official), em templates/lsp-plugins.txt:
# plugin|binario|manifestos (nome do arquivo, * vale qualquer trecho)|instalacao ("macos:" = so no
# macOS; vazio = sem instalacao automatica).
LSP_TABLE_FILE="$HERE/../templates/lsp-plugins.txt"

cmd_lsp() {
  local dir="${1:-.}" p plugin bin globs inst names tool
  git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "setup: $dir não é repositório git" >&2; return 2; }
  p="$(kit_platform)"
  names="$(git -C "$dir" ls-files -co --exclude-standard 2>/dev/null | tr -d '\r' | awk -F/ '{ print $NF }' | sort -u)"
  while IFS='|' read -r plugin bin globs inst; do
    [ -n "$plugin" ] || continue
    printf '%s\n' "$names" | awk -v gl="$globs" '
      BEGIN { n = split(gl, g, " "); for (i = 1; i <= n; i++) { gsub(/\./, "\\.", g[i]); gsub(/\*/, ".*", g[i]); g[i] = "^" g[i] "$" } }
      { for (i = 1; i <= n; i++) if ($0 ~ g[i]) { found = 1; exit } }
      END { exit !found }' || continue
    if command -v "$bin" >/dev/null 2>&1; then
      echo "lsp $plugin@$LSP_MARKETPLACE $bin: ok"
      continue
    fi
    case "$inst" in
      macos:*) if [ "$p" = "macos" ]; then inst="${inst#macos:}"; else inst=""; fi ;;
    esac
    tool="${inst%% *}"
    if [ -n "$inst" ] && command -v "$tool" >/dev/null 2>&1; then
      echo "lsp $plugin@$LSP_MARKETPLACE $bin: falta — instale: $inst"
    else
      echo "lsp $plugin@$LSP_MARKETPLACE $bin: falta — sem instalação automática nesta plataforma"
    fi
  done < <(tr -d '\r' <"$LSP_TABLE_FILE")
  return 0
}

cmd_plans() {
  local dir="${1:-.}" root now m d t f
  command -v jq >/dev/null 2>&1 || { echo "setup: jq não encontrado" >&2; return 2; }
  root="$(kit_session_root "$(cd "$dir" && pwd)")"
  now="$(date +%s)"
  while IFS=$'\t' read -r m d t f; do
    [ -n "$f" ] || continue
    echo "plano parado há $(((now - m) / 86400)) dias: $(kit_rel_to "$root" "$f") ($d/$t)"
  done < <(kit_stale_plans "$root")
  return 0
}

case "${1:-}" in
  check) cmd_check ;;
  status) cmd_status ;;
  propose) shift; cmd_propose "$@" ;;
  apply) cmd_apply ;;
  lsp) shift; cmd_lsp "$@" ;;
  plans) shift; cmd_plans "$@" ;;
  *) echo "uso: setup.sh check | status | propose <todos|opt-in> | apply | lsp [pasta] | plans [pasta]" >&2; exit 2 ;;
esac
