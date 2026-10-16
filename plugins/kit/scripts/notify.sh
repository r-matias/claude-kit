#!/usr/bin/env bash
# Notification: avisa que a sessao aguarda o usuario ("⏳ <projeto>: <mensagem>"), se notify.waiting
# estiver ligado no kit.json. --send: entrega KIT_NOTIFY_TITLE e KIT_NOTIFY_MSG (usado pelo
# verify-gate no "concluido"), com KIT_NOTIFY_SOUND e os nomes das variaveis de push em
# KIT_NOTIFY_NTFY_ENV e KIT_NOTIFY_DISCORD_ENV.
# Toast do Windows (Git Bash e WSL) pelo powershell.exe, osascript no macOS, notify-send no Linux;
# sem nenhum, o sino do terminal. Push opcional por ntfy e webhook do Discord. Titulo e mensagem
# chegam ao powershell/osascript por variavel de ambiente, nunca dentro do comando.
# KIT_NOTIFY_DRY_RUN=1 imprime no stdout o que rodaria, sem executar; KIT_NOTIFY_PLATFORM troca a
# plataforma detectada. Sempre exit 0.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'exit 0' EXIT

DRY="${KIT_NOTIFY_DRY_RUN:-}"

# Texto de um argumento para a saida do dry-run: cru se for simples, senao entre aspas simples.
show_arg() {
  case "$1" in
    '' | *[!A-Za-z0-9_./:@=+-]*) kit_quote "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

kit_timeout() {
  local s="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi
}

# Uso: run <corpo-stdin|-> <comando...>. Corpo "-" e sem stdin.
run() {
  local body="$1" a line="run:"
  shift
  if [ -n "$DRY" ]; then
    for a in "$@"; do line+=" $(show_arg "$a")"; done
    printf 'notify: %s\n' "$line"
    [ "$body" = "-" ] || printf 'notify: body: %s\n' "$body"
    return 0
  fi
  if [ "$body" = "-" ]; then
    kit_timeout 10 "$@" </dev/null >/dev/null 2>&1
  else
    printf '%s' "$body" | kit_timeout 8 "$@" >/dev/null 2>&1
  fi
}

show_env() {
  [ -z "$DRY" ] || printf 'notify: env: %s=%s\n' "$1" "$2"
}

PS_TOAST="\$ErrorActionPreference = 'Stop'
\$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
\$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
\$t = \$x.GetElementsByTagName('text')
\$null = \$t.Item(0).AppendChild(\$x.CreateTextNode([string]\$env:KIT_NOTIFY_TITLE))
\$null = \$t.Item(1).AppendChild(\$x.CreateTextNode([string]\$env:KIT_NOTIFY_MSG))
if (\$env:KIT_NOTIFY_SOUND -ne 'true') { \$a = \$x.CreateElement('audio'); \$a.SetAttribute('silent', 'true'); \$null = \$x.DocumentElement.AppendChild(\$a) }
\$id = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\$id).Show([Windows.UI.Notifications.ToastNotification]::new(\$x))"

JXA="ObjC.import('Foundation');
var e = \$.NSProcessInfo.processInfo.environment;
function v(k) { var x = ObjC.unwrap(e.objectForKey(k)); return x === undefined ? '' : String(x); }
var a = Application.currentApplication();
a.includeStandardAdditions = true;
var o = { withTitle: v('KIT_NOTIFY_TITLE') };
if (v('KIT_NOTIFY_SOUND') === 'true') o.soundName = 'Glass';
a.displayNotification(v('KIT_NOTIFY_MSG'), o);"

# Toast do Windows. No WSL o powershell.exe vem da interop e as variaveis passam pelo WSLENV.
toast_windows() {
  local ps
  ps="$(command -v powershell.exe 2>/dev/null)"
  [ -n "$ps" ] || [ ! -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ] || ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
  if [ -n "$DRY" ]; then ps=powershell.exe; elif [ -z "$ps" ]; then return 1; fi
  if [ "$PLAT" = "wsl" ]; then
    WSLENV="KIT_NOTIFY_TITLE/u:KIT_NOTIFY_MSG/u:KIT_NOTIFY_SOUND/u${WSLENV:+:$WSLENV}"
    export WSLENV
    show_env WSLENV "$WSLENV"
  fi
  show_env KIT_NOTIFY_TITLE "$KIT_NOTIFY_TITLE"
  show_env KIT_NOTIFY_MSG "$KIT_NOTIFY_MSG"
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  run - "$ps" -NoProfile -NonInteractive -WindowStyle Hidden -Command "$PS_TOAST"
}

toast_macos() {
  [ -n "$DRY" ] || command -v osascript >/dev/null 2>&1 || return 1
  show_env KIT_NOTIFY_TITLE "$KIT_NOTIFY_TITLE"
  show_env KIT_NOTIFY_MSG "$KIT_NOTIFY_MSG"
  run - osascript -l JavaScript -e "$JXA"
}

# notify-send recebe titulo e mensagem como argumentos, sem shell no meio.
toast_linux() {
  [ -n "$DRY" ] || command -v notify-send >/dev/null 2>&1 || return 1
  run - notify-send -a "Claude Code" -- "$KIT_NOTIFY_TITLE" "$KIT_NOTIFY_MSG" || return 1
  [ "$KIT_NOTIFY_SOUND" = "true" ] || return 0
  if [ -n "$DRY" ] || command -v canberra-gtk-play >/dev/null 2>&1; then
    run - canberra-gtk-play -i complete
  elif command -v paplay >/dev/null 2>&1 && [ -f /usr/share/sounds/freedesktop/stereo/complete.oga ]; then
    run - paplay /usr/share/sounds/freedesktop/stereo/complete.oga
  fi
  return 0
}

bell() {
  if [ -n "$DRY" ]; then printf 'notify: bell\n'; return 0; fi
  { printf '\a' >/dev/tty; } 2>/dev/null || printf '\a' >&2
}

# Valor da variavel de ambiente cujo nome esta em $1; vazio se o nome for invalido.
env_value() {
  case "$1" in '' | [0-9]* | *[!A-Za-z0-9_]*) return 0 ;; esac
  printf '%s' "${!1:-}"
}

# ntfy: tópico simples vai para https://ntfy.sh; URL completa (servidor proprio) e dividida em
# servidor e topico. Publicacao em JSON, sem titulo em cabecalho HTTP.
push_ntfy() {
  local v server topic body
  v="$(env_value "${KIT_NOTIFY_NTFY_ENV:-}")"
  [ -n "$v" ] || return 0
  case "$v" in
    http://* | https://*) server="${v%/*}"; topic="${v##*/}" ;;
    *) server="https://ntfy.sh"; topic="$v" ;;
  esac
  case "$topic" in '' | *[!A-Za-z0-9_-]*) return 0 ;; esac
  body="$(jq -cn --arg t "$topic" --arg ti "$KIT_NOTIFY_TITLE" --arg m "$KIT_NOTIFY_MSG" '{topic: $t, title: $ti, message: $m}')" || return 0
  run "$body" curl -fsS --max-time 5 -H "Content-Type: application/json" -d @- "$server/"
}

# Discord: sem mencoes (@everyone vindo da mensagem nao notifica ninguem), ate 1900 caracteres.
push_discord() {
  local url body
  url="$(env_value "${KIT_NOTIFY_DISCORD_ENV:-}")"
  case "$url" in https://*) ;; *) return 0 ;; esac
  body="$(jq -cn --arg ti "$KIT_NOTIFY_TITLE" --arg m "$KIT_NOTIFY_MSG" \
    '{content: ("**" + $ti + "**\n" + $m)[0:1900], allowed_mentions: {parse: []}}')" || return 0
  run "$body" curl -fsS --max-time 5 -H "Content-Type: application/json" -d @- "$url"
}

deliver() {
  local ok=1
  PLAT="${KIT_NOTIFY_PLATFORM:-$(kit_platform)}"
  KIT_NOTIFY_TITLE="${KIT_NOTIFY_TITLE:-Claude Code}"
  KIT_NOTIFY_MSG="${KIT_NOTIFY_MSG:-}"
  KIT_NOTIFY_SOUND="${KIT_NOTIFY_SOUND:-false}"
  export KIT_NOTIFY_TITLE KIT_NOTIFY_MSG KIT_NOTIFY_SOUND
  if command -v curl >/dev/null 2>&1 || [ -n "$DRY" ]; then
    if [ -n "$DRY" ]; then
      push_ntfy
      push_discord
    else
      push_ntfy &
      push_discord &
    fi
  fi
  case "$PLAT" in
    windows | wsl) toast_windows && ok=0 ;;
    macos) toast_macos && ok=0 ;;
    *) toast_linux && ok=0 ;;
  esac
  [ "$ok" = "0" ] || bell
  wait
}

if [ "${1:-}" = "--send" ]; then
  deliver
  exit 0
fi

kit_require_jq
kit_read_input
ROOT="$(kit_notify_root "$(kit_cwd)")"
[ -n "$ROOT" ] || exit 0
kit_notify_load "$ROOT"
[ "$KIT_NOTIFY_WAITING" = "true" ] || exit 0
msg="$(kit_field '.message')"
[ -n "$msg" ] || msg="$(kit_field '.title')"
[ -n "$msg" ] || msg="aguardando resposta"
KIT_NOTIFY_TITLE="Claude Code"
KIT_NOTIFY_MSG="⏳ ${ROOT##*/}: $msg"
deliver
exit 0
