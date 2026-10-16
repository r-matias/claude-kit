#!/usr/bin/env bash
# Apoio do /kit:setup e do /kit:init. Nao e hook. Nunca grava no settings do usuario
# (${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json): permissao e por projeto, escolhida no /kit:init.
#
#   setup.sh check
#     Plataforma e dependencias (Claude Code >= minima, git, bash, jq; no Linux/WSL2 tambem bwrap e
#     socat do sandbox). Exit 1 se faltar algo, com o comando de instalacao de cada item.
#
#   setup.sh status
#     check mais o marketplace claude-kit registrado (so leitura). Exit 1 se falta dependencia.
#     Usado pelo /kit:init antes de configurar o projeto.
#
#   setup.sh groups
#     Grupos de permissao de templates/project-permissions.json que valem nesta plataforma, um por
#     linha: "<id><TAB><rotulo> — <descricao>". PowerShell so no Windows nativo; sandbox so no macOS
#     e no Linux/WSL2 com bwrap e socat.
#
#   setup.sh permissions <id,id,...|-|--kit <kit.json>> <proposta.json>
#     Acrescenta a proposta (criada se nao existe) as regras dos grupos escolhidos, pelo merge aditivo
#     do merge-json.sh. "-" e nenhum grupo. --kit usa permissions.groups do kit.json (reparo); sem a
#     chave, exit 3. Grupo fora desta plataforma vira "fora: <id> ...". Id desconhecido: exit 2.
#
#   setup.sh guards [kit.json]
#     Valida guards e permissions.groups do kit.json (padrao .claude/kit.json). Cada entrada ignorada
#     ou invalida vira uma linha; exit 1 se houver alguma. Sem problema: "ok guards".
#
#   setup.sh lsp [pasta]
#     Plugins LSP oficiais das linguagens do projeto (pelos manifestos rastreados), um por linha:
#     "lsp <plugin> <binario>: ok", "... falta — instale: <comando>" ou "... falta — sem instalação
#     automática nesta plataforma". Linguagem sem plugin oficial nao aparece.
#
#   setup.sh plans [pasta]
#     Planos com tarefa pendente e mais de 14 dias sem mudanca, um por linha.
#
#   setup.sh alerts [pasta]
#     Alertas que o usuario ja tem, um por linha: "alerta: <origem>: <detalhe>". Hooks Notification e
#     Stop que notificam (settings do usuario, do projeto e local, plugins habilitados), a config
#     preferredNotifChannel e o aviso nativo dos terminais que o suportam. So leitura; sem saida se nada.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"

CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
GROUPS_FILE="$HERE/../templates/project-permissions.json"
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
    windows) echo "plataforma: windows nativo — sem sandbox; o grupo sandbox do /kit:init não se aplica. Para ter sandbox, use o WSL2." ;;
    macos) echo "plataforma: macos — sandbox disponível (grupo sandbox do /kit:init)" ;;
    *)
      local name="linux"
      [ "$p" = "wsl" ] && name="wsl2"
      if [ -n "$sbm" ]; then
        echo "plataforma: $name — sandbox exige bwrap e socat (grupo sandbox do /kit:init só depois de instalar)"
      else
        echo "plataforma: $name — sandbox disponível (grupo sandbox do /kit:init)"
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

# Maquina pronta para o kit? check mais o marketplace conhecido. O settings do usuario nao conta.
cmd_status() {
  local missing=0 mk="$CONFIG/plugins/known_marketplaces.json"
  cmd_check || missing=1
  if ! command -v jq >/dev/null 2>&1; then
    echo "aviso marketplace: não conferido sem jq"
  elif [ ! -f "$mk" ]; then
    echo "aviso marketplace: $mk não encontrado, não conferido"
  elif jq -e 'has("claude-kit")' "$mk" >/dev/null 2>&1; then
    echo "ok marketplace claude-kit"
  else
    echo "aviso marketplace: claude-kit não registrado"
  fi
  return "$missing"
}

# Grupos que valem nesta plataforma, como array JSON. PowerShell so no Windows nativo, onde os
# guardas do kit nao a cobrem. Sandbox so no macOS e no Linux/WSL2 com bwrap e socat; sem ele,
# failIfUnavailable travaria todo Bash.
groups_here() {
  local p sb=true
  p="$(kit_platform)"
  if [ "$p" = "windows" ] || [ -n "$(sandbox_missing)" ]; then sb=false; fi
  jq -c --arg p "$p" --argjson sb "$sb" '[.groups[]
    | select((.platforms // null) == null or any(.platforms[]; . == $p))
    | select(((.requires_sandbox // false) | not) or $sb)]' "$GROUPS_FILE" | tr -d '\r'
}

cmd_groups() {
  command -v jq >/dev/null 2>&1 || { echo "setup: jq não encontrado; rode setup.sh check" >&2; return 2; }
  groups_here | jq -r '.[] | "\(.id)\t\(.label) — \(.description)"' | tr -d '\r'
}

cmd_permissions() {
  local ids prop here unknown frag id
  command -v jq >/dev/null 2>&1 || { echo "setup: jq não encontrado; rode setup.sh check" >&2; return 2; }
  if [ "${1:-}" = "--kit" ]; then
    [ -f "${2:-}" ] || { echo "setup: kit.json não encontrado: ${2:-}" >&2; return 2; }
    if ! jq -e '.permissions.groups | type == "array"' "$2" >/dev/null 2>&1; then
      echo "setup: sem escolha de grupos: permissions.groups ausente em $2" >&2
      return 3
    fi
    ids="$(jq -r '.permissions.groups | map(strings) | join(",")' "$2" | tr -d '\r')"
    [ -n "$ids" ] || ids="-"
    shift 2
  else
    ids="${1:-}"
    [ $# -gt 0 ] && shift
  fi
  prop="${1:-}"
  if [ -z "$ids" ] || [ -z "$prop" ]; then
    echo "uso: setup.sh permissions <id,id,...|-|--kit <kit.json>> <proposta.json>" >&2
    return 2
  fi
  [ "$ids" = "-" ] && ids=""
  if [ -f "$prop" ] && ! jq empty "$prop" >/dev/null 2>&1; then
    echo "setup: $prop não é JSON válido" >&2
    return 2
  fi
  unknown="$(jq -r --arg ids "$ids" '(($ids | split(",")) - [""]) - (.groups | map(.id)) | .[]' "$GROUPS_FILE" | tr -d '\r')"
  if [ -n "$unknown" ]; then
    echo "setup: grupo desconhecido: $(printf '%s' "$unknown" | tr '\n' ' ')" >&2
    return 2
  fi
  here="$(groups_here)"
  for id in ${ids//,/ }; do
    jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$here" >/dev/null || echo "fora: $id (não se aplica nesta plataforma)"
  done
  frag="$(mktemp)"
  jq --arg ids "$ids" '
    def merge($x; $y):
      if ($x | type) == "object" and ($y | type) == "object" then
        reduce ($y | keys_unsorted[]) as $k ($x; .[$k] = (if ($x | has($k)) then merge($x[$k]; $y[$k]) else $y[$k] end))
      elif ($x | type) == "array" and ($y | type) == "array" then
        reduce $y[] as $e ($x; if any(.[]; . == $e) then . else . + [$e] end)
      else $x end;
    ($ids | split(",")) as $sel
    | reduce (.[] | select(.id as $i | any($sel[]; . == $i)) | .settings) as $s ({}; merge(.; $s))' \
    <<<"$here" | tr -d '\r' >"$frag"
  [ -f "$prop" ] || printf '{}\n' >"$prop"
  if ! "${BASH:-bash}" "$HERE/merge-json.sh" "$prop" "$frag" >"$frag.m"; then
    rm -f "$frag" "$frag.m"
    return 2
  fi
  jq . "$frag.m" | tr -d '\r' >"$prop"
  rm -f "$frag" "$frag.m"
  echo "grupos: ${ids:-nenhum}"
  return 0
}

# guards e permissions.groups do kit.json: glob largo ou segredo em allow_write, item sem glob e
# grupo desconhecido.
cmd_guards() {
  local kit="${1:-.claude/kit.json}" out="" g
  command -v jq >/dev/null 2>&1 || { echo "setup: jq não encontrado; rode setup.sh check" >&2; return 2; }
  [ -f "$kit" ] || { echo "setup: kit.json não encontrado: $kit" >&2; return 2; }
  jq empty "$kit" >/dev/null 2>&1 || { echo "setup: $kit não é JSON válido" >&2; return 2; }
  KIT_JSON="$kit"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if kit_glob_broad "$g"; then
      out+="ignorado: guards.allow_write \"$g\" — glob largo demais; liste o caminho exato"$'\n'
    elif kit_glob_secret "$g"; then
      out+="ignorado: guards.allow_write \"$g\" — segredo não tem exceção"$'\n'
    fi
  done < <(kit_guard_allow_entries)
  out+="$(jq -r --slurpfile gr "$GROUPS_FILE" '
    def noglob: (type != "string") and ((type != "object") or ((.glob // "") | type) != "string" or (.glob // "") == "");
    (.guards // {}) as $g
    | (if ($g | type) != "object" then "inválido: guards precisa ser objeto"
       else (["allow_write", "deny_write"][] as $k | ($g[$k] // []) |
         if type != "array" then "inválido: guards.\($k) precisa ser lista"
         else to_entries[] | select(.value | noglob) | "inválido: guards.\($k)[\(.key)] sem glob" end) end),
      ((.permissions.groups // []) |
       if type != "array" then "inválido: permissions.groups precisa ser lista"
       else .[] | select(. as $i | ($gr[0].groups | map(.id) | index($i)) == null) | "inválido: permissions.groups \(tojson) desconhecido" end)' "$kit" 2>/dev/null | tr -d '\r')"
  out="$(printf '%s\n' "$out" | sed '/^$/d')"
  if [ -z "$out" ]; then
    echo "ok guards"
    return 0
  fi
  printf '%s\n' "$out"
  return 1
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

# Comando de hook que notifica: o proprio texto ou o script que ele chama. Uso: alert_cmd <cmd> <pasta-do-projeto> [raiz-do-plugin]
ALERT_RE='notify|notification|toast|osascript|ntfy|webhook|terminal-notifier|burnttoast|messagebox|(^|[^a-z])(af|pa|a)?play([^a-z]|$)'
alert_cmd() {
  local c="$1" f
  printf '%s' "$c" | grep -Eiq -- "$ALERT_RE" && return 0
  c="${c//\$\{CLAUDE_PROJECT_DIR\}/$2}"
  c="${c//\$CLAUDE_PROJECT_DIR/$2}"
  [ -z "${3:-}" ] || c="${c//\$\{CLAUDE_PLUGIN_ROOT\}/$3}"
  c="${c//\~\//$HOME/}"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in /* | [A-Za-z]:/*) ;; *) f="$2/$f" ;; esac
    [ -f "$f" ] && grep -Eiq -- "$ALERT_RE" "$f" 2>/dev/null && return 0
  done < <(printf '%s' "$c" | tr '\\' / | grep -oE "[^ \"']+\.(sh|ps1|py|js|mjs|cmd|bat)" | head -n 5)
  return 1
}

# Hooks Notification/Stop de um JSON de hooks ({"hooks": {...}} ou o objeto de eventos). Uso: alert_hooks <json> <origem> <pasta> [raiz-do-plugin]
alert_hooks() {
  local ev c short
  while IFS=$'\t' read -r ev c; do
    [ -n "$c" ] || continue
    alert_cmd "$c" "$3" "${4:-}" || continue
    short="$(printf '%s' "$c" | tr -s ' \t' ' ' | cut -c1-80)"
    echo "alerta: $2: hook $ev ($short)"
  done < <(jq -r '(if has("hooks") then .hooks else . end) // {} | to_entries[]? | select(.key == "Notification" or .key == "Stop")
    | .key as $e | .value[]?.hooks[]? | select(.type == "command") | "\($e)\t\(.command // "" | gsub("[\t\r\n]"; " "))"' "$1" 2>/dev/null | tr -d '\r')
}

cmd_alerts() {
  local dir proj f label v plugin ip cfg_label any_channel=0 pj
  command -v jq >/dev/null 2>&1 || { echo "setup: jq não encontrado" >&2; return 2; }
  dir="$(cd "${1:-.}" && pwd)" || return 2
  proj="$(kit_session_root "$dir")"
  cfg_label="$CONFIG"
  case "$CONFIG" in "$HOME"/*) cfg_label="~/${CONFIG#"$HOME"/}" ;; esac
  {
    for f in "$CONFIG/settings.json" "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
      [ -f "$f" ] || continue
      case "$f" in "$CONFIG"/*) label="$cfg_label/settings.json" ;; *) label="${f#"$proj"/}" ;; esac
      alert_hooks "$f" "$label" "$proj"
      v="$(jq -r '.preferredNotifChannel // empty' "$f" 2>/dev/null | tr -d '\r')"
      if [ -n "$v" ]; then
        any_channel=1
        [ "$v" = "notifications_disabled" ] || echo "alerta: $label: preferredNotifChannel=$v (aviso nativo do Claude Code)"
      fi
    done
    for f in "$CONFIG/.claude.json" "$HOME/.claude.json"; do
      [ -f "$f" ] || continue
      v="$(jq -r '.preferredNotifChannel // empty' "$f" 2>/dev/null | tr -d '\r')"
      [ -n "$v" ] || continue
      any_channel=1
      case "$f" in "$HOME"/*) label="~/${f#"$HOME"/}" ;; *) label="$f" ;; esac
      [ "$v" = "notifications_disabled" ] || echo "alerta: $label: preferredNotifChannel=$v (aviso nativo do Claude Code)"
    done
    # Sem canal configurado, o padrao (auto) ja notifica no iTerm2, no Ghostty e no Kitty.
    if [ "$any_channel" = "0" ]; then
      case "${TERM_PROGRAM:-}" in
        iTerm.app) echo "alerta: terminal iTerm2: aviso nativo do Claude Code (preferredNotifChannel auto)" ;;
        ghostty) echo "alerta: terminal Ghostty: aviso nativo do Claude Code (preferredNotifChannel auto)" ;;
        *) [ -z "${KITTY_WINDOW_ID:-}" ] || echo "alerta: terminal Kitty: aviso nativo do Claude Code (preferredNotifChannel auto)" ;;
      esac
    fi
    # Plugins habilitados (usuario < projeto < local), fora o proprio kit, pelo installPath registrado.
    pj="$CONFIG/plugins/installed_plugins.json"
    if [ -f "$pj" ]; then
      while IFS= read -r plugin; do
        [ -n "$plugin" ] || continue
        case "$plugin" in kit@*) continue ;; esac
        ip="$(jq -r --arg p "$plugin" '(.plugins[$p] // []) | map(.installPath // empty) | .[0] // empty' "$pj" 2>/dev/null | tr -d '\r')"
        ip="$(kit_norm_path "$ip")"
        [ -n "$ip" ] && [ -d "$ip" ] || continue
        [ -f "$ip/hooks/hooks.json" ] && alert_hooks "$ip/hooks/hooks.json" "plugin $plugin" "$proj" "$ip"
        [ -f "$ip/.claude-plugin/plugin.json" ] && jq -e '(.hooks // null) | type == "object"' "$ip/.claude-plugin/plugin.json" >/dev/null 2>&1 &&
          alert_hooks "$ip/.claude-plugin/plugin.json" "plugin $plugin" "$proj" "$ip"
      done < <(for f in "$CONFIG/settings.json" "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
          [ -f "$f" ] && jq -c '.enabledPlugins // {}' "$f" 2>/dev/null
        done | jq -rs 'add // {} | to_entries[] | select(.value == true) | .key' 2>/dev/null | tr -d '\r')
    fi
  } | awk '!seen[$0]++'
  return 0
}

case "${1:-}" in
  check) cmd_check ;;
  status) cmd_status ;;
  groups) cmd_groups ;;
  permissions) shift; cmd_permissions "$@" ;;
  guards) shift; cmd_guards "$@" ;;
  lsp) shift; cmd_lsp "$@" ;;
  plans) shift; cmd_plans "$@" ;;
  alerts) shift; cmd_alerts "$@" ;;
  *) echo "uso: setup.sh check | status | groups | permissions <grupos> <proposta.json> | guards [kit.json] | lsp [pasta] | plans [pasta] | alerts [pasta]" >&2; exit 2 ;;
esac
