#!/usr/bin/env bash
# Passa as fixtures de tests/fixtures pelos scripts do kit e confere decisao, exit code e saidas.
# Uso: tests/run-tests.sh [--awk <mawk|gawk|busybox>] [--bash <caminho>] [--jobs N] [--changed] [filtro]
# --awk roda tudo com aquele awk no lugar do padrao (ex.: mawk, o awk do Debian/Ubuntu).
# --bash roda os scripts com outro bash (ex.: /bin/bash 3.2 do macOS). Se o awk ou o bash pedido
# nao existir, a execucao e pulada com aviso. O filtro casa o nome do caso ou do script.
# --jobs N roda os grupos em paralelo (padrao: numero de CPUs, no maximo 8); --jobs 1 e serial.
# --changed roda so os grupos afetados pelos arquivos alterados desde HEAD, mais as estaticas.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPTS="$REPO/plugins/kit/scripts"
AWK_IMPL=""
BASH_IMPL=""
JOBS=""
CHANGED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --awk) AWK_IMPL="${2:-}"; [ -n "$AWK_IMPL" ] || { echo "uso: --awk <mawk|gawk|busybox>" >&2; exit 2; }; shift 2 ;;
    --bash) BASH_IMPL="${2:-}"; [ -n "$BASH_IMPL" ] || { echo "uso: --bash <caminho>" >&2; exit 2; }; shift 2 ;;
    --jobs) JOBS="${2:-}"; case "$JOBS" in '' | *[!0-9]* | 0) echo "uso: --jobs N (N >= 1)" >&2; exit 2 ;; esac; shift 2 ;;
    --changed) CHANGED=1; shift ;;
    *) break ;;
  esac
done
FILTER="${1:-}"
if [ -z "$JOBS" ]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
  case "$JOBS" in '' | *[!0-9]* | 0) JOBS=1 ;; esac
  [ "$JOBS" -le 8 ] || JOBS=8
fi

command -v jq >/dev/null 2>&1 || { echo "jq nao encontrado" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git nao encontrado" >&2; exit 1; }

PASS=0
FAIL=0
FAILED=()
TMP_ALL="$(mktemp -d)"
trap 'rm -rf "$TMP_ALL"' EXIT

# Git dos repositorios de teste sem a config do sistema (credential helper, fsmonitor e autocrlf do
# Git for Windows) nem a do usuario: cada processo git fica mais barato e o resultado nao depende da maquina.
mkdir -p "$TMP_ALL/git-template"
cat >"$TMP_ALL/gitconfig" <<EOF
[user]
	name = kit-test
	email = kit@test
[init]
	defaultBranch = main
	templateDir = $TMP_ALL/git-template
[core]
	autocrlf = false
	fsmonitor = false
	fscache = true
[gc]
	auto = 0
EOF
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP_ALL/gitconfig"

# Troca um comando do PATH por outro executavel: shim_cmd <nome> <executavel> [argumento fixo]
shim_cmd() {
  mkdir -p "$TMP_ALL/shim-bin"
  printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$2" "${3:-}" >"$TMP_ALL/shim-bin/$1"
  chmod +x "$TMP_ALL/shim-bin/$1"
  case ":$PATH:" in *":$TMP_ALL/shim-bin:"*) ;; *) export PATH="$TMP_ALL/shim-bin:$PATH" ;; esac
}
if [ -n "$AWK_IMPL" ]; then
  AWK_BIN="$(command -v "$AWK_IMPL" 2>/dev/null)"
  [ -n "$AWK_BIN" ] || { echo "pulado: $AWK_IMPL nao instalado"; exit 0; }
  if [ "$AWK_IMPL" = "busybox" ]; then shim_cmd awk "$AWK_BIN" awk; else shim_cmd awk "$AWK_BIN"; fi
  echo "awk: $AWK_IMPL ($AWK_BIN)"
fi
if [ -n "$BASH_IMPL" ]; then
  [ -x "$BASH_IMPL" ] || { echo "pulado: $BASH_IMPL nao encontrado"; exit 0; }
  shim_cmd bash "$BASH_IMPL"
  echo "bash: $("$BASH_IMPL" -c 'echo $BASH_VERSION') ($BASH_IMPL)"
fi
# Bash que roda os scripts, resolvido uma vez (o shim do --bash, se houver): nunca o primeiro do PATH
# de cada caso, que no Windows pode ser o bash.exe do WSL em System32.
TBASH="$BASH"
[ -z "$BASH_IMPL" ] || TBASH="$TMP_ALL/shim-bin/bash"

# Caminho no formato que o Claude Code envia na plataforma atual.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

native_join() {
  local base="$1" rel="$2"
  if command -v cygpath >/dev/null 2>&1; then printf '%s\\%s' "$base" "${rel//\//\\}"; else printf '%s/%s' "$base" "$rel"; fi
}

git_q() { git -c user.name=kit-test -c user.email=kit@test -c init.defaultBranch=main -c core.autocrlf=false "$@" >/dev/null 2>&1; }

# Repositorios-modelo, criados uma vez: sample commitado e nokit (git sem kit.json). Cada caso copia.
TPL_REPOS="$TMP_ALL/modelo"
mkdir -p "$TPL_REPOS/nokit/src"
cp -r "$HERE/sample" "$TPL_REPOS/sample"
git_q init "$TPL_REPOS/sample"
git_q -C "$TPL_REPOS/sample" add -A
git_q -C "$TPL_REPOS/sample" commit -m init
printf 'x\n' >"$TPL_REPOS/nokit/notes.md"
git_q init "$TPL_REPOS/nokit"
git_q -C "$TPL_REPOS/nokit" add -A
git_q -C "$TPL_REPOS/nokit" commit -m init

# PATH sem nenhum diretorio que tenha o comando $1. Se ele estiver junto das ferramentas basicas
# (ex.: /usr/bin no Linux), o diretorio e trocado por um espelho com links para tudo menos ele.
path_without() {
  local IFS=: dir out="" shim f name="$1"
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/$name" ] || [ -e "$dir/$name.exe" ] || [ -e "$dir/$name.cmd" ]; then
      if [ -e "$dir/bash" ] || [ -e "$dir/bash.exe" ] || [ -e "$dir/dirname" ] || [ -e "$dir/dirname.exe" ]; then
        shim="$(mktemp -d "$TMP_ALL/sem-$name.XXXXXX")"
        for f in "$dir"/*; do
          case "${f##*/}" in "$name" | "$name.exe" | "$name.cmd" | "$name.ps1") continue ;; esac
          ln -s "$f" "$shim/${f##*/}" 2>/dev/null
        done
        out="${out:+$out:}$shim"
      fi
      continue
    fi
    out="${out:+$out:}$dir"
  done
  printf '%s' "$out"
}

# Caminho do comando $2 com o PATH $1; vazio e exit 1 se nao for encontrado. Subshell com "hash -r":
# no bash 3.2, "PATH=... command -v" devolve o caminho lembrado de uma chamada anterior.
found_in_path() {
  (PATH="$1"; hash -r; command -v "$2") 2>/dev/null
}

# PATH dos scripts em cada caso: um "claude" falso responde a versao pedida em fake_claude
# (padrao 9.9.9). fake_claude "ilegivel" responde sem versao; "ausente" tira o claude do PATH.
NOCLAUDE_PATH="$(path_without claude)"
case_path() {
  local ws="$1" fake="$2"
  mkdir -p "$ws/bin"
  case "$fake" in
    ausente) printf '%s' "$NOCLAUDE_PATH"; return 0 ;;
    ilegivel) printf '#!/usr/bin/env bash\necho "versao desconhecida"\n' >"$ws/bin/claude" ;;
    *) printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "${fake:-9.9.9}" >"$ws/bin/claude" ;;
  esac
  chmod +x "$ws/bin/claude"
  printf '%s' "$ws/bin:$NOCLAUDE_PATH"
}

case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*) TEST_PLATFORM=windows ;;
  Darwin) TEST_PLATFORM=macos ;;
  *) if grep -qi microsoft /proc/version 2>/dev/null; then TEST_PLATFORM=wsl; else TEST_PLATFORM=linux; fi ;;
esac

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); FAILED+=("$1: $2"); printf '  FALHA %s -- %s\n' "$1" "$2"; }

# Comandos de shell que gravam {caminho: valor} sob $root (string vira conteudo sem \r, objeto/array
# vira JSON indentado, null apaga). Uma chamada de jq por mapa; eval do resultado.
JQ_WRITE_MAP='def write_map($root):
  to_entries
  | ([.[] | select(.value != null) | .key | split("/") | .[:-1] | select(length > 0) | $root + "/" + join("/")] | unique) as $dirs
  | (if ($dirs | length) > 0 then "mkdir -p " + ($dirs | map(@sh) | join(" ")) else empty end),
    (.[] | ($root + "/" + .key | @sh) as $dest
      | if .value == null then "rm -f " + $dest
        elif (.value | type) == "string" then "printf %s " + (.value | gsub("\r"; "") | @sh) + " >" + $dest
        else "jq . <<<" + (.value | tojson | @sh) + " | tr -d '"'"'\\r'"'"' >" + $dest end);'

# Monta um workspace novo em $WS: sample (git, commitado), nokit (git sem kit.json) e nogit. A base
# do caso (sample ou mroot) fica em $CASE_BASE.
setup_ws() {
  local case_json="$1" ws kit_patch plan has_ws has_head0 n_extra files_cmds repos_cmds late_cmds
  ws="$(mktemp -d "$TMP_ALL/ws.XXXXXX")"
  cp -r "$TPL_REPOS/sample" "$ws/sample"
  cp -r "$TPL_REPOS/nokit" "$ws/nokit"
  mkdir -p "$ws/nogit"

  eval "$(jq -r --arg ws "$ws" "$JQ_WRITE_MAP"'
    (.workspace != null) as $mr
    | (if $mr then $ws + "/mroot" else $ws + "/sample" end) as $base
    | @sh "kit_patch=\(.kit // "" | if type == "string" then . else tojson end)",
      @sh "plan=\(.plan // "")",
      @sh "has_ws=\(if $mr then 1 else 0 end)",
      @sh "has_head0=\(if tostring | contains("__HEAD0__") then 1 else 0 end)",
      @sh "n_extra=\(.commits // 0)",
      @sh "files_cmds=\(if $mr then "" else [(.files // {}) | write_map($ws + "/sample")] | join("\n") end)",
      @sh "repos_cmds=\(if $mr then [(.workspace.repos // {}) | to_entries[] | .key as $r
          | "mkdir -p " + ($ws + "/mroot/" + $r | @sh),
            (.value | write_map($ws + "/mroot/" + $r)),
            "git_q init " + ($ws + "/mroot/" + $r | @sh),
            "git_q -C " + ($ws + "/mroot/" + $r | @sh) + " add -A",
            "git_q -C " + ($ws + "/mroot/" + $r | @sh) + " commit -m init"]
          + [(.files // {}) | write_map($ws + "/mroot")] | join("\n") else "" end)",
      @sh "late_cmds=\([(.change // empty | if type == "array" then .[] else . end | ($base + "/" + .) as $p
          | "mkdir -p \"$(dirname " + ($p | @sh) + ")\"; printf '"'"'// alterado\\n'"'"' >>" + ($p | @sh)),
        ((.edit // {}) | write_map($base)),
        ((.touch // {}) | to_entries[] | "touch -d \"@$(($(date +%s) - " + (.value | tostring) + " * 60))\" " + ($base + "/" + .key | @sh))]
        | join("\n"))"
  ' <<<"$case_json" | tr -d '\r')"

  local dirty=0
  if [ -n "$kit_patch" ]; then
    jq --argjson p "$kit_patch" '. * $p' "$ws/sample/.claude/kit.json" >"$ws/kit.tmp" && mv "$ws/kit.tmp" "$ws/sample/.claude/kit.json"
    dirty=1
  fi
  if [ -n "$plan" ]; then
    mkdir -p "$ws/sample/docs/specs/feat"
    printf '%b' "$plan" >"$ws/sample/docs/specs/feat/PLAN.md"
    dirty=1
  fi
  if [ -n "$files_cmds" ]; then eval "$files_cmds"; dirty=1; fi
  # O commit do modelo e refeito com o conteudo do caso: continua um unico commit inicial.
  if [ "$dirty" = "1" ]; then
    git_q -C "$ws/sample" add -A
    git_q -C "$ws/sample" commit --amend -m init
  fi
  # __HEAD0__ nos arquivos vira o hash do commit inicial; commits: N cria N commits vazios depois dele.
  if [ "$has_head0" = "1" ]; then
    local h0 f0
    h0="$(git -C "$ws/sample" rev-parse HEAD 2>/dev/null | tr -d '\r')"
    # Sem sed -i: no sed do macOS (BSD) o -i exige um argumento.
    while IFS= read -r f0; do
      [ -n "$f0" ] || continue
      sed "s/__HEAD0__/$h0/g" "$f0" >"$f0.tmp" && mv "$f0.tmp" "$f0"
    done < <(grep -rlF __HEAD0__ "$ws/sample" --exclude-dir=.git 2>/dev/null)
  fi
  local i
  for ((i = 1; i <= n_extra; i++)); do git_q -C "$ws/sample" commit --allow-empty -m "extra $i"; done
  printf 'class X {}\n' >"$ws/nokit/src/X.cs"

  # Pasta-mae sem git com repositorios filhos: workspace.repos = {nome: {caminho: conteudo}}.
  if [ "$has_ws" = "1" ]; then
    mkdir -p "$ws/mroot"
    eval "$repos_cmds"
    CASE_BASE="$ws/mroot"
  else
    CASE_BASE="$ws/sample"
  fi

  # change, edit e touch ({caminho: minutos atras}, para simular arquivos antigos).
  [ -z "$late_cmds" ] || eval "$late_cmds"
  WS="$ws"
}

resolve_token() {
  local v="$1" ws="$2" base="$3"
  case "$v" in
    __NOKIT__*) native_join "$(native_path "$ws/nokit")" "${v#__NOKIT__/}" ;;
    __NOGIT__*) native_path "$ws/nogit" ;;
    *) native_join "$(native_path "$base")" "$v" ;;
  esac
}

run_case() {
  local script="$1" case_json="$2" ws base input out err code cwd file sid
  local name skip c_cwd c_command c_tool has_raw c_raw c_file c_stop c_source c_args c_fake repeat expect exp_exit \
    c_message c_mode c_env l_stderr l_stderr_not l_stderr_order l_absent l_exists l_contains l_stdout l_stdout_not stdout_empty has_out_expect reason json_check
  # Uma chamada de jq le todos os campos do caso; listas viram linhas.
  eval "$(jq -r --arg p "$TEST_PLATFORM" '
    def lines(f): [f | if type == "array" then .[] else . end | tostring] | join("\n");
    @sh "name=\(.name)",
    @sh "skip=\(if has("platforms") and (.platforms | index($p)) == null then 1 else 0 end)",
    @sh "c_cwd=\(.cwd // "")",
    @sh "c_command=\(.command | tostring)",
    @sh "c_tool=\(.tool | tostring)",
    @sh "has_raw=\(has("raw_file"))",
    @sh "c_raw=\(.raw_file | tostring)",
    @sh "c_file=\(.file | tostring)",
    @sh "c_stop=\(.stop_hook_active // false | tojson)",
    @sh "c_source=\(.source // "startup")",
    @sh "c_args=\(lines((.args // [])[]))",
    @sh "c_fake=\(.fake_claude // "")",
    @sh "c_message=\(.message // "")",
    @sh "c_mode=\(.permission_mode // "")",
    @sh "c_env=\([(.env // {}) | to_entries[] | .key + "=" + (.value | tostring)] | join("\n"))",
    @sh "repeat=\(.repeat_empty // false)",
    @sh "expect=\(.expect // "")",
    @sh "exp_exit=\(if has("exit") then .exit else 0 end)",
    @sh "l_stderr=\(lines(.stderr // empty))",
    @sh "l_stderr_not=\(lines(.stderr_not // empty))",
    @sh "l_stderr_order=\(lines(.stderr_order // empty))",
    @sh "l_absent=\(lines((.after.absent // [])[]))",
    @sh "l_exists=\(lines((.after.exists // [])[]))",
    @sh "l_contains=\([(.after.contains // {}) | to_entries[] | .key as $k | .value | if type == "array" then .[] else . end | $k + "\t" + tostring] | join("\n"))",
    @sh "l_stdout=\(lines((.stdout // [])[]))",
    @sh "l_stdout_not=\(lines((.stdout_not // [])[]))",
    @sh "stdout_empty=\(.stdout_empty // false)",
    @sh "has_out_expect=\(has("stdout") or has("json_check"))",
    @sh "reason=\(.reason // "")",
    @sh "json_check=\(.json_check // "")"
  ' <<<"$case_json" | tr -d '\r')"
  # platforms: o caso so roda nas plataformas listadas (windows, macos, linux, wsl).
  [ "$skip" = "0" ] || return
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && [[ "$script" != *"$FILTER"* ]]; then return; fi

  setup_ws "$case_json"
  ws="$WS"
  base="$CASE_BASE"
  case "$c_cwd" in
    __NOKIT__) cwd="$(native_path "$ws/nokit")" ;;
    __NOGIT__) cwd="$(native_path "$ws/nogit")" ;;
    "") cwd="$(native_path "$base")" ;;
    *) cwd="$(native_join "$(native_path "$base")" "$c_cwd")" ;;
  esac
  sid="teste-${ws##*.}"
  mkdir -p "$ws/tmp"

  case "$script" in
    guard-bash.sh | guard-pwsh.sh)
      local gcmd="$c_command" gtool="Bash"
      [ "$script" = "guard-pwsh.sh" ] && gtool="PowerShell"
      gcmd="${gcmd//__PROJ__/$(native_path "$base")}"
      input="$(jq -cn --arg c "$gcmd" --arg d "$cwd" --arg m "$c_mode" --arg t "$gtool" \
        '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: {command: $c}, cwd: $d} + (if $m == "" then {} else {permission_mode: $m} end)')" ;;
    guard-files.sh | format.sh | advise.sh)
      # raw_file vai como esta (relativo, com .., //); file e juntado ao caminho do projeto.
      if [ "$has_raw" = "true" ]; then
        file="$c_raw"
      else
        file="$(resolve_token "$c_file" "$ws" "$base")"
      fi
      local ev="PreToolUse" fkey="file_path"; [ "$script" != "guard-files.sh" ] && ev="PostToolUse"
      [ "$c_tool" = "NotebookEdit" ] && fkey="notebook_path"
      input="$(jq -cn --arg t "$c_tool" --arg f "$file" --arg d "$cwd" --arg e "$ev" --arg s "$sid" --arg k "$fkey" \
        '{hook_event_name: $e, session_id: $s, tool_name: $t, tool_input: {($k): $f}, cwd: $d}')" ;;
    verify-gate.sh)
      input="$(jq -cn --arg d "$cwd" --arg s "$sid" --argjson a "$c_stop" \
        '{hook_event_name: "Stop", session_id: $s, stop_hook_active: $a, cwd: $d}')" ;;
    session-context.sh)
      input="$(jq -cn --arg d "$cwd" --arg s "$sid" --arg o "$c_source" \
        '{hook_event_name: "SessionStart", session_id: $s, source: $o, cwd: $d}')" ;;
    notify.sh)
      input="$(jq -cn --arg d "$cwd" --arg s "$sid" --arg m "$c_message" \
        '{hook_event_name: "Notification", session_id: $s, message: $m, title: "Claude Code", notification_type: "permission_prompt", cwd: $d}')" ;;
    pre-compact.sh)
      input="$(jq -cn --arg d "$cwd" --arg s "$sid" '{hook_event_name: "PreCompact", session_id: $s, trigger: "auto", cwd: $d}')" ;;
  esac

  local -a args=() envs=()
  while IFS= read -r s; do [ -n "$s" ] && args+=("$s"); done <<<"$c_args"
  # env: variaveis extras do caso; __BASE__ vira a pasta do caso.
  while IFS= read -r s; do [ -n "$s" ] && envs+=("${s//__BASE__/$base}"); done <<<"$c_env"

  out="$ws/stdout"
  err="$ws/stderr"
  local cpath
  cpath="$(case_path "$ws" "$c_fake")"
  (cd "$ws" && PATH="$cpath" TMPDIR="$ws/tmp" env -u CLAUDE_PROJECT_DIR -u KIT_NTFY_TOPIC -u KIT_DISCORD_WEBHOOK ${envs[@]+"${envs[@]}"} "$TBASH" "$SCRIPTS/$script" ${args[@]+"${args[@]}"} <<<"$input" >"$out" 2>"$err")
  code=$?
  if [ "$repeat" = "true" ]; then
    (cd "$ws" && PATH="$cpath" TMPDIR="$ws/tmp" env -u CLAUDE_PROJECT_DIR ${envs[@]+"${envs[@]}"} "$TBASH" "$SCRIPTS/$script" ${args[@]+"${args[@]}"} <<<"$input" >"$ws/stdout2" 2>/dev/null)
  fi

  local why=""
  [ "$code" = "$exp_exit" ] || why="exit $code, esperado $exp_exit"
  case "$expect" in
    deny)
      [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$out" 2>/dev/null)" = "deny" ] || why="${why:+$why; }esperava deny, stdout='$(head -c 200 "$out")'" ;;
    ask)
      [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$out" 2>/dev/null)" = "ask" ] || why="${why:+$why; }esperava ask, stdout='$(head -c 200 "$out")'" ;;
    allow)
      [ ! -s "$out" ] || why="${why:+$why; }esperava liberar, stdout='$(head -c 200 "$out")'" ;;
  esac
  local s pos last=0 k want
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qF -- "$s" "$err" || why="${why:+$why; }stderr sem '$s'"
  done <<<"$l_stderr"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ! grep -qF -- "$s" "$err" || why="${why:+$why; }stderr contem '$s'"
  done <<<"$l_stderr_not"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    pos="$(grep -nF -- "$s" "$err" | head -n 1 | cut -d: -f1)"
    if [ -z "$pos" ] || [ "$pos" -lt "$last" ]; then why="${why:+$why; }ordem do stderr: '$s' fora de ordem"; else last="$pos"; fi
  done <<<"$l_stderr_order"
  if [ "$script" = "verify-gate.sh" ] && [ "$code" = "2" ]; then
    [ "$(grep -c '^kit verify-gate:' "$err")" = "1" ] || why="${why:+$why; }esperava uma unica mensagem do gate"
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ ! -e "$base/$s" ] || why="${why:+$why; }deveria nao existir: $s"
  done <<<"$l_absent"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ -e "$base/$s" ] || why="${why:+$why; }deveria existir: $s"
  done <<<"$l_exists"
  while IFS=$'\t' read -r k want; do
    [ -n "$k" ] && [ -n "$want" ] || continue
    grep -qF -- "$want" "$base/$k" 2>/dev/null || why="${why:+$why; }$k sem '$want'"
  done <<<"$l_contains"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qF -- "$s" "$out" || why="${why:+$why; }stdout sem '$s'"
  done <<<"$l_stdout"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ! grep -qF -- "$s" "$out" || why="${why:+$why; }stdout contem '$s'"
  done <<<"$l_stdout_not"
  if [ "$stdout_empty" = "true" ] && [ -s "$out" ]; then
    why="${why:+$why; }stdout deveria ser vazio"
  fi
  if [ "$expect" != "deny" ] && [ "$expect" != "ask" ] && [ "$script" != "session-context.sh" ] && [ "$has_out_expect" != "true" ] && [ -s "$out" ]; then
    why="${why:+$why; }stdout deveria ser vazio"
  fi
  if [ -n "$reason" ] && ! jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$out" 2>/dev/null | grep -qF -- "$reason"; then
    why="${why:+$why; }motivo sem '$reason': $(head -c 300 "$out")"
  fi
  if [ -n "$json_check" ] && ! jq -e "$json_check" "$out" >/dev/null 2>&1; then
    why="${why:+$why; }json_check falhou ($json_check): $(head -c 300 "$out")"
  fi
  if [ "$repeat" = "true" ] && [ -s "$ws/stdout2" ]; then
    why="${why:+$why; }segunda execucao deveria ter saida vazia: $(head -c 200 "$ws/stdout2")"
  fi

  [ -n "${KIT_TEST_DEBUG:-}" ] && { echo "--- input: $input"; echo "--- stdout:"; cat "$out"; echo "--- stderr:"; cat "$err"; }
  if [ -z "$why" ]; then ok "$name"; else
    [ -s "$err" ] && why="$why; stderr='$(tail -c 300 "$err" | tr '\n' ' ')'"
    ko "$name" "$why"
  fi
}

# Casos de uma fixture, do indice $2 ao $3 (exclusivo). Cabecalho so na primeira fatia.
FX_SHARD=15
g_fixture() {
  local fx="$1" from="$2" to="$3" script c
  script="$(jq -r '.script' "$fx" | tr -d '\r')"
  [ "$from" != "0" ] || echo "$script"
  while IFS= read -r c; do
    run_case "$script" "$c"
  done < <(jq -c --argjson a "$from" --argjson b "$to" '(.defaults // {}) as $d | .cases[$a:$b][] | $d * .' "$fx" | tr -d '\r')
}

g_semjq() {
echo "sem jq no PATH"
if [ -z "$FILTER" ] || [[ "sem jq" == *"$FILTER"* ]]; then
  NOJQ_PATH="$(path_without jq)"
  BASH_BIN="$(command -v bash)"
  if found_in_path "$NOJQ_PATH" jq >/dev/null; then
    ko "PATH de teste sem jq" "jq ainda encontrado em $(found_in_path "$NOJQ_PATH" jq)"
  else
    case "$TEST_PLATFORM" in windows) JQ_INSTALL="winget install jqlang.jq" ;; macos) JQ_INSTALL="brew install jq" ;; *) JQ_INSTALL="sudo apt install jq" ;; esac
    JQ_MSG="kit: jq não encontrado — instale com $JQ_INSTALL e reabra o Claude Code"
    # Uso: nojq_guard <rotulo> <script> <json> <exit esperado>. Bloqueio: exit 2 com a mensagem; liberacao: exit 0 calado.
    nojq_guard() {
      local out code
      out="$(printf '%s' "$3" | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/$2" 2>"$TMP_ALL/nojq.err")"
      code=$?
      if [ "$4" = "2" ]; then
        if [ "$code" = "2" ] && [ -z "$out" ] && [ "$(cat "$TMP_ALL/nojq.err")" = "$JQ_MSG" ]; then ok "$1"; else ko "$1" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
      else
        if [ "$code" = "0" ] && [ -z "$out" ] && [ ! -s "$TMP_ALL/nojq.err" ]; then ok "$1"; else ko "$1" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
      fi
    }
    nojq_guard "guard-bash.sh sem jq bloqueia rm -rf / com a mensagem de instalação" guard-bash.sh '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' 2
    nojq_guard "guard-pwsh.sh sem jq bloqueia Remove-Item -Recurse C:\ com a mensagem de instalação" guard-pwsh.sh '{"tool_name":"PowerShell","tool_input":{"command":"Remove-Item -Recurse C:\\"}}' 2
    nojq_guard "guard-files.sh sem jq bloqueia Edit em .env com a mensagem de instalação" guard-files.sh '{"tool_name":"Edit","tool_input":{"file_path":".env","old_string":"a","new_string":"b"}}' 2
    nojq_guard "guard-bash.sh sem jq libera o comando exato de instalação ($JQ_INSTALL)" guard-bash.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\": \"$JQ_INSTALL\",\"description\":\"x\"}}" 0
    for c in "$JQ_INSTALL; rm -rf /" "$JQ_INSTALL && rm -rf ~" "echo $JQ_INSTALL" "$JQ_INSTALL\\\"; rm -rf /"; do
      nojq_guard "guard-bash.sh sem jq bloqueia instalação com algo junto: $c" guard-bash.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}" 2
    done
    nojq_guard "guard-bash.sh sem jq bloqueia a instalação citada só na descrição" guard-bash.sh "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\",\"description\":\"\\\"command\\\":\\\"$JQ_INSTALL\\\"\"}}" 2
    for s in format.sh verify-gate.sh advise.sh pre-compact.sh notify.sh; do
      out="$(printf '%s' '{"cwd":"."}' | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/$s" 2>"$TMP_ALL/nojq.err")"
      code=$?
      if [ "$code" = "0" ] && [ -z "$out" ] && [ ! -s "$TMP_ALL/nojq.err" ]; then
        ok "$s sem jq sai 0 sem fazer nada"
      else ko "$s sem jq sai 0 sem fazer nada" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
    done
    out="$(printf '%s' '{"cwd":"."}' | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/session-context.sh" 2>"$TMP_ALL/nojq.err")"
    code=$?
    if [ "$code" = "0" ] && jq -e --arg m "$JQ_MSG" '.systemMessage == $m and .hookSpecificOutput.hookEventName == "SessionStart"
      and (.hookSpecificOutput.additionalContext | contains($m))' <<<"$out" >/dev/null 2>&1 && [ ! -s "$TMP_ALL/nojq.err" ]; then
      ok "session-context.sh sem jq avisa em systemMessage e additionalContext com o comando de instalação"
    else ko "session-context.sh sem jq avisa em systemMessage e additionalContext com o comando de instalação" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
    out="$(printf '%s' '{"cwd":"."}' | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/session-context.sh" --plan-only 2>&1)"
    if [ "$?" = "0" ] && [ -z "$out" ]; then ok "session-context.sh --plan-only sem jq não avisa"; else ko "session-context.sh --plan-only sem jq não avisa" "stdout='$out'"; fi
  fi
  NOGIT_PATH="$(path_without git)"
  if found_in_path "$NOGIT_PATH" git >/dev/null; then
    ko "PATH de teste sem git" "git ainda encontrado em $(found_in_path "$NOGIT_PATH" git)"
  else
    ng="$(mktemp -d "$TMP_ALL/nogit.XXXXXX")"
    out="$(jq -cn --arg d "$(native_path "$ng")" '{hook_event_name: "SessionStart", source: "startup", cwd: $d}' |
      PATH="$NOGIT_PATH" "$BASH_BIN" "$SCRIPTS/session-context.sh" 2>"$TMP_ALL/nogit.err")"
    code=$?
    if [ "$code" = "0" ] && grep -qF 'kit: git não encontrado' <<<"$out" && grep -qF '/kit:setup' <<<"$out"; then
      ok "session-context.sh sem git avisa com o comando de instalação e /kit:setup"
    else ko "session-context.sh sem git avisa com o comando de instalação e /kit:setup" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nogit.err")'"; fi
  fi
fi
}

g_forma_shell() {
echo "hooks em forma shell"
if [ -z "$FILTER" ] || [[ "forma shell" == *"$FILTER"* ]]; then
  HOOKS="$REPO/plugins/kit/hooks/hooks.json"
  bad_form="$(jq -r '.hooks[][].hooks[] | select(has("args") or .shell != "bash"
    or (.command | test("^bash \"\\$\\{CLAUDE_PLUGIN_ROOT\\}/scripts/[a-z-]+\\.sh\"( --plan-only)?$") | not)) | .command' "$HOOKS" | tr -d '\r')"
  if [ -z "$bad_form" ]; then ok "hooks.json: forma shell, shell bash, sem args"; else ko "hooks.json: forma shell, shell bash, sem args" "$bad_form"; fi

  # No Windows, a forma shell roda pelo Git Bash que o Claude Code localiza, nao por busca no PATH.
  # Simula isso chamando o bash.exe do Git pelo caminho com um PATH sem nenhum bash.
  if command -v cygpath >/dev/null 2>&1; then
    GIT_BASH="$(cygpath -m /)bin/bash.exe"
    SIM_PATH="$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):$(cygpath -u "$SYSTEMROOT")/System32"
    PLUGIN_NATIVE="$(native_path "$REPO/plugins/kit")"
    SIM_CWD="$(native_path "$(mktemp -d "$TMP_ALL/shell.XXXXXX")")"
    # O System32 pode ter o bash.exe do WSL (componente antigo): bash de fora do Git nao conta.
    sim_bash="$(PATH="$SIM_PATH" command -v bash 2>/dev/null)"
    [ -z "$sim_bash" ] || sim_bash="$(cygpath -m "$sim_bash")"
    if [ ! -x "$GIT_BASH" ]; then
      ko "simulacao de PATH sem bash" "Git Bash nao encontrado em $GIT_BASH"
    elif [ -n "$sim_bash" ] && [[ "$sim_bash" == "$(cygpath -m /)"* ]]; then
      ko "simulacao de PATH sem bash" "bash do Git ainda encontrado em $sim_bash"
    else
      ok "forma exec falharia: bash do Git fora do PATH simulado"
      while IFS=$'\t' read -r ev cmd; do
        [ -n "$cmd" ] || continue
        cmd="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_NATIVE}"
        input="$(jq -cn --arg e "$ev" --arg d "$SIM_CWD" \
          '{hook_event_name: $e, session_id: "teste-shell", tool_name: "Bash", tool_input: {command: "echo oi"}, source: "startup", cwd: $d}')"
        out="$(cd "$SIM_CWD" && env PATH="$SIM_PATH" TMPDIR="$TMP_ALL" "$GIT_BASH" -c "$cmd" <<<"$input" 2>"$TMP_ALL/shell.err")"
        code=$?
        label="$ev: ${cmd##*/scripts/} roda sem bash no PATH"
        label="${label//\"/}"
        if [ "$code" = "0" ] && ! grep -q "not found" "$TMP_ALL/shell.err" && ! grep -q '"deny"' <<<"$out"; then
          ok "$label"
        else ko "$label" "exit $code, stdout='$out', stderr='$(head -c 300 "$TMP_ALL/shell.err")'"; fi
      done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[] | "\($e)\t\(.command)"' "$HOOKS" | tr -d '\r')

      # O guarda precisa decidir de fato, nao so sair 0.
      cmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$HOOKS" | tr -d '\r')"
      cmd="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_NATIVE}"
      out="$(cd "$SIM_CWD" && jq -cn --arg d "$SIM_CWD" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "git push --force origin main"}, cwd: $d}' |
        env PATH="$SIM_PATH" TMPDIR="$TMP_ALL" "$GIT_BASH" -c "$cmd" 2>"$TMP_ALL/shell.err")"
      if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null 2>&1; then
        ok "PreToolUse: guard-bash.sh nega push --force sem bash no PATH"
      else ko "PreToolUse: guard-bash.sh nega push --force sem bash no PATH" "stdout='$out', stderr='$(head -c 300 "$TMP_ALL/shell.err")'"; fi

      # bash.exe do WSL antes no PATH: o hook roda pelo bash do Git e os guardas continuam negando.
      mkdir -p "$TMP_ALL/wsl-bin"
      printf '#!/bin/sh\necho "bash do WSL chamado" >&2\nexit 1\n' >"$TMP_ALL/wsl-bin/bash"
      chmod +x "$TMP_ALL/wsl-bin/bash"
      WSL_PATH="$TMP_ALL/wsl-bin:$SIM_PATH"
      if [ "$(PATH="$WSL_PATH" command -v bash)" = "$TMP_ALL/wsl-bin/bash" ]; then
        out="$(cd "$SIM_CWD" && jq -cn --arg d "$SIM_CWD" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "rm -rf /"}, cwd: $d}' |
          env PATH="$WSL_PATH" TMPDIR="$TMP_ALL" "$GIT_BASH" -c "$cmd" 2>"$TMP_ALL/shell.err")"
        if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null 2>&1 && ! grep -q 'bash do WSL' "$TMP_ALL/shell.err"; then
          ok "PreToolUse: guard-bash.sh nega rm -rf / com o bash do WSL antes no PATH"
        else ko "PreToolUse: guard-bash.sh nega rm -rf / com o bash do WSL antes no PATH" "stdout='$out', stderr='$(head -c 300 "$TMP_ALL/shell.err")'"; fi
        fcmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher | test("Edit")) | .hooks[0].command' "$HOOKS" | tr -d '\r')"
        fcmd="${fcmd//\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_NATIVE}"
        out="$(cd "$SIM_CWD" && jq -cn --arg d "$SIM_CWD" --arg f "$SIM_CWD\.env" '{hook_event_name: "PreToolUse", tool_name: "Edit", tool_input: {file_path: $f}, cwd: $d}' |
          env PATH="$WSL_PATH" TMPDIR="$TMP_ALL" "$GIT_BASH" -c "$fcmd" 2>"$TMP_ALL/shell.err")"
        if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null 2>&1 && ! grep -q 'bash do WSL' "$TMP_ALL/shell.err"; then
          ok "PreToolUse: guard-files.sh nega Edit em .env com o bash do WSL antes no PATH"
        else ko "PreToolUse: guard-files.sh nega Edit em .env com o bash do WSL antes no PATH" "stdout='$out', stderr='$(head -c 300 "$TMP_ALL/shell.err")'"; fi
      else ko "simulacao do bash do WSL no PATH" "$(PATH="$WSL_PATH" command -v bash)"; fi
    fi
  else
    echo "  pulado simulacao de PATH sem bash (so no Windows)"
  fi
fi
}

g_apoio_init() {
echo "scripts de apoio do init"
if [ -z "$FILTER" ] || [[ "merge-json inventory" == *"$FILTER"* ]]; then
  U="$(mktemp -d "$TMP_ALL/unit.XXXXXX")"
  M="$SCRIPTS/merge-json.sh"
  printf '%s' '{"permissions":{"allow":["A","B"],"deny":["X"]},"model":"opus"}' >"$U/old.json"
  printf '%s' '{"permissions":{"allow":["B","C"],"ask":["Q"]},"model":"sonnet","enabledPlugins":{"kit@claude-kit":true}}' >"$U/new.json"
  "$TBASH" "$M" "$U/old.json" "$U/new.json" >"$U/merged.json" 2>"$U/conflicts"
  if jq -e '.permissions.allow == ["A","B","C"] and .permissions.deny == ["X"] and .permissions.ask == ["Q"] and .model == "opus" and .enabledPlugins["kit@claude-kit"] == true' "$U/merged.json" >/dev/null 2>&1; then
    ok "merge-json: chave a chave, arrays por uniao, existente vence"
  else ko "merge-json: chave a chave, arrays por uniao, existente vence" "$(tr '\n' ' ' <"$U/merged.json")"; fi
  if grep -qF 'conflito: .model mantido "opus"' "$U/conflicts"; then ok "merge-json: conflito reportado no stderr"; else ko "merge-json: conflito reportado no stderr" "$(cat "$U/conflicts")"; fi
  if "$TBASH" "$M" "$U/nao-existe.json" "$U/new.json" | jq -e '.model == "sonnet"' >/dev/null 2>&1; then ok "merge-json: existente ausente usa a proposta"; else ko "merge-json: existente ausente usa a proposta" ""; fi
  # --preview: diff e conflitos, nada gravado.
  cp "$U/old.json" "$U/pv.json"
  out="$("$TBASH" "$M" --preview "$U/pv.json" "$U/new.json" 2>&1)"
  if cmp -s "$U/old.json" "$U/pv.json" && grep -qF '+      "C"' <<<"$out" && grep -qF 'conflito: .model mantido "opus" (o kit propunha "sonnet")' <<<"$out" &&
    ! ls "$U"/pv.json.bak-kit-* >/dev/null 2>&1; then
    ok "merge-json --preview: diff e conflito, nada gravado"
  else ko "merge-json --preview: diff e conflito, nada gravado" "$out"; fi
  # --apply: backup identico ao original, so adicoes, hooks do settings intocados, conflito mantido.
  printf '%s' '{"model":"opus","permissions":{"allow":["A"],"deny":["X"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"meu.sh"}]}]},"enabledPlugins":{"kit@claude-kit":true}}' >"$U/ap.json"
  printf '%s' '{"model":"sonnet","permissions":{"allow":["B"],"ask":["Q"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"kit.sh"}]}],"PreToolUse":[]},"enabledPlugins":{"kit@claude-kit":false,"lsp@x":true}}' >"$U/ap-prop.json"
  cp "$U/ap.json" "$U/ap.orig"
  out="$("$TBASH" "$M" --apply "$U/ap.json" "$U/ap-prop.json" 2>&1)"; code=$?
  bak="$(ls "$U"/ap.json.bak-kit-* 2>/dev/null | head -n 1)"
  if [ "$code" = "0" ] && [ -n "$bak" ] && cmp -s "$U/ap.orig" "$bak" && "$TBASH" "$M" --check "$U/ap.orig" "$U/ap.json" 2>/dev/null &&
    jq -e '.permissions.allow == ["A","B"] and .permissions.ask == ["Q"] and .model == "opus" and .enabledPlugins == {"kit@claude-kit":true,"lsp@x":true}
      and .hooks == {"Stop":[{"hooks":[{"type":"command","command":"meu.sh"}]}]}' "$U/ap.json" >/dev/null 2>&1 &&
    grep -qF "gravado: $U/ap.json (backup em $bak)" <<<"$out" && grep -qF 'conflito: .model mantido' <<<"$out" && grep -qF 'conflito: .enabledPlugins."kit@claude-kit"' <<<"$out"; then
    ok "merge-json --apply: backup, só adições, hooks e valores existentes intocados"
  else ko "merge-json --apply: backup, só adições, hooks e valores existentes intocados" "exit $code, $out, $(tr -d '\n ' <"$U/ap.json")"; fi
  out="$("$TBASH" "$M" --apply "$U/ap.json" "$U/ap-prop.json" 2>&1)"
  if grep -qF 'sem mudança' <<<"$out" && [ "$(ls "$U"/ap.json.bak-kit-* | wc -l | tr -d ' ')" = "1" ]; then
    ok "merge-json --apply: nada a somar não grava nem cria backup"
  else ko "merge-json --apply: nada a somar não grava nem cria backup" "$out"; fi
  # settings.local.json, JSON invalido e arquivo ausente.
  mkdir -p "$U/loc/.claude"
  printf '{"permissions":{"allow":["Z"]}}\n' >"$U/loc/.claude/settings.local.json"
  cp "$U/loc/.claude/settings.local.json" "$U/loc.orig"
  "$TBASH" "$M" --apply "$U/loc/.claude/settings.local.json" "$U/new.json" >/dev/null 2>&1; code=$?
  if [ "$code" = "2" ] && cmp -s "$U/loc.orig" "$U/loc/.claude/settings.local.json" && ! ls "$U"/loc/.claude/*.bak-kit-* >/dev/null 2>&1; then
    ok "merge-json --apply: settings.local.json recusado e intacto"
  else ko "merge-json --apply: settings.local.json recusado e intacto" "exit $code"; fi
  printf '{"a":' >"$U/bad.json"
  "$TBASH" "$M" --apply "$U/bad.json" "$U/new.json" >/dev/null 2>&1; code=$?
  if [ "$code" = "2" ] && [ "$(cat "$U/bad.json")" = '{"a":' ]; then ok "merge-json --apply: JSON inválido não é tocado"; else ko "merge-json --apply: JSON inválido não é tocado" "exit $code"; fi
  out="$("$TBASH" "$M" --apply "$U/novo/settings.json" "$U/ap-prop.json" 2>&1)"
  if grep -qF 'criado:' <<<"$out" && jq -e '(has("hooks") | not) and .model == "sonnet"' "$U/novo/settings.json" >/dev/null 2>&1; then
    ok "merge-json --apply: arquivo ausente é criado com a proposta, sem hooks"
  else ko "merge-json --apply: arquivo ausente é criado com a proposta, sem hooks" "$out"; fi
  if "$TBASH" "$M" --check "$U/old.json" "$U/merged.json" 2>/dev/null; then ok "merge-json --check: so adicoes passa"; else ko "merge-json --check: so adicoes passa" ""; fi
  if ! "$TBASH" "$M" --check "$U/merged.json" "$U/old.json" 2>"$U/lost" && grep -qF '$.enabledPlugins: removido' "$U/lost"; then
    ok "merge-json --check: remocao falha e e listada"
  else ko "merge-json --check: remocao falha e e listada" "$(cat "$U/lost")"; fi

  cp -r "$HERE/adopt/repo" "$U/adopt"
  mv "$U/adopt/_claude" "$U/adopt/.claude"
  mv "$U/adopt/_CLAUDE.md" "$U/adopt/CLAUDE.md"
  mv "$U/adopt/_mcp.json" "$U/adopt/.mcp.json"
  git_q init "$U/adopt"
  git_q -C "$U/adopt" add -A
  git_q -C "$U/adopt" add -f .claude/settings.local.json
  git_q -C "$U/adopt" commit -m init
  "$TBASH" "$SCRIPTS/inventory.sh" "$U/adopt" >"$U/inv" 2>&1
  inv_miss=""
  for s in 'PreToolUse [Bash] command: bash "$CLAUDE_PROJECT_DIR/.claude/hooks/no-rm-rf.sh"' \
    'PostToolUse [Edit|Write]' '`.claude/hooks/manual-check.sh`' '`review`' '`manual-sync`' \
    '`i18n-checker`' 'tools: Read, Grep, Glob' '`.claude/rules/api.md` paths:' '`CLAUDE.md`' '`docs-search`: stdio node' \
    'permissions: allow 2, ask 0, deny 2'; do
    grep -qF -- "$s" "$U/inv" || inv_miss+="[$s] "
  done
  if [ -z "$inv_miss" ]; then ok "inventory: lista hooks, skills, agents, rules, CLAUDE.md e MCP"; else ko "inventory: lista hooks, skills, agents, rules, CLAUDE.md e MCP" "faltam $inv_miss"; fi

  # Riscos: cada linha esperada e o que nao pode ser marcado (hooks que usam stderr corretamente).
  risk_miss=""
  for s in '[sobreposição] skill `fix`' 'Skill(kit:fix)' 'disable-model-invocation: true e a do kit não' \
    '[efeito colateral] skill `publicar-previa`' '[falha aberta] hook PreToolUse `./.claude/hooks/block-generated.sh`' \
    '[aviso possivelmente mudo] hook PostToolUse `./.claude/hooks/lint-hint.sh`' \
    '[settings.local.json versionado]' '[sintaxe antiga] regra `Bash(rm:*)`'; do
    grep -qF -- "$s" "$U/inv" || risk_miss+="[$s] "
  done
  for s in 'manual-check.sh` (.claude/settings.json) imprime' 'no-rm-rf.sh` (.claude/settings.json) imprime' '[sem deny de segredos]' 'skill `review` (.claude'; do
    ! grep -qF -- "$s" "$U/inv" || risk_miss+="[nao deveria: $s] "
  done
  if [ -z "$risk_miss" ]; then ok "inventory: sobreposicoes, aviso mudo, falha aberta e riscos de configuracao"; else ko "inventory: sobreposicoes, aviso mudo, falha aberta e riscos de configuracao" "$risk_miss"; fi

  # curl/wget usados pelo projeto: o init deixa o deny de fora.
  out="$(HOME="$U/home" "$TBASH" "$SCRIPTS/inventory.sh" --net "$U/adopt" 2>&1)"
  if [ "$out" = ".claude/skills/status-api/SKILL.md" ] && grep -qF -- '- usados por 1 arquivos' "$U/inv" && grep -qF -- '`.claude/skills/status-api/SKILL.md`' "$U/inv"; then
    ok "inventory --net: skill da fixture de adoção que usa curl"
  else ko "inventory --net: skill da fixture de adoção que usa curl" "$out"; fi
  N="$U/net"
  mkdir -p "$N/.claude/hooks" "$N/.claude/agents" "$N/.claude/commands" "$N/pkg"
  printf '%s' '{"scripts":{"build":"tsc","ping":"curl -fsS http://localhost/health"},"description":"usa curl no texto, fora de scripts"}' >"$N/package.json"
  printf '%s' '{"scripts":{"x":"node libcurl-wrapper.js && echo curlew"}}' >"$N/pkg/package.json"
  printf 'get:\n\twget -q https://example.com/a.tgz\n' >"$N/Makefile"
  printf 'build:\n    cargo build\n' >"$N/justfile"
  printf '#!/bin/sh\nwget -qO- "$URL" >/dev/null\n' >"$N/scripts-hook.sh"
  printf '#!/bin/sh\necho ok\n' >"$N/.claude/hooks/quieto.sh"
  printf '%s\n' '---' 'name: baixa' '---' 'Rode `curl -O $URL`.' >"$N/.claude/commands/baixa.md"
  printf '%s\n' '---' 'name: leitor' '---' 'Leia os arquivos.' >"$N/.claude/agents/leitor.md"
  printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts-hook.sh\""}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"curl -s localhost:9/notify"},{"type":"command","command":"bash .claude/hooks/quieto.sh"}]}]}}' >"$N/.claude/settings.json"
  git_q init "$N"
  out="$(HOME="$U/home" "$TBASH" "$SCRIPTS/inventory.sh" --net "$N" 2>&1 | LC_ALL=C sort | paste -sd' ' -)"
  if [ "$out" = ".claude/commands/baixa.md .claude/settings.json Makefile package.json scripts-hook.sh" ]; then
    ok "inventory --net: commands, comando e script de hook, package.json scripts e Makefile; sem falso positivo"
  else ko "inventory --net: commands, comando e script de hook, package.json scripts e Makefile; sem falso positivo" "$out"; fi
  out="$(HOME="$U/home" "$TBASH" "$SCRIPTS/inventory.sh" --net "$HERE/sample" 2>&1)"
  if [ -z "$out" ]; then ok "inventory --net: projeto sem curl/wget não lista nada (o deny entra)"; else ko "inventory --net: projeto sem curl/wget não lista nada (o deny entra)" "$out"; fi

  # Regras em subpasta de .claude/rules e settings do usuario em CLAUDE_CONFIG_DIR.
  IV="$U/inv-cfg"
  mkdir -p "$IV/p/.claude/rules/sub/deep" "$IV/cfg" "$IV/home"
  printf '# a\n' >"$IV/p/.claude/rules/top.md"
  printf '# b\n' >"$IV/p/.claude/rules/sub/deep/two.md"
  printf '%s' '{"permissions":{"deny":["Read(**/.env)"],"allow":["Bash(curl *)"]}}' >"$IV/cfg/settings.json"
  git_q init "$IV/p"
  HOME="$IV/home" CLAUDE_CONFIG_DIR="$IV/cfg" "$TBASH" "$SCRIPTS/inventory.sh" "$IV/p" >"$IV/out" 2>&1
  out="$(HOME="$IV/home" CLAUDE_CONFIG_DIR="$IV/cfg" "$TBASH" "$SCRIPTS/inventory.sh" --net "$IV/p" 2>&1)"
  if grep -qF '`.claude/rules/sub/deep/two.md`' "$IV/out" && grep -qF '`.claude/rules/top.md`' "$IV/out" &&
    ! grep -qF '[sem deny de segredos]' "$IV/out" && grep -qF 'settings.json' <<<"$out"; then
    ok "inventory: regras em subpasta e settings do usuário em CLAUDE_CONFIG_DIR"
  else ko "inventory: regras em subpasta e settings do usuário em CLAUDE_CONFIG_DIR" "net='$out' $(grep -n 'rules\|deny' "$IV/out" | head -5)"; fi
  NR="$U/netrules"
  mkdir -p "$NR/.claude" "$U/home/.claude"
  printf '%s' '{"permissions":{"ask":["Bash(curl *example.com*)"]}}' >"$NR/.claude/settings.json"
  printf '%s' '{"permissions":{"allow":["Bash(wget -q *)"]}}' >"$NR/.claude/settings.local.json"
  printf '%s' '{"permissions":{"allow":["Bash(curl https://api.x/*)"]}}' >"$U/home/.claude/settings.json"
  out="$(HOME="$U/home" "$TBASH" "$SCRIPTS/inventory.sh" --net "$NR" 2>&1 | paste -sd' ' -)"
  if [ "$out" = ".claude/settings.json .claude/settings.local.json ~/.claude/settings.json" ]; then
    ok "inventory --net: regras de allow/ask com curl/wget (projeto, local e usuário) contam como uso"
  else ko "inventory --net: regras de allow/ask com curl/wget (projeto, local e usuário) contam como uso" "$out"; fi
  rm -f "$U/home/.claude/settings.json"

  # Merge aditivo nao sombreia: deny novo que cobre regra de allow/ask do arquivo nao entra.
  SH="$U/shadow"
  mkdir -p "$SH"
  printf '%s' '{"permissions":{"deny":["Bash(curl *)","Bash(wget *)"]}}' >"$SH/prop.json"
  # Uso: shadow_case <rotulo> <settings> <deny esperado (jq)> <conflitos esperados, separados por |>
  shadow_case() {
    local f="$SH/s.json" out want miss=""
    printf '%s' "$2" >"$f"
    rm -f "$f".bak-kit-*
    out="$("$TBASH" "$M" --apply "$f" "$SH/prop.json" 2>&1)"
    if [ -n "$4" ]; then
      while IFS= read -r want; do grep -qxF -- "$want" <<<"$out" || miss+="[$want] "; done <<<"$(tr '|' '\n' <<<"$4")"
    elif grep -qF 'não aplicado' <<<"$out"; then miss="conflito inesperado"; fi
    if [ -z "$miss" ] && jq -e "$3" "$f" >/dev/null 2>&1 && "$TBASH" "$M" --check "$SH/s.json".bak-kit-* "$f" 2>/dev/null; then ok "$1"
    else ko "$1" "${miss:-arquivo: $(jq -c . "$f")}; saída: $out"; fi
  }
  shadow_case "merge-json: deny Bash(curl *) não entra sobre ask Bash(curl *x.com*); wget entra" \
    '{"permissions":{"ask":["Bash(curl *x.com*)"]}}' '.permissions.deny == ["Bash(wget *)"] and .permissions.ask == ["Bash(curl *x.com*)"]' \
    'conflito: deny Bash(curl *) não aplicado — sombrearia Bash(curl *x.com*) em ask'
  shadow_case "merge-json: deny não entra sobre allow (Bash(curl:*) e Bash(wget -q *))" \
    '{"permissions":{"allow":["Bash(curl:*)","Bash(wget -q *)"]}}' '(.permissions | has("deny") | not) and (.permissions.allow | length) == 2' \
    'conflito: deny Bash(curl *) não aplicado — sombrearia Bash(curl:*) em allow|conflito: deny Bash(wget *) não aplicado — sombrearia Bash(wget -q *) em allow'
  shadow_case "merge-json: settings sem curl/wget recebe os dois deny" \
    '{"permissions":{"ask":["Bash(git push *)"],"allow":["Read"]}}' '.permissions.deny == ["Bash(curl *)","Bash(wget *)"]' ''
  shadow_case "merge-json: deny já presente não vira conflito" \
    '{"permissions":{"ask":["Bash(curl *x.com*)"],"deny":["Bash(curl *)"]}}' '.permissions.deny == ["Bash(curl *)","Bash(wget *)"]' ''
  out="$(printf '%s' '{"permissions":{"ask":["Bash(curl *x.com*)"]}}' >"$SH/s.json"; "$TBASH" "$M" --preview "$SH/s.json" "$SH/prop.json" 2>&1)"
  if grep -qxF 'conflito: deny Bash(curl *) não aplicado — sombrearia Bash(curl *x.com*) em ask' <<<"$out" && ! grep -q '^+.*Bash(curl \*)' <<<"$out" && grep -q '^+.*Bash(wget \*)' <<<"$out"; then
    ok "merge-json --preview: diff sem o deny sombreado e linha de não aplicado"
  else ko "merge-json --preview: diff sem o deny sombreado e linha de não aplicado" "$out"; fi
  printf '%s' '{"permissions":{"ask":["Bash(curl *x.com*)"],"deny":["Bash(curl *)"]}}' >"$SH/after.json"
  if ! "$TBASH" "$M" --check "$SH/s.json" "$SH/after.json" 2>"$SH/err" && grep -qF '"Bash(curl *)" sombreia "Bash(curl *x.com*)" em ask' "$SH/err"; then
    ok "merge-json --check: deny novo que sombreia ask é mudança de comportamento"
  else ko "merge-json --check: deny novo que sombreia ask é mudança de comportamento" "$(cat "$SH/err")"; fi
fi
}

g_wave_base() {
echo "wave-base"
if [ -z "$FILTER" ] || [[ "wave-base" == *"$FILTER"* ]]; then
  WB="$(mktemp -d "$TMP_ALL/wave.XXXXXX")"
  WS="$SCRIPTS/wave-base.sh"
  printf 'a\n' >"$WB/a.txt"
  printf 'ign.txt\n' >"$WB/.gitignore"
  git_q init "$WB"
  git_q -C "$WB" add -A
  git_q -C "$WB" commit -m init
  printf 'staged\n' >"$WB/s.txt"
  git_q -C "$WB" add s.txt
  base="$("$TBASH" "$WS" "$WB" 2>/dev/null)"
  printf 'b\n' >>"$WB/a.txt"
  printf 'novo\n' >"$WB/n.txt"
  printf 'x\n' >"$WB/ign.txt"
  now="$("$TBASH" "$WS" "$WB" 2>/dev/null)"
  wdiff="$(git -C "$WB" diff --name-status "$base" "$now" 2>/dev/null | tr -d '\r' | paste -sd' ' -)"
  if [ "$wdiff" = "$(printf 'M\ta.txt A\tn.txt')" ]; then ok "wave-base: diff da wave tem alterado e novo, sem ignorado nem o que já existia"; else ko "wave-base: diff da wave tem alterado e novo, sem ignorado nem o que já existia" "$wdiff"; fi
  if [ "$(git -C "$WB" diff --cached --name-only | tr -d '\r')" = "s.txt" ]; then ok "wave-base: index do usuário intacto"; else ko "wave-base: index do usuário intacto" "$(git -C "$WB" diff --cached --name-only | tr '\n' ' ')"; fi
  if [ "$(git -C "$WB" rev-list --count HEAD | tr -d '\r')" = "1" ]; then ok "wave-base: nenhum commit criado"; else ko "wave-base: nenhum commit criado" ""; fi
  if ! "$TBASH" "$WS" "$(mktemp -d "$TMP_ALL/nogit.XXXXXX")" >/dev/null 2>&1; then ok "wave-base: fora de repo git sai com erro"; else ko "wave-base: fora de repo git sai com erro" ""; fi
fi
}

g_map_partition() {
echo "map-partition"
if [ -z "$FILTER" ] || [[ "map-partition" == *"$FILTER"* ]]; then
  MP="$SCRIPTS/map-partition.sh"
  # Uso: mp_files <pasta> <caminho>... cria cada arquivo com 3 linhas.
  mp_files() {
    local d="$1" f
    shift
    for f in "$@"; do mkdir -p "$(dirname "$d/$f")"; printf 'a\nb\nc\n' >"$d/$f"; done
  }
  mp_commit() { git_q init "$1"; git_q -C "$1" add -A; git_q -C "$1" commit -m init; }

  # Repo pequeno: uma unidade cobrindo tudo.
  R="$(mktemp -d "$TMP_ALL/mp.XXXXXX")"
  mp_files "$R" README.md src/a.js src/b.js lib/c.js
  mp_commit "$R"
  out="$("$TBASH" "$MP" --root "$R" 2>"$TMP_ALL/mp.err")"
  if jq -e '.totals.units == 1 and .totals.files == 4 and .totals.loc == 12 and .units[0].paths == ["**"] and .totals.agents == 4
      and (.repos | length) == 1 and (.repos[0].commit | length) == 40 and .primary == "."' <<<"$out" >/dev/null 2>&1; then
    ok "map-partition: repo pequeno vira uma unidade com o repo inteiro"
  else ko "map-partition: repo pequeno vira uma unidade com o repo inteiro" "$(head -c 400 <<<"$out") $(cat "$TMP_ALL/mp.err")"; fi

  # Monorepo com workspaces: uma unidade por pacote, com o manifesto de cada um.
  R="$(mktemp -d "$TMP_ALL/mp.XXXXXX")"
  printf '{"workspaces":["packages/*","apps/*"]}\n' >"$R/package.json"
  mkdir -p "$R/.claude"
  printf '{"map":{"unit_max_files":5}}\n' >"$R/.claude/kit.json"
  for p in packages/core packages/ui apps/web; do
    mkdir -p "$R/$p"
    printf '{"name":"%s"}\n' "${p##*/}" >"$R/$p/package.json"
    mp_files "$R" "$p/src/one.ts" "$p/src/two.ts" "$p/src/three.ts"
  done
  mp_files "$R" tools/build.ts
  mp_commit "$R"
  out="$("$TBASH" "$MP" --root "$R" 2>"$TMP_ALL/mp.err")"
  if jq -e '
      def owner($m): [.units[] | select(.manifests | index($m))];
      (owner("packages/core/package.json") | length == 1) and (owner("packages/ui/package.json") | length == 1)
      and (owner("apps/web/package.json") | length == 1)
      and (owner("packages/core/package.json")[0].paths == ["packages/core/**"])
      and (owner("packages/ui/package.json")[0].paths == ["packages/ui/**"])
      and (owner("apps/web/package.json")[0].paths == ["apps/**"])
      and .totals.files == 14 and all(.units[]; .file_count <= 5)' <<<"$out" >/dev/null 2>&1; then
    ok "map-partition: monorepo com workspaces separa pacotes e lista manifestos"
  else ko "map-partition: monorepo com workspaces separa pacotes e lista manifestos" "$(jq -c '[.units[] | {unit, paths, manifests}]' <<<"$out" 2>&1 | head -c 600)"; fi

  # Multi-repo: pasta-mae sem git com repos no kit.json; unidades por repositorio, nome com prefixo.
  R="$(mktemp -d "$TMP_ALL/mp.XXXXXX")"
  mkdir -p "$R/.claude" "$R/app" "$R/web" "$R/fora"
  printf '{"repos":["app","web"]}\n' >"$R/.claude/kit.json"
  mp_files "$R/app" src/main.rs src/lib.rs
  mp_files "$R/web" src/home.ts
  mp_files "$R/fora" x.js
  mp_commit "$R/app"; mp_commit "$R/web"; mp_commit "$R/fora"
  out="$("$TBASH" "$MP" --root "$R" 2>"$TMP_ALL/mp.err")"
  if jq -e '([.repos[].repo] == ["app", "web"]) and .primary == "app" and ([.units[].repo] | unique) == ["app", "web"]
      and all(.units[]; .unit | test("^(app|web)-")) and .totals.files == 3
      and ([.units[] | select(.repo == "app") | .file_count] | add) == 2' <<<"$out" >/dev/null 2>&1; then
    ok "map-partition: multi-repo usa repos do kit.json, unidades por repositorio"
  else ko "map-partition: multi-repo usa repos do kit.json, unidades por repositorio" "$(head -c 500 <<<"$out") $(cat "$TMP_ALL/mp.err")"; fi

  # Unidade gigante: 400 arquivos num pacote viram unidades de no maximo 150, sem perder arquivo.
  R="$(mktemp -d "$TMP_ALL/mp.XXXXXX")"
  mkdir -p "$R/api/flat"
  printf '<Project />\n' >"$R/api/Api.csproj"
  for d in a b c; do
    mkdir -p "$R/api/src/$d"
    for i in $(seq 1 120); do printf 'x\n' >"$R/api/src/$d/f$i.cs"; done
  done
  for i in $(seq 1 40); do printf 'x\n' >"$R/api/flat/g$i.cs"; done
  mp_commit "$R"
  out="$("$TBASH" "$MP" --root "$R" 2>"$TMP_ALL/mp.err")"
  if jq -e '.totals.files == 401 and .totals.units >= 3 and all(.units[]; .file_count <= 150)
      and ([.units[].paths[]] | length) == ([.units[].paths[]] | unique | length)
      and all(.units[]; .manifests == ["api/Api.csproj"])' <<<"$out" >/dev/null 2>&1; then
    ok "map-partition: unidade gigante é subdividida até o limite sem perder arquivo"
  else ko "map-partition: unidade gigante é subdividida até o limite sem perder arquivo" "$(jq -c '[.units[] | {unit, file_count, paths}]' <<<"$out" 2>&1 | head -c 600)"; fi
  # Pasta so com arquivos diretos: fatias.
  R2="$(mktemp -d "$TMP_ALL/mp.XXXXXX")"
  mkdir -p "$R2/big"
  for i in $(seq 1 320); do printf 'x\n' >"$R2/big/f$i.py"; done
  mp_commit "$R2"
  out="$("$TBASH" "$MP" --root "$R2" 2>"$TMP_ALL/mp.err")"
  if jq -e '.totals.files == 320 and .totals.units == 3 and all(.units[]; .file_count <= 150) and ([.units[].unit] == ["big-1", "big-2", "big-3"])' <<<"$out" >/dev/null 2>&1; then
    ok "map-partition: pasta só com arquivos diretos é fatiada"
  else ko "map-partition: pasta só com arquivos diretos é fatiada" "$(jq -c '[.units[] | {unit, file_count}]' <<<"$out" 2>&1 | head -c 400)"; fi

  # Protegidos, segredos, vendor, build, gerados, lockfiles e binarios ficam de fora; source_globs vale.
  R="$(mktemp -d "$TMP_ALL/mp.XXXXXX")"
  mkdir -p "$R/.claude"
  printf '{"source_globs":["**/*.cs","**/*.ts"],"protected_paths":["**/Migrations/**",{"glob":"gen/**","message":"gerado"}]}\n' >"$R/.claude/kit.json"
  mp_files "$R" src/App.cs web/app.ts src/Migrations/001_Init.cs gen/Client.cs vendor/lib/x.ts dist/out.ts build/b.ts \
    secrets/token.cs keys/k.cs .env.local.ts src/Form.Designer.cs src/api.generated.ts docs/readme.md notes.txt src/app.min.js
  printf '\000\001binario\n' >"$R/src/blob.cs"
  printf 'lock\n' >"$R/yarn.lock"
  printf '{}\n' >"$R/package-lock.json"
  mp_commit "$R"
  out="$("$TBASH" "$MP" --root "$R" 2>"$TMP_ALL/mp.err")"
  if jq -e '.totals.files == 2' <<<"$out" >/dev/null 2>&1 && ! grep -qE 'Migrations|gen/|vendor|dist|build/|secrets|keys|\.env|Designer|generated|readme|notes|min\.js|blob|lock' <<<"$(jq -c '.units' <<<"$out")"; then
    ok "map-partition: protegidos, segredos, gerados, lockfiles, binários e fora de source_globs ignorados"
  else ko "map-partition: protegidos, segredos, gerados, lockfiles, binários e fora de source_globs ignorados" "$(jq -c '[.units[] | {paths, file_count}]' <<<"$out" 2>&1 | head -c 500)"; fi

  # --since marca so a unidade alterada; --path limita a area.
  R="$(mktemp -d "$TMP_ALL/mp.XXXXXX")"
  mkdir -p "$R/.claude"
  printf '{"map":{"unit_max_files":3}}\n' >"$R/.claude/kit.json"
  mp_files "$R" a/1.js a/2.js a/3.js b/1.js b/2.js b/3.js
  mp_commit "$R"
  c0="$(git -C "$R" rev-parse HEAD | tr -d '\r')"
  printf 'novo\n' >>"$R/b/2.js"
  out="$("$TBASH" "$MP" --root "$R" --since "$c0" 2>"$TMP_ALL/mp.err")"
  if jq -e '.totals.changed == 1 and ([.units[] | select(.changed) | .paths[]] == ["b/**"]) and ([.units[] | select(.changed) | .changed_files] == [1])' <<<"$out" >/dev/null 2>&1; then
    ok "map-partition: --since marca só a unidade com arquivo alterado"
  else ko "map-partition: --since marca só a unidade com arquivo alterado" "$(jq -c '[.units[] | {paths, changed}]' <<<"$out" 2>&1 | head -c 400)"; fi
  out="$("$TBASH" "$MP" --root "$R" --path a 2>"$TMP_ALL/mp.err")"
  if jq -e '.totals.files == 3 and ([.units[].paths[]] == ["a/**"])' <<<"$out" >/dev/null 2>&1; then
    ok "map-partition: --path limita a uma área"
  else ko "map-partition: --path limita a uma área" "$(jq -c '.units' <<<"$out" 2>&1 | head -c 400)"; fi
  # --status: ausente, em dia e desatualizado (limite do kit.json).
  st1="$("$TBASH" "$MP" --root "$R" --status 2>&1)"; c1=$?
  mkdir -p "$R/docs"
  printf '<!-- kit:map v1 · 2026-10-14 · %s -->\n# Mapa\n' "$c0" >"$R/docs/codemap.md"
  st2="$("$TBASH" "$MP" --root "$R" --status 2>&1)"; c2=$?
  printf '{"map":{"unit_max_files":3,"stale_after_commits":1}}\n' >"$R/.claude/kit.json"
  git_q -C "$R" commit --allow-empty -m a; git_q -C "$R" commit --allow-empty -m b
  st3="$("$TBASH" "$MP" --root "$R" --status 2>&1)"; c3=$?
  if [ "$c1:$st1" = "1:codemap: ausente" ] && [ "$c2:$st2" = "0:codemap: em dia" ] && [ "$c3" = "1" ] && grep -qF '2 commits atrás (limite 1); rode /kit:map --update' <<<"$st3"; then
    ok "map-partition --status: ausente, em dia e desatualizado"
  else ko "map-partition --status: ausente, em dia e desatualizado" "$c1:$st1 | $c2:$st2 | $c3:$st3"; fi
  if ! "$TBASH" "$MP" --root "$(mktemp -d "$TMP_ALL/nogit.XXXXXX")" >/dev/null 2>&1; then ok "map-partition: sem repositório git sai com erro"; else ko "map-partition: sem repositório git sai com erro" ""; fi
  mp_bad=""
  for opt in --root --path --since; do
    timeout 10 "$TBASH" "$MP" "$opt" >/dev/null 2>"$TMP_ALL/mp-opt.err"; code=$?
    { [ "$code" = "2" ] && grep -qF "map-partition: $opt precisa de um valor" "$TMP_ALL/mp-opt.err"; } || mp_bad+="$opt=$code "
  done
  [ -z "$mp_bad" ] && ok "map-partition: opção sem valor sai com erro, sem travar" || ko "map-partition: opção sem valor sai com erro, sem travar" "$mp_bad"
fi
}

g_setup() {
echo "setup"
if [ -z "$FILTER" ] || [[ "setup" == *"$FILTER"* ]]; then
  SU="$SCRIPTS/setup.sh"
  # Stubs de plataforma e versao: uname responde $1, claude responde $2. WSL via WSL_DISTRO_NAME.
  # bwrap e socat existem, salvo com $3 = "sem-sandbox". AppArmor sem restricao, salvo nos casos dele.
  setup_bin() {
    local d
    d="$(mktemp -d "$TMP_ALL/setup-bin.XXXXXX")"
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" >"$d/uname"
    printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "${2:-9.9.9}" >"$d/claude"
    chmod +x "$d/uname" "$d/claude"
    if [ "${3:-}" != "sem-sandbox" ]; then
      printf '#!/usr/bin/env bash\nexit 0\n' >"$d/bwrap"
      printf '#!/usr/bin/env bash\nexit 0\n' >"$d/socat"
      chmod +x "$d/bwrap" "$d/socat"
    fi
    printf '%s' "$d"
  }
  printf '0\n' >"$TMP_ALL/userns-0"
  printf '1\n' >"$TMP_ALL/userns-1"
  export KIT_USERNS_SYSCTL="$TMP_ALL/userns-0"
  NOSB_PATH="$(PATH="$(path_without bwrap)" path_without socat)"
  LINUX_BIN="$(setup_bin Linux)"
  WIN_BIN="$(setup_bin MINGW64_NT-10.0-26100)"
  MAC_BIN="$(setup_bin Darwin)"
  # Uso: run_setup <config> <PATH> <subcomando...>. Sem WSL_DISTRO_NAME herdado.
  run_setup() {
    local cfg="$1" path="$2"
    shift 2
    env -u WSL_DISTRO_NAME CLAUDE_CONFIG_DIR="$cfg" PATH="$path" "$TBASH" "$SU" "$@"
  }
  NOJQ_PATH="${NOJQ_PATH:-$(path_without jq)}"

  # Settings do usuario nunca e alterado: setup e scripts de apoio do init, com CLAUDE_CONFIG_DIR
  # apontando para uma fixture e com o padrao ~/.claude (HOME falso).
  user_hash() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum <"$f")"; done); }
  UH="$(mktemp -d "$TMP_ALL/home.XXXXXX")"
  C1="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  mkdir -p "$UH/.claude/plugins" "$C1/plugins"
  for d in "$UH/.claude" "$C1"; do
    printf '%s\n' '{"model":"opus","permissions":{"allow":["Bash(curl *)"]},"enabledPlugins":{"kit@claude-kit":true}}' >"$d/settings.json"
    printf '{"claude-kit":{}}\n' >"$d/plugins/known_marketplaces.json"
  done
  PR0="$(mktemp -d "$TMP_ALL/proj.XXXXXX")"
  git_q init "$PR0"
  mkdir -p "$PR0/.claude"
  printf '%s\n' '{"commands":{"test":"true"},"permissions":{"groups":["segredos","push"]},"guards":{"allow_write":["**"]}}' >"$PR0/.claude/kit.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(npm run *)"]}}' >"$PR0/.claude/settings.json"
  hu0="$(user_hash "$UH")"
  hc0="$(user_hash "$C1")"
  for cfg in "$C1" ""; do
    for sub in check status groups "permissions segredos,git-destrutivo,push,curl-wget,sandbox $PR0/prop.json" "permissions --kit $PR0/.claude/kit.json $PR0/prop.json" "guards $PR0/.claude/kit.json" "lsp $PR0" "plans $PR0"; do
      # shellcheck disable=SC2086
      (cd "$PR0" && env -u WSL_DISTRO_NAME -u CLAUDE_CONFIG_DIR HOME="$UH" ${cfg:+CLAUDE_CONFIG_DIR="$cfg"} PATH="$LINUX_BIN:$NOCLAUDE_PATH" "$TBASH" "$SU" $sub) >/dev/null 2>&1
    done
    (cd "$PR0" && env -u CLAUDE_CONFIG_DIR HOME="$UH" ${cfg:+CLAUDE_CONFIG_DIR="$cfg"} "$TBASH" "$SCRIPTS/merge-json.sh" --apply .claude/settings.json prop.json) >/dev/null 2>&1
    (cd "$PR0" && env -u CLAUDE_CONFIG_DIR HOME="$UH" ${cfg:+CLAUDE_CONFIG_DIR="$cfg"} "$TBASH" "$SCRIPTS/inventory.sh") >/dev/null 2>&1
    (cd "$PR0" && env -u CLAUDE_CONFIG_DIR HOME="$UH" ${cfg:+CLAUDE_CONFIG_DIR="$cfg"} "$TBASH" "$SCRIPTS/inventory.sh" --net) >/dev/null 2>&1
  done
  if [ "$hu0" = "$(user_hash "$UH")" ] && [ "$hc0" = "$(user_hash "$C1")" ] && jq -e '.permissions.deny | index("Read(**/.env)") != null' "$PR0/.claude/settings.json" >/dev/null 2>&1; then
    ok "setup e scripts do init não alteram o settings de usuário (CLAUDE_CONFIG_DIR e ~/.claude)"
  else ko "setup e scripts do init não alteram o settings de usuário (CLAUDE_CONFIG_DIR e ~/.claude)" "$(user_hash "$C1") | $(user_hash "$UH")"; fi

  # status: so dependencias e marketplace, nada de settings.
  out="$(run_setup "$C1" "$LINUX_BIN:$NOCLAUDE_PATH" status 2>&1)"
  code=$?
  if [ "$code" = "0" ] && grep -qF 'ok marketplace claude-kit' <<<"$out" && ! grep -qi 'settings' <<<"$out"; then
    ok "setup status: confere dependências e marketplace, sem settings de usuário"
  else ko "setup status: confere dependências e marketplace, sem settings de usuário" "exit $code, $out"; fi
  CS="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" status 2>&1)"
  code=$?
  if [ "$code" = "0" ] && grep -qF 'aviso marketplace' <<<"$out" && [ -z "$(ls -A "$CS")" ]; then
    ok "setup status: sem settings de usuário está pronto e não cria nada"
  else ko "setup status: sem settings de usuário está pronto e não cria nada" "exit $code, $out"; fi
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" propose todos 2>&1)"
  code=$?
  if [ "$code" = "2" ] && [ -z "$(ls -A "$CS")" ]; then ok "setup: propose e apply do settings de usuário não existem mais"; else ko "setup: propose e apply do settings de usuário não existem mais" "exit $code, $out"; fi

  # groups: PowerShell so no Windows nativo, sandbox so onde existe.
  NOSB_BIN="$(setup_bin Linux 9.9.9 sem-sandbox)"
  g_lin="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" groups 2>&1 | cut -f1 | tr '\n' ' ')"
  g_win="$(run_setup "$CS" "$WIN_BIN:$NOCLAUDE_PATH" groups 2>&1 | cut -f1 | tr '\n' ' ')"
  g_mac="$(run_setup "$CS" "$MAC_BIN:$NOCLAUDE_PATH" groups 2>&1 | cut -f1 | tr '\n' ' ')"
  g_wsl="$(WSL_DISTRO_NAME=Ubuntu CLAUDE_CONFIG_DIR="$CS" PATH="$LINUX_BIN:$NOCLAUDE_PATH" "$TBASH" "$SU" groups 2>&1 | cut -f1 | tr '\n' ' ')"
  g_nosb="$(run_setup "$CS" "$NOSB_BIN:$(PATH="$NOSB_PATH" path_without claude)" groups 2>&1 | cut -f1 | tr '\n' ' ')"
  if [ "$g_lin" = "segredos git-destrutivo push curl-wget sandbox " ] && [ "$g_win" = "segredos git-destrutivo push curl-wget powershell " ] &&
    [ "$g_mac" = "$g_lin" ] && [ "$g_wsl" = "$g_lin" ] && [ "$g_nosb" = "segredos git-destrutivo push curl-wget " ]; then
    ok "setup groups: PowerShell só no Windows nativo, sandbox só no macOS e no Linux/WSL2 com bwrap e socat"
  else ko "setup groups: PowerShell só no Windows nativo, sandbox só no macOS e no Linux/WSL2 com bwrap e socat" "linux=$g_lin win=$g_win mac=$g_mac wsl=$g_wsl nosb=$g_nosb"; fi
  if run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" groups 2>&1 | grep -q $'^segredos\tSegredos — Nega Read'; then
    ok "setup groups: cada grupo com rótulo e uma linha do que faz"
  else ko "setup groups: cada grupo com rótulo e uma linha do que faz" "$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" groups 2>&1 | head -n 2)"; fi

  # permissions: so os grupos marcados entram na proposta.
  PP="$(mktemp -d "$TMP_ALL/perm.XXXXXX")"
  printf '%s\n' '{"permissions":{"allow":["Bash(npm run *)"]}}' >"$PP/p.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions segredos,push "$PP/p.json" 2>&1)"
  code=$?
  if [ "$code" = "0" ] && jq -e '(.permissions.deny | index("Read(**/.env)") != null) and (.permissions.deny | index("Bash(git reset --hard *)") == null)
      and (.permissions.deny | index("Bash(curl *)") == null) and .permissions.ask == ["Bash(git push *)"] and (has("sandbox") | not)
      and .permissions.allow == ["Bash(npm run *)"]' "$PP/p.json" >/dev/null 2>&1 && grep -qF 'grupos: segredos,push' <<<"$out"; then
    ok "setup permissions: só os grupos marcados entram, proposta existente mantida"
  else ko "setup permissions: só os grupos marcados entram, proposta existente mantida" "exit $code, $out, $(jq -c . "$PP/p.json")"; fi
  cp "$PP/p.json" "$PP/p.before"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions - "$PP/p.json" 2>&1)"
  if jq -e --slurpfile b "$PP/p.before" '. == $b[0]' "$PP/p.json" >/dev/null 2>&1 && grep -qF 'grupos: nenhum' <<<"$out"; then
    ok "setup permissions: nenhum grupo marcado não acrescenta nada"
  else ko "setup permissions: nenhum grupo marcado não acrescenta nada" "$out"; fi
  out="$(run_setup "$CS" "$WIN_BIN:$NOCLAUDE_PATH" permissions sandbox,powershell "$PP/w.json" 2>&1)"
  if jq -e '(has("sandbox") | not) and .permissions.deny == ["PowerShell"]' "$PP/w.json" >/dev/null 2>&1 && grep -qF 'fora: sandbox' <<<"$out"; then
    ok "setup permissions: grupo fora da plataforma não entra e vira linha fora:"
  else ko "setup permissions: grupo fora da plataforma não entra e vira linha fora:" "$out, $(cat "$PP/w.json" 2>&1)"; fi
  run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions sandbox "$PP/s.json" >/dev/null 2>&1
  if jq -e '.sandbox.enabled == true and .sandbox.failIfUnavailable == true and (.permissions.ask | index("Bash(dangerouslyDisableSandbox:true)") != null)' "$PP/s.json" >/dev/null 2>&1; then
    ok "setup permissions: grupo sandbox liga o sandbox com failIfUnavailable e o ask de rodar fora"
  else ko "setup permissions: grupo sandbox liga o sandbox com failIfUnavailable e o ask de rodar fora" "$(cat "$PP/s.json" 2>&1)"; fi
  printf '%s\n' '{"permissions":{"ask":["Bash(curl https://api.x.com *)"]}}' >"$PP/c.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions curl-wget "$PP/c.json" 2>&1)"
  if jq -e '.permissions.deny == ["Bash(wget *)"]' "$PP/c.json" >/dev/null 2>&1 &&
    grep -qF 'conflito: deny Bash(curl *) não aplicado — sombrearia Bash(curl https://api.x.com *) em ask' <<<"$out"; then
    ok "setup permissions: deny de curl que sombrearia ask da proposta não entra"
  else ko "setup permissions: deny de curl que sombrearia ask da proposta não entra" "$out, $(jq -c . "$PP/c.json")"; fi
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions segredos,nada "$PP/x.json" 2>&1)"
  code=$?
  if [ "$code" = "2" ] && [ ! -e "$PP/x.json" ] && grep -qF 'grupo desconhecido: nada' <<<"$out"; then
    ok "setup permissions: grupo desconhecido recusa e não grava"
  else ko "setup permissions: grupo desconhecido recusa e não grava" "exit $code, $out"; fi

  # Reparo: permissions.groups do kit.json manda; grupo desmarcado antes nao volta.
  printf '%s\n' '{"permissions":{"groups":["git-destrutivo"]}}' >"$PP/kit.json"
  run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions --kit "$PP/kit.json" "$PP/r.json" >/dev/null 2>&1
  code=$?
  if [ "$code" = "0" ] && jq -e '.permissions.deny == ["Bash(git push --force *)","Bash(git push -f *)","Bash(git reset --hard *)","Bash(git clean -fdx *)"]
      and (.permissions | has("ask") | not) and (has("sandbox") | not)' "$PP/r.json" >/dev/null 2>&1; then
    ok "setup permissions --kit: reparo propõe só os grupos de permissions.groups"
  else ko "setup permissions --kit: reparo propõe só os grupos de permissions.groups" "exit $code, $(cat "$PP/r.json" 2>&1)"; fi
  printf '%s\n' '{"permissions":{"groups":[]}}' >"$PP/kit0.json"
  run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions --kit "$PP/kit0.json" "$PP/r0.json" >/dev/null 2>&1
  code=$?
  if [ "$code" = "0" ] && jq -e '. == {}' "$PP/r0.json" >/dev/null 2>&1; then
    ok "setup permissions --kit: todos desmarcados antes, nada volta"
  else ko "setup permissions --kit: todos desmarcados antes, nada volta" "exit $code, $(cat "$PP/r0.json" 2>&1)"; fi
  printf '%s\n' '{"commands":{}}' >"$PP/kit1.json"
  run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" permissions --kit "$PP/kit1.json" "$PP/r1.json" >/dev/null 2>&1
  code=$?
  if [ "$code" = "3" ] && [ ! -e "$PP/r1.json" ]; then ok "setup permissions --kit: sem permissions.groups sai com 3 e não grava"; else ko "setup permissions --kit: sem permissions.groups sai com 3 e não grava" "exit $code"; fi

  # guards: glob largo e segredo em allow_write ignorados; item sem glob e grupo desconhecido invalidos.
  printf '%s\n' '{"guards":{"allow_write":["**","*","**/*",".env*","*.env","web/gen/strings.ts",".env","config/.env.test","certs/a.pem","secrets/x.yml","keys/k",".env.test.example"],"deny_write":["vendor/**",{"glob":"docs/legal/**","message":"x"},{"message":"sem glob"}]},"permissions":{"groups":["segredos","nada"]}}' >"$PP/g.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/g.json" 2>&1)"
  code=$?
  g_bad=""
  for gl in '**' '*' '**/*' '.env*' '*.env'; do grep -qxF "ignorado: guards.allow_write \"$gl\" — glob largo demais; liste o caminho exato" <<<"$out" || g_bad+="$gl "; done
  for gl in '.env' 'config/.env.test' 'certs/a.pem' 'secrets/x.yml' 'keys/k'; do grep -qxF "ignorado: guards.allow_write \"$gl\" — segredo não tem exceção" <<<"$out" || g_bad+="$gl "; done
  if [ "$code" = "1" ] && [ -z "$g_bad" ] && ! grep -qF 'web/gen/strings.ts' <<<"$out" && ! grep -qF '.env.test.example' <<<"$out" &&
    grep -qxF 'inválido: guards.deny_write[2] sem glob' <<<"$out" && grep -qxF 'inválido: permissions.groups "nada" desconhecido' <<<"$out"; then
    ok "setup guards: glob largo e segredo ignorados, caminho exato e exemplo aceitos, item sem glob e grupo desconhecido"
  else ko "setup guards: glob largo e segredo ignorados, caminho exato e exemplo aceitos, item sem glob e grupo desconhecido" "exit $code, faltou: $g_bad, $out"; fi
  printf '%s\n' '{"guards":{"allow_write":["web/gen/strings.ts"],"deny_write":["vendor/**"]},"permissions":{"groups":["segredos"]}}' >"$PP/g2.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/g2.json" 2>&1)"
  code=$?
  if [ "$code" = "0" ] && [ "$out" = "ok guards" ]; then ok "setup guards: kit.json válido dá ok guards"; else ko "setup guards: kit.json válido dá ok guards" "exit $code, $out"; fi
  mkdir -p "$PP/tipos/.claude" "$PP/tipos/api/.git"
  printf '%s\n' '{"protected_paths":"gen/**","commands":{"test":"true"},"verify_on_stop":["tset"],"repos":["api","nope"]}' >"$PP/tipos/.claude/kit.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/tipos/.claude/kit.json" 2>&1)"
  code=$?
  if [ "$code" = "1" ] && grep -qxF 'inválido: protected_paths precisa ser lista' <<<"$out" &&
    grep -qF 'inválido: verify_on_stop "tset" não existe em commands' <<<"$out" &&
    grep -qxF 'inválido: verify_on_stop sem source_globs; o gate não roda nenhum comando' <<<"$out" &&
    grep -qF 'inválido: repos "nope" não é repositório git' <<<"$out" && ! grep -qF '"api"' <<<"$out"; then
    ok "setup guards: tipo errado, verify_on_stop sem comando ou sem source_globs e repos sem git"
  else ko "setup guards: tipo errado, verify_on_stop sem comando ou sem source_globs e repos sem git" "exit $code, $out"; fi
  printf '%s\n' '{"commands":{"build":"true","lint":{"run":"x {files}","files":["**/*.ts"]},"bad1":5,"bad2":{"files":["a"]},"bad3":{"run":"x","files":"a"}},"verify_on_stop":["lint"],
    "diff_deny":[{"pattern":"ok"},{"files":["x"]},{"pattern":"(","level":"x"},{"pattern":"y","files":"z"}]}' >"$PP/cmdobj.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/cmdobj.json" 2>&1)"
  code=$?
  if [ "$code" = "1" ] && grep -qxF 'inválido: commands.bad1 precisa ser texto ou objeto com "run"' <<<"$out" &&
    grep -qxF 'inválido: commands.bad2 precisa ser texto ou objeto com "run"' <<<"$out" &&
    grep -qxF 'inválido: commands.bad3.files precisa ser lista de globs' <<<"$out" &&
    grep -qxF 'inválido: diff_deny[1] sem pattern' <<<"$out" && grep -qxF 'inválido: diff_deny[2].level precisa ser block ou warn' <<<"$out" &&
    grep -qxF 'inválido: diff_deny[3].files precisa ser lista de globs' <<<"$out" &&
    grep -qxF 'inválido: diff_deny[2].pattern não é ERE válido: (' <<<"$out" &&
    ! grep -qE 'commands\.(build|lint)|diff_deny\[0\]|source_globs' <<<"$out"; then
    ok "setup guards: commands na forma objeto e regras de diff_deny"
  else ko "setup guards: commands na forma objeto e regras de diff_deny" "exit $code, $out"; fi
  printf '%s\n' '{"commands":{"build":"true","lint":{"run":"x {files}","files":["**/*.ts"]}},"verify_on_stop":["build","lint"]}' >"$PP/misto.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/misto.json" 2>&1)"
  code=$?
  if [ "$code" = "1" ] && [ "$out" = 'inválido: verify_on_stop sem source_globs; o gate não roda os comandos sem "files": build' ]; then
    ok "setup guards: sem source_globs, só os comandos sem files ficam de fora"
  else ko "setup guards: sem source_globs, só os comandos sem files ficam de fora" "exit $code, $out"; fi
  printf '%s\n' '{"ui":{"globs":["src/**/*.tsx"],"dev":"x","url":"http://localhost:3000","routes":["/"],"viewports":["360x800"]}}' >"$PP/ui-ok.json"
  printf '%s\n' '{"ui":false}' >"$PP/ui-nao.json"
  o1="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/ui-ok.json" 2>&1)"
  o2="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/ui-nao.json" 2>&1)"
  printf '%s\n' '{"ui":{"globs":"x","dev":5,"url":"localhost:3000","viewports":["360","1280x800"],"screenshot":"tira foto"}}' >"$PP/ui-ruim.json"
  out="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/ui-ruim.json" 2>&1)"; code=$?
  printf '%s\n' '{"ui":{"dev":"sobe"}}' >"$PP/ui-ruim2.json"
  o3="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/ui-ruim2.json" 2>&1)"
  printf '%s\n' '{"ui":"sim"}' >"$PP/ui-ruim3.json"
  o4="$(run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/ui-ruim3.json" 2>&1)"
  if [ "$o1" = "ok guards" ] && [ "$o2" = "ok guards" ] && [ "$code" = "1" ] && [ "$(grep -c . <<<"$out")" = "5" ] &&
    grep -qxF 'inválido: ui.globs precisa ser lista de textos' <<<"$out" && grep -qxF 'inválido: ui.dev precisa ser texto' <<<"$out" &&
    grep -qxF 'inválido: ui.viewports "360" precisa ser <largura>x<altura>, como 360x800' <<<"$out" &&
    grep -qxF 'inválido: ui.url precisa começar com http:// ou https://' <<<"$out" &&
    grep -qxF 'inválido: ui.screenshot sem {out}; o comando precisa gravar a imagem nesse caminho' <<<"$out" &&
    grep -qxF 'inválido: ui sem globs; nenhum arquivo conta como interface' <<<"$o3" &&
    grep -qxF 'inválido: ui.dev sem ui.url; a captura não sabe que endereço abrir' <<<"$o3" &&
    [ "$o4" = "inválido: ui precisa ser objeto ou false" ]; then
    ok "setup guards: ui válido e false passam; tipo errado, viewport, url, dev sem url, screenshot sem {out} e ui sem globs"
  else ko "setup guards: ui válido e false passam; tipo errado, viewport, url, dev sem url, screenshot sem {out} e ui sem globs" "1='$o1' 2='$o2' exit $code: $out | $o3 | $o4"; fi
  printf '%s\n' '{"protected_paths":["gen/**"],}' >"$PP/invalido.json"
  run_setup "$CS" "$LINUX_BIN:$NOCLAUDE_PATH" guards "$PP/invalido.json" >/dev/null 2>&1
  code=$?
  [ "$code" = "2" ] && ok "setup guards: kit.json inválido sai com 2" || ko "setup guards: kit.json inválido sai com 2" "exit $code"

  # Windows nativo simulado: check avisa que nao ha sandbox.
  C3="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  out="$(run_setup "$C3" "$WIN_BIN:$NOCLAUDE_PATH" check 2>&1)"
  code=$?
  if [ "$code" = "0" ] && grep -qF 'plataforma: windows nativo — sem sandbox' <<<"$out"; then
    ok "setup check: Windows nativo simulado avisa que não há sandbox"
  else ko "setup check: Windows nativo simulado avisa que não há sandbox" "exit $code, $out"; fi
  CPS="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  ps1="$(cd "$CPS" && run_setup "$CPS" "$WIN_BIN:$NOCLAUDE_PATH" check 2>&1)"
  printf '%s\n' '{"permissions":{"deny":["PowerShell"]}}' >"$CPS/settings.json"
  ps2="$(cd "$CPS" && run_setup "$CPS" "$WIN_BIN:$NOCLAUDE_PATH" check 2>&1)"
  ps3="$(cd "$CPS" && run_setup "$CPS" "$LINUX_BIN:$NOCLAUDE_PATH" check 2>&1)"
  rm -f "$CPS/settings.json"
  ps4="$(cd "$CPS" && run_setup "$CPS" "$LINUX_BIN:$NOCLAUDE_PATH" check 2>&1)"
  if grep -qF 'aviso powershell:' <<<"$ps1" && ! grep -qF 'aviso powershell' <<<"$ps2$ps3$ps4"; then
    ok "setup check: Windows sem deny de PowerShell avisa; com deny ou fora do Windows, não"
  else ko "setup check: Windows sem deny de PowerShell avisa; com deny ou fora do Windows, não" "1=$ps1 2=$ps2"; fi
  C4="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  out="$(WSL_DISTRO_NAME=Ubuntu CLAUDE_CONFIG_DIR="$C4" PATH="$LINUX_BIN:$NOCLAUDE_PATH" "$TBASH" "$SU" check 2>&1)"
  if grep -qF 'plataforma: wsl2 — sandbox disponível' <<<"$out"; then
    ok "setup check: WSL2 simulado com bwrap e socat tem sandbox"
  else ko "setup check: WSL2 simulado com bwrap e socat tem sandbox" "$out"; fi

  # jq ausente simulado: check falha com o comando de instalacao da plataforma; permissions recusa.
  out="$(run_setup "$C4" "$WIN_BIN:$NOJQ_PATH" check 2>&1)"
  code=$?
  if [ "$code" = "1" ] && grep -qF 'falta jq — instale: winget install jqlang.jq' <<<"$out" && grep -qF 'ok git' <<<"$out"; then
    ok "setup check: jq ausente (Windows) falha com winget install jqlang.jq"
  else ko "setup check: jq ausente (Windows) falha com winget install jqlang.jq" "exit $code, $out"; fi
  out="$(run_setup "$C4" "$MAC_BIN:$NOJQ_PATH" check 2>&1)"
  if grep -qF 'falta jq — instale: brew install jq' <<<"$out"; then ok "setup check: jq ausente (macOS) sugere brew install jq"; else ko "setup check: jq ausente (macOS) sugere brew install jq" "$out"; fi
  out="$(run_setup "$C4" "$LINUX_BIN:$NOJQ_PATH" check 2>&1)"
  if grep -qF 'falta jq — instale: sudo apt install jq' <<<"$out"; then ok "setup check: jq ausente (Linux) sugere sudo apt install jq"; else ko "setup check: jq ausente (Linux) sugere sudo apt install jq" "$out"; fi
  run_setup "$C4" "$LINUX_BIN:$NOJQ_PATH" permissions segredos "$C4/p.json" >/dev/null 2>&1
  code=$?
  if [ "$code" = "2" ] && [ ! -e "$C4/p.json" ]; then ok "setup permissions: sem jq recusa e não grava"; else ko "setup permissions: sem jq recusa e não grava" "exit $code"; fi

  # Linux/WSL2 sem bwrap e socat: falta com o comando de instalacao.
  C5="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  out="$(run_setup "$C5" "$NOSB_BIN:$(PATH="$NOSB_PATH" path_without claude)" check 2>&1)"
  code=$?
  if [ "$code" = "1" ] && grep -qF 'falta bwrap (sandbox) — instale: sudo apt install bubblewrap' <<<"$out" &&
    grep -qF 'falta socat (sandbox) — instale: sudo apt install socat' <<<"$out" && grep -qF 'sandbox exige bwrap e socat' <<<"$out"; then
    ok "setup check: Linux sem bwrap e socat falha com o comando de instalação"
  else ko "setup check: Linux sem bwrap e socat falha com o comando de instalação" "exit $code, $out"; fi

  # Templates: regras de permissao so nos grupos; segredos com nomes explicitos, sem o curinga .env.*.
  TPL_PROJ="$REPO/plugins/kit/templates/project-settings.json"
  TPL_GROUPS="$REPO/plugins/kit/templates/project-permissions.json"
  if [ ! -e "$REPO/plugins/kit/templates/user-settings.json" ] &&
    jq -e '(.permissions.deny // []) == [] and (.sandbox.network.allowedDomains | length > 0)' "$TPL_PROJ" >/dev/null 2>&1 &&
    jq -e '(.groups[] | select(.id == "curl-wget") | .settings.permissions.deny) == ["Bash(curl *)", "Bash(wget *)"]' "$TPL_GROUPS" >/dev/null 2>&1; then
    ok "templates: sem template de usuário; curl e wget só no grupo curl-wget; projeto com allowedDomains"
  else ko "templates: sem template de usuário; curl e wget só no grupo curl-wget; projeto com allowedDomains" "$(jq -c '.permissions' "$TPL_PROJ")"; fi
  tpl_miss=""
  for r in 'Read(**/.env)' 'Read(**/.env.local)' 'Read(**/.env.*.local)' 'Read(**/.env.test)' 'Read(**/.env.production)' 'Read(**/.env.development)' 'Read(**/.env.staging)' \
    'Read(**/*.pem)' 'Read(**/*.key)' 'Read(**/secrets/**)' 'Read(~/.ssh/**)' 'Read(~/.aws/**)' 'Read(~/.kube/**)' 'Read(~/.git-credentials)' 'Read(~/.npmrc)' \
    'Read(~/.config/gh/**)' 'Read(~/.docker/config.json)'; do
    jq -e --arg r "$r" '.groups[] | select(.id == "segredos") | .settings.permissions.deny | index($r) != null' "$TPL_GROUPS" >/dev/null 2>&1 || tpl_miss+="$r "
  done
  for r in 'Bash(git push --force *)' 'Bash(git push -f *)' 'Bash(git reset --hard *)' 'Bash(git clean -fdx *)'; do
    jq -e --arg r "$r" '.groups[] | select(.id == "git-destrutivo") | .settings.permissions.deny | index($r) != null' "$TPL_GROUPS" >/dev/null 2>&1 || tpl_miss+="$r "
  done
  # Nenhum Read de segredo casa um arquivo de exemplo (.env*.example etc.).
  ex_hit="$(jq -r '.groups[] | select(.id == "segredos") | .settings.permissions.deny[] | select(startswith("Read(**/")) | sub("^Read\\(\\*\\*/"; "") | sub("\\)$"; "")' "$TPL_GROUPS" | tr -d '\r' |
    while IFS= read -r g; do
      re="$("$TBASH" -c '. "$1/lib.sh"; glob_to_regex "$2"' _ "$SCRIPTS" "$g")"
      for f in .env.example .env.test.example .env.production.sample .env.local.template .env.dist; do [[ "$f" =~ $re ]] && printf '%s~%s ' "$g" "$f"; done
    done)"
  if [ -z "$tpl_miss" ] && [ -z "$ex_hit" ] && ! grep -qF 'Read(**/.env.*)' "$TPL_GROUPS" &&
    jq -e '(.groups[] | select(.id == "push") | .settings.permissions.ask) == ["Bash(git push *)"]' "$TPL_GROUPS" >/dev/null 2>&1; then
    ok "template de grupos: segredos por nome (sem .env.*, .env.example legível), git destrutivo e ask de push"
  else ko "template de grupos: segredos por nome (sem .env.*, .env.example legível), git destrutivo e ask de push" "faltam: $tpl_miss; casam exemplo: $ex_hit"; fi

  # lsp: plugin oficial pelos manifestos; binario presente ok, ausente com o comando ou sem instalacao.
  LR="$(mktemp -d "$TMP_ALL/lsp.XXXXXX")"
  mkdir -p "$LR/web" "$LR/svc" "$LR/java/src" "$LR/bin"
  printf '{}
' >"$LR/web/package.json"
  printf 'module x
' >"$LR/svc/go.mod"
  printf 'class A {}
' >"$LR/java/src/A.java"
  printf '# nada
' >"$LR/Makefile"
  git_q init "$LR"
  for t in typescript-language-server go; do printf '#!/usr/bin/env bash
exit 0
' >"$LR/bin/$t"; chmod +x "$LR/bin/$t"; done
  LSP_PATH="$LR/bin:$LINUX_BIN:$(PATH="$(PATH="$NOCLAUDE_PATH" path_without gopls)" path_without jdtls)"
  out="$(run_setup "$C1" "$LSP_PATH" lsp "$LR" 2>&1)"; code=$?
  if [ "$code" = "0" ] && grep -qxF 'lsp ts-lsp@claude-kit typescript-language-server: ok' <<<"$out" &&
    grep -qxF 'lsp gopls-lsp@claude-plugins-official gopls: falta — instale: go install golang.org/x/tools/gopls@latest' <<<"$out" &&
    grep -qxF 'lsp jdtls-lsp@claude-plugins-official jdtls: falta — sem instalação automática nesta plataforma' <<<"$out" &&
    [ "$(grep -c . <<<"$out")" = "3" ]; then
    ok "setup lsp: plugin por linguagem (ts-lsp do kit, demais oficiais), binário ok, ausente com instalação ou sem instalação"
  else ko "setup lsp: plugin por linguagem (ts-lsp do kit, demais oficiais), binário ok, ausente com instalação ou sem instalação" "exit $code, $out"; fi
  out="$(run_setup "$C1" "$LR/bin:$MAC_BIN:$(PATH="$NOCLAUDE_PATH" path_without jdtls)" lsp "$LR" 2>&1)"
  if grep -qF 'jdtls: falta' <<<"$out" && { command -v brew >/dev/null 2>&1 || grep -qF 'sem instalação automática' <<<"$out"; }; then
    ok "setup lsp: instalação só do macOS não vale fora dele e exige a ferramenta"
  else ko "setup lsp: instalação só do macOS não vale fora dele e exige a ferramenta" "$out"; fi
  LN="$(mktemp -d "$TMP_ALL/lsp.XXXXXX")"
  printf 'x
' >"$LN/main.c"
  git_q init "$LN"
  out="$(run_setup "$C1" "$LINUX_BIN:$NOCLAUDE_PATH" lsp "$LN" 2>&1)"; code=$?
  if [ "$code" = "0" ] && [ -z "$out" ]; then ok "setup lsp: linguagem sem plugin no kit não aparece"; else ko "setup lsp: linguagem sem plugin no kit não aparece" "exit $code, $out"; fi

  # plans: so plano com pendencia e mais de 14 dias sem mudanca.
  PR="$(mktemp -d "$TMP_ALL/plans.XXXXXX")"
  mkdir -p "$PR/docs/specs/velho" "$PR/docs/specs/novo" "$PR/docs/specs/feito"
  printf -- '- [x] 1. a
- [ ] 2. b
' >"$PR/docs/specs/velho/PLAN.md"
  printf -- '- [ ] 1. a
' >"$PR/docs/specs/novo/PLAN.md"
  printf -- '- [x] 1. a
' >"$PR/docs/specs/feito/PLAN.md"
  git_q init "$PR"
  touch -d "@$(($(date +%s) - 20 * 86400))" "$PR/docs/specs/velho/PLAN.md" "$PR/docs/specs/feito/PLAN.md"
  out="$(run_setup "$C1" "$LINUX_BIN:$NOCLAUDE_PATH" plans "$PR" 2>&1)"; code=$?
  if [ "$code" = "0" ] && [ "$out" = "plano parado há 20 dias: docs/specs/velho/PLAN.md (1/2)" ]; then
    ok "setup plans: só plano pendente com mais de 14 dias sem mudança"
  else ko "setup plans: só plano pendente com mais de 14 dias sem mudança" "exit $code, $out"; fi
  # Pasta-mae: plano parado de repositorio filho aparece; 14 dias e 6 horas ja conta como parado.
  PM="$(mktemp -d "$TMP_ALL/plans-mae.XXXXXX")"
  mkdir -p "$PM/api/docs/specs/x"
  printf -- '- [ ] 1. a\n' >"$PM/api/docs/specs/x/PLAN.md"
  git_q init "$PM/api"
  touch -d "@$(($(date +%s) - 14 * 86400 - 6 * 3600))" "$PM/api/docs/specs/x/PLAN.md"
  out="$(run_setup "$C1" "$LINUX_BIN:$NOCLAUDE_PATH" plans "$PM" 2>&1)"; code=$?
  if [ "$code" = "0" ] && [ "$out" = "plano parado há 14 dias: api/docs/specs/x/PLAN.md (0/1)" ]; then
    ok "setup plans: pasta-mãe lista plano de repositório filho, 14 dias já é parado"
  else ko "setup plans: pasta-mãe lista plano de repositório filho, 14 dias já é parado" "exit $code, $out"; fi
  out="$(KIT_USERNS_SYSCTL="$TMP_ALL/userns-1" run_setup "$C5" "$LINUX_BIN:$NOCLAUDE_PATH" check 2>&1)"
  if grep -qF 'aviso sandbox: o AppArmor restringe user namespaces' <<<"$out"; then ok "setup check: AppArmor restringindo userns gera aviso"; else ko "setup check: AppArmor restringindo userns gera aviso" "$out"; fi
  out="$(KIT_USERNS_SYSCTL="$TMP_ALL/userns-1" run_setup "$C5" "$MAC_BIN:$NOCLAUDE_PATH" check 2>&1)"
  if ! grep -qF 'aviso sandbox' <<<"$out"; then ok "setup check: aviso de AppArmor só no Linux"; else ko "setup check: aviso de AppArmor só no Linux" "$out"; fi

  # Claude Code abaixo da minima: check falha com claude update.
  OLD_BIN="$(setup_bin Linux 2.1.200)"
  out="$(run_setup "$C4" "$OLD_BIN:$NOCLAUDE_PATH" check 2>&1)"
  code=$?
  if [ "$code" = "1" ] && grep -qF 'falta claude >= 2.1.295 (atual 2.1.200) — rode: claude update' <<<"$out"; then
    ok "setup check: Claude Code antigo falha com claude update"
  else ko "setup check: Claude Code antigo falha com claude update" "exit $code, $out"; fi
fi
}

g_notify() {
echo "notify e alertas existentes"
if [ -z "$FILTER" ] || [[ "notify alerts" == *"$FILTER"* ]]; then
  NT="$(mktemp -d "$TMP_ALL/notify.XXXXXX")"
  mkdir -p "$NT/bin" "$NT/cwd"
  # Binarios falsos: gravam argv (um por linha) e as variaveis de titulo e mensagem; curl grava o corpo.
  for b in powershell.exe osascript notify-send curl canberra-gtk-play; do
    cat >"$NT/bin/$b" <<EOF
#!/usr/bin/env bash
d="$NT/log-\${0##*/}"
mkdir -p "\$d"
printf '%s\n' "\$@" >"\$d/argv"
printf '%s' "\${KIT_NOTIFY_MSG-}" >"\$d/msg"
[ "\${0##*/}" != curl ] || cat >"\$d/body"
exit "\${FAKE_EXIT:-0}"
EOF
    chmod +x "$NT/bin/$b"
  done
  EVIL="a'b\"c
\$(touch PWN1) \`touch PWN2\`; touch PWN3 & %TEMP% \$env:USERNAME"
  nt_send() {
    (cd "$NT/cwd" && env -u KIT_NOTIFY_DRY_RUN PATH="$NT/bin:$PATH" KIT_NOTIFY_PLATFORM="$1" KIT_NOTIFY_TITLE="Claude Code" KIT_NOTIFY_MSG="$EVIL" \
      KIT_NOTIFY_SOUND=true KIT_NOTIFY_NTFY_ENV="${3:-NT_TOPIC}" NT_TOPIC=kit-teste KIT_NOTIFY_DISCORD_ENV="${4:-}" NT_HOOK=https://discord.test/x \
      FAKE_EXIT="${2:-0}" "$TBASH" "$SCRIPTS/notify.sh" --send >"$NT/out" 2>"$NT/err")
  }
  for plat in windows:powershell.exe wsl:powershell.exe macos:osascript linux:notify-send; do
    b="${plat#*:}"; plat="${plat%%:*}"
    rm -rf "$NT"/log-*
    nt_send "$plat"; code=$?
    why=""
    [ "$code" = "0" ] || why+="exit $code; "
    [ ! -s "$NT/out" ] || why+="stdout '$(head -c 100 "$NT/out")'; "
    ! ls "$NT/cwd" | grep -q PWN || why+="comando da mensagem executado; "
    [ -f "$NT/log-$b/argv" ] || why+="$b não chamado; "
    if [ "$b" = "notify-send" ]; then
      [ "$(tail -n +5 "$NT/log-$b/argv")" = "$EVIL" ] || why+="mensagem não chegou intacta como argumento; "
    else
      ! grep -qF 'PWN' "$NT/log-$b/argv" 2>/dev/null || why+="mensagem dentro do comando; "
      [ "$(cat "$NT/log-$b/msg" 2>/dev/null)" = "$EVIL" ] || why+="KIT_NOTIFY_MSG diferente; "
    fi
    jq -e --arg m "$EVIL" '.message == $m' "$NT/log-curl/body" >/dev/null 2>&1 || why+="corpo do push sem a mensagem intacta; "
    if [ -z "$why" ]; then ok "notify --send ($plat): aspas, quebra de linha e \$() não executam e chegam intactos"
    else ko "notify --send ($plat): aspas, quebra de linha e \$() não executam e chegam intactos" "$why$(head -c 200 "$NT/err")"; fi
  done
  rm -rf "$NT"/log-*
  nt_send linux 0 - NT_HOOK
  if jq -e --arg m "$EVIL" '(.content | endswith($m)) and .allowed_mentions.parse == []' "$NT/log-curl/body" >/dev/null 2>&1 &&
    [ "$(tail -n 1 "$NT/log-curl/argv")" = "https://discord.test/x" ]; then ok "notify --send: Discord recebe a mensagem intacta, sem menções"
  else ko "notify --send: Discord recebe a mensagem intacta, sem menções" "$(cat "$NT/log-curl/body" 2>&1)"; fi
  nt_send windows 1; code=$?
  if [ "$code" = "0" ] && [ ! -s "$NT/out" ]; then ok "notify --send: notificador falhando sai 0 calado (sino de reserva)"
  else ko "notify --send: notificador falhando sai 0 calado (sino de reserva)" "exit $code, $(head -c 200 "$NT/out")"; fi
  out="$(cd "$NT/cwd" && env -u KIT_NOTIFY_DRY_RUN PATH="$(path_without notify-send)" KIT_NOTIFY_PLATFORM=linux KIT_NOTIFY_MSG=x "$TBASH" "$SCRIPTS/notify.sh" --send 2>"$NT/err")"; code=$?
  if [ "$code" = "0" ] && [ -z "$out" ] && { [ ! -s "$NT/err" ] || [ "$(cat "$NT/err")" = $'\a' ]; }; then ok "notify --send: sem notificador no Linux toca o sino e sai 0"
  else ko "notify --send: sem notificador no Linux toca o sino e sai 0" "exit $code, out='$out', err='$(cat -v "$NT/err")'"; fi
  out="$(cd "$NT/cwd" && KIT_NOTIFY_DRY_RUN=1 KIT_NOTIFY_PLATFORM=linux "$TBASH" "$SCRIPTS/notify.sh" <<<'{"cwd":"."' 2>&1)"; code=$?
  if [ "$code" = "0" ] && [ -z "$out" ]; then ok "notify: JSON inválido sai 0 calado"; else ko "notify: JSON inválido sai 0 calado" "exit $code, $out"; fi
  out="$("$TBASH" -c '. "$1/lib.sh"; kit_duration 45; echo; kit_duration 187; echo; kit_duration 3720' _ "$SCRIPTS" | paste -sd' ' -)"
  if [ "$out" = "45s 3m07s 1h02m" ]; then ok "kit_duration: 45s, 3m07s, 1h02m"; else ko "kit_duration: 45s, 3m07s, 1h02m" "$out"; fi

  # setup.sh alerts: so leitura; Notification/Stop que notificam, preferredNotifChannel, terminal e plugins.
  AL="$NT/alerts"
  mkdir -p "$AL/cfg/plugins" "$AL/proj/.claude/hooks" "$AL/plug/outro/hooks" "$AL/plug/kit/hooks" "$AL/home"
  git_q init "$AL/proj"
  run_alerts() { (cd "$AL/proj" && env -u TERM_PROGRAM -u KITTY_WINDOW_ID HOME="$AL/home" CLAUDE_CONFIG_DIR="$AL/cfg" "$@" "$TBASH" "$SCRIPTS/setup.sh" alerts . 2>&1); }
  out="$(run_alerts)"
  if [ -z "$out" ]; then ok "setup alerts: sem alerta nenhum não imprime nada"; else ko "setup alerts: sem alerta nenhum não imprime nada" "$out"; fi
  printf '%s' '{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"notify-send \"Claude\" \"aguardando\""}]}]}}' >"$AL/cfg/settings.json"
  out="$(run_alerts)"
  if grep -qF "alerta: $AL/cfg/settings.json: hook Notification (notify-send" <<<"$out" && [ "$(wc -l <<<"$out" | tr -d ' ')" = "1" ]; then
    ok "setup alerts: hook Notification no settings do usuário vira aviso de duplicação"
  else ko "setup alerts: hook Notification no settings do usuário vira aviso de duplicação" "$out"; fi
  printf '#!/bin/sh\nosascript -e "display notification fim"\n' >"$AL/proj/.claude/hooks/fim.sh"
  printf '#!/bin/sh\necho lint\n' >"$AL/proj/.claude/hooks/lint.sh"
  printf '%s' '{"preferredNotifChannel":"terminal_bell","hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/fim.sh\""},{"type":"command","command":"bash .claude/hooks/lint.sh"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"notify-send pre"}]}]}}' >"$AL/proj/.claude/settings.json"
  printf '%s' '{"preferredNotifChannel":"notifications_disabled"}' >"$AL/proj/.claude/settings.local.json"
  printf '%s' '{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/toast.sh\""}]}]}}' >"$AL/plug/outro/hooks/hooks.json"
  printf 'powershell.exe -Command "New-BurntToastNotification"\n' >"$AL/plug/outro/hooks/toast.sh"
  printf '%s' '{"hooks":{"Notification":[{"hooks":[{"type":"command","command":"notify.sh"}]}]}}' >"$AL/plug/kit/hooks/hooks.json"
  jq -n --arg o "$AL/plug/outro" --arg k "$AL/plug/kit" '{version: 2, plugins: {"outro@m": [{scope: "user", installPath: $o}], "kit@claude-kit": [{scope: "user", installPath: $k}], "desligado@m": [{scope: "user", installPath: $o}]}}' >"$AL/cfg/plugins/installed_plugins.json"
  jq '. + {enabledPlugins: {"outro@m": true, "kit@claude-kit": true, "desligado@m": false}}' "$AL/cfg/settings.json" >"$AL/s.tmp" && mv "$AL/s.tmp" "$AL/cfg/settings.json"
  al_sums() { cksum "$AL/cfg/settings.json" "$AL/proj/.claude/settings.json" "$AL/proj/.claude/settings.local.json" "$AL/cfg/plugins/installed_plugins.json" 2>&1; }
  sums="$(al_sums)"
  out="$(run_alerts)"
  why=""
  for want in '.claude/settings.json: hook Stop (bash "$CLAUDE_PROJECT_DIR/.claude/hooks/fim.sh")' '.claude/settings.json: preferredNotifChannel=terminal_bell' \
    'plugin outro@m: hook Notification'; do
    grep -qF -- "$want" <<<"$out" || why+="sem [$want] "
  done
  for bad in 'lint.sh' 'PreToolUse' 'notifications_disabled' 'kit@claude-kit' 'desligado@m'; do
    ! grep -qF -- "$bad" <<<"$out" || why+="não deveria: [$bad] "
  done
  [ "$sums" = "$(al_sums)" ] || why+="arquivo alterado "
  if [ -z "$why" ]; then ok "setup alerts: Stop por script do projeto, preferredNotifChannel e plugin habilitado; kit, desligado e não-alerta fora; nada alterado"
  else ko "setup alerts: Stop por script do projeto, preferredNotifChannel e plugin habilitado; kit, desligado e não-alerta fora; nada alterado" "$why: $out"; fi
  rm -f "$AL/cfg/settings.json" "$AL/proj/.claude/settings.json" "$AL/proj/.claude/settings.local.json"
  out="$(run_alerts TERM_PROGRAM=iTerm.app)"
  if [ "$out" = "alerta: terminal iTerm2: aviso nativo do Claude Code (preferredNotifChannel auto)" ]; then ok "setup alerts: iTerm2 sem canal configurado já tem aviso nativo"
  else ko "setup alerts: iTerm2 sem canal configurado já tem aviso nativo" "$out"; fi
fi
}

g_interface() {
echo "interface"
if [ -z "$FILTER" ] || [[ "interface ui" == *"$FILTER"* ]]; then
  UIS="$SCRIPTS/ui.sh"
  UT="$(mktemp -d "$TMP_ALL/ui.XXXXXX")"
  unset KIT_UI_BROWSER KIT_UI_WAIT_S KIT_UI_LOAD_MS KIT_UI_BUDGET_S
  ui_commit() { git_q init "$1"; git_q -C "$1" add -A; git_q -C "$1" commit -m init; }
  mixed_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
  # Uso: ui_status <config> <PATH> [pasta]. Roda na pasta $P.
  ui_status() {
    local cfg="$1" path="$2"
    shift 2
    (cd "$P" && CLAUDE_CONFIG_DIR="$cfg" PATH="$path" "$TBASH" "$UIS" status "$@" 2>&1)
  }
  ui_line() { grep "^$1" <<<"$2" | head -n 1; }

  # status: contagem por extensao, globs, pastas e marcadores; testes, stories, minificados e dist de fora.
  P="$UT/proj"
  mkdir -p "$P/src/components" "$P/src/pages" "$P/src/styles" "$P/dist" "$P/infra" "$P/scripts"
  for f in src/components/Botao.tsx src/components/Card.tsx src/pages/Home.tsx src/styles/app.css src/styles/tokens.css \
    src/components/Botao.test.tsx src/components/Card.stories.tsx dist/saida.html src/styles/lib.min.css src/api.ts \
    infra/variables.tf scripts/tokens.py src/theme.test.ts; do printf 'x\n' >"$P/$f"; done
  printf 'export default {}\n' >"$P/tailwind.config.ts"
  printf '%s\n' '{"dependencies":{"@mui/material":"1","@radix-ui/react-dialog":"1","left-pad":"1"},"devDependencies":{"tailwindcss":"1"}}' >"$P/package.json"
  ui_commit "$P"
  CFG0="$(mktemp -d "$TMP_ALL/uicfg.XXXXXX")"
  out="$(ui_status "$CFG0" "$PATH")"; code=$?
  if [ "$code" = "0" ] && [ "$(ui_line 'ui: ' "$out")" = "ui: 5 arquivos de interface (tsx 3, css 2)" ] &&
    [ "$(ui_line 'ui globs: ' "$out")" = "ui globs: **/*.tsx **/*.css" ] &&
    [ "$(ui_line 'ui pastas: ' "$out")" = "ui pastas: src/components (2), src/styles (2), src/pages (1)" ]; then
    ok "ui status: conta por extensão, propõe globs e pastas; teste, story, minificado e dist ficam de fora"
  else ko "ui status: conta por extensão, propõe globs e pastas; teste, story, minificado e dist ficam de fora" "exit $code, $out"; fi
  design="$(ui_line 'ui design: ' "$out")"
  d_bad=""
  for want in 'tailwind (tailwind.config.ts)' 'tokens (src/styles/tokens.css)' 'mui (package.json)' 'radix (package.json)'; do
    grep -qF -- "$want" <<<"$design" || d_bad+="[$want] "
  done
  [ "$(grep -o 'tailwind' <<<"$design" | wc -l | tr -d ' ')" = "2" ] || d_bad+="tailwind repetido "
  ! grep -qF 'left-pad' <<<"$design" || d_bad+="left-pad "
  if [ -z "$d_bad" ]; then ok "ui status: biblioteca, tema e tokens pelo nome do arquivo e pelas dependências"
  else ko "ui status: biblioteca, tema e tokens pelo nome do arquivo e pelas dependências" "$d_bad: $design"; fi
  if ! grep -qE 'variáveis|tema|tokens\.py' <<<"$design"; then ok "ui status: variables.tf, tokens.py e theme.test.ts não contam como tema nem como tokens"
  else ko "ui status: variables.tf, tokens.py e theme.test.ts não contam como tema nem como tokens" "$design"; fi
  if ! grep -q '^rule: ' <<<"$out" && [ -z "$(ls -A "$CFG0")" ]; then ok "ui status: sem ui no kit.json não há linha rule, e nada é criado na config do usuário"
  else ko "ui status: sem ui no kit.json não há linha rule, e nada é criado na config do usuário" "$out"; fi
  N="$UT/semtela"
  mkdir -p "$N/src"
  printf 'x\n' >"$N/src/api.ts"
  ui_commit "$N"
  out="$(P="$N" ui_status "$CFG0" "$PATH")"
  if [ "$(ui_line 'ui' "$out")" = "ui: nenhum arquivo de interface" ] && ! grep -q '^ui globs' <<<"$out" && grep -q '^captura: ' <<<"$out"; then
    ok "ui status: projeto sem tela diz nenhum arquivo de interface"
  else ko "ui status: projeto sem tela diz nenhum arquivo de interface" "$out"; fi
  "$TBASH" "$UIS" >/dev/null 2>&1; c1=$?
  "$TBASH" "$UIS" status "$UT/nao-existe" >/dev/null 2>&1; c2=$?
  if [ "$c1" = "2" ] && [ "$c2" = "2" ]; then ok "ui: sem subcomando ou com pasta inexistente sai com 2"; else ko "ui: sem subcomando ou com pasta inexistente sai com 2" "$c1 $c2"; fi

  # Linha rule: estado da .claude/rules/kit-ui.md frente ao template, ao bloco de regras e a ui.globs.
  # E o que o modo reparo do init usa para criar ou atualizar a rule.
  mkdir -p "$P/.claude/rules"
  RK="$P/.claude/kit.json"
  RR="$P/.claude/rules/kit-ui.md"
  rule_line() { ui_line 'rule: ' "$(ui_status "$CFG0" "$PATH")"; }
  # Uso: write_rule <versao> <glob>... Grava a rule como o init grava: paths, cabecalho e o bloco de regras.
  write_rule() {
    local v="$1" g
    shift
    { printf '%s\n' '---' 'paths:'; for g in "$@"; do printf '  - "%s"\n' "$g"; done
      printf '%s\n' '---' "<!-- kit:ui v$v -->" '# Interface deste projeto' '' '- Tema e tokens: `src/styles/tokens.css`' ''
      cat "$REPO/plugins/kit/skills/execute/ui-rules.md"; } >"$RR"
  }
  printf '%s\n' '{"ui":{"globs":["**/*.tsx","**/*.css"]}}' >"$RK"
  r1="$(rule_line)"
  write_rule 1 '**/*.tsx' '**/*.css'
  r2="$(rule_line)"
  grep -v '^3\. ' "$RR" >"$RR.tmp" && mv "$RR.tmp" "$RR"
  r3="$(rule_line)"
  write_rule 1 '**/*.tsx'
  r4="$(rule_line)"
  write_rule 0 '**/*.tsx' '**/*.css'
  r5="$(rule_line)"
  printf '%s\n' '# Regras de tela escritas pelo projeto' >"$RR"
  r6="$(rule_line)"
  printf '%s\n' '{"ui":false}' >"$RK"
  r7="$(rule_line)"
  rm -rf "$RK" "$P/.claude/rules"
  if [ "$r1" = "rule: ausente" ] && [ "$r2" = "rule: ok" ] && [ "$r3" = "rule: desatualizada — 1 linhas do bloco de regras diferentes das do kit" ] &&
    [ "$r4" = "rule: desatualizada — paths sem o glob **/*.css de ui.globs" ] && [ "$r5" = "rule: desatualizada — versão 0, a do kit é 1" ] &&
    [ "$r6" = "rule: do projeto (sem o cabeçalho kit:ui)" ] && [ -z "$r7" ] && [ -z "$(ls -A "$CFG0")" ]; then
    ok "ui status: rule ausente, em dia, com regra, glob ou versão para trás, e do projeto; ui false não tem a linha"
  else ko "ui status: rule ausente, em dia, com regra, glob ou versão para trás, e do projeto; ui false não tem a linha" "1='$r1' 2='$r2' 3='$r3' 4='$r4' 5='$r5' 6='$r6' 7='$r7'"; fi

  # Sem node: status diz ausente e a captura sai com 3.
  NONODE_PATH="$(path_without node)"
  if found_in_path "$NONODE_PATH" node >/dev/null; then
    ko "PATH de teste sem node" "node ainda encontrado em $(found_in_path "$NONODE_PATH" node)"
  else
    out="$(ui_status "$CFG0" "$NONODE_PATH")"
    if grep -qx 'node: ausente' <<<"$out" && grep -qx 'navegador: ausente' <<<"$out" && grep -qx 'captura: nenhuma — revisão de interface só pelo código' <<<"$out"; then
      ok "ui status: sem node não há captura"
    else ko "ui status: sem node não há captura" "$out"; fi
    out="$(cd "$P" && PATH="$NONODE_PATH" "$TBASH" "$UIS" capture 2>&1)"; code=$?
    if [ "$code" = "3" ] && grep -qF 'node não encontrado; sem captura' <<<"$out"; then ok "ui capture: sem node sai com 3 e diz que a revisão segue pelo código"
    else ko "ui capture: sem node sai com 3 e diz que a revisão segue pelo código" "exit $code, $out"; fi
  fi

  if ! command -v node >/dev/null 2>&1; then
    echo "  pulado modos de captura e captura no navegador (sem node)"
  else
    # Linha captura: pelo que existe. KIT_UI_BROWSER troca o navegador por um arquivo que existe ou nao.
    ws="$(node -e 'process.stdout.write(typeof WebSocket === "undefined" ? "0" : "1")')"
    exists="$(mixed_path "$(command -v git)")"
    m1="$(ui_line 'captura: ' "$(KIT_UI_BROWSER="$exists" ui_status "$CFG0" "$PATH")")"
    m2="$(ui_line 'captura: ' "$(KIT_UI_BROWSER="$UT/nao-existe" ui_status "$CFG0" "$PATH")")"
    mkdir -p "$P/.claude"
    printf '%s\n' '{"ui":{"globs":["lib/**"],"screenshot":"tira {out}"}}' >"$P/.claude/kit.json"
    m3="$(ui_line 'captura: ' "$(KIT_UI_BROWSER="$UT/nao-existe" ui_status "$CFG0" "$PATH")")"
    rm -f "$P/.claude/kit.json"
    if [ "$m1" = "captura: kit" ] && [ "$m2" = "captura: nenhuma — revisão de interface só pelo código" ] &&
      [ "$m3" = "captura: comando (ui.screenshot do kit.json)" ]; then
      ok "ui status: captura pelo kit, nenhuma e pelo comando do projeto"
    else ko "ui status: captura pelo kit, nenhuma e pelo comando do projeto" "1='$m1' 2='$m2' 3='$m3'"; fi

    doc="$(node "$SCRIPTS/ui-capture.mjs" --doctor 2>/dev/null | tr -d '\r')"
    if ! grep -q '^navegador: ok' <<<"$doc"; then
      echo "  pulado captura no navegador (nenhum Chromium instalado)"
    else
      free_port() { node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { process.stdout.write(String(s.address().port)); s.close(); });'; }
      url_up() { node -e 'const q = require("http").get(process.argv[1], { timeout: 1500 }, (r) => { r.resume(); process.exit(0); }); q.on("error", () => process.exit(1)); q.on("timeout", () => { q.destroy(); process.exit(1); });' "$1"; }
      stop_pid() {
        local w
        if [ "$TEST_PLATFORM" = "windows" ]; then
          w="$(cat "/proc/$1/winpid" 2>/dev/null)"
          [ -z "$w" ] || taskkill //T //F //PID "$w" >/dev/null 2>&1
        fi
        kill "$1" 2>/dev/null
        wait "$1" 2>/dev/null
      }
      PORT="$(free_port)"
      BASE="http://127.0.0.1:$PORT"
      SRV="$(mixed_path "$HERE/ui/server.mjs")"
      C="$UT/cap"
      mkdir -p "$C/.claude"
      jq -n --arg dev "node '$SRV' $PORT" --arg url "$BASE" '{ui: {globs: ["**/*.html"], dev: $dev, url: $url, routes: ["/"]}}' >"$C/.claude/kit.json"
      cap() { (cd "$1" && shift && "$TBASH" "$UIS" capture "$@"); }

      out="$(cap "$C" --name t --routes /,/ruim,/escuro,/longa,/nao-existe 2>"$UT/cap.err")"; code=$?
      R="$C/.claude/state/ui/t/report.json"
      if [ "$code" = "3" ] && grep -qF 'navegador não iniciou' "$UT/cap.err"; then
        echo "  pulado captura no navegador (o navegador não inicia nesta máquina: $(head -c 200 "$UT/cap.err" | tr '\n' ' '))"
      else
        s_bad=""
        for want in 'captura: navegador (' 'app iniciado por ui.dev' '5 telas' 'imagens em 360x800, 768x1024, 1280x800, 1920x1080' \
          'achado [B2] rolagem-horizontal em 320–600px' 'conferir [M7] texto-pequeno' 'tema claro e escuro' 'resultado: 13 achados, 2 a conferir'; do
          grep -qF -- "$want" <<<"$out" || s_bad+="[$want] "
        done
        if [ "$code" = "1" ] && [ -z "$s_bad" ]; then ok "ui capture: sobe o app, percorre as larguras e resume os achados (exit 1)"
        else ko "ui capture: sobe o app, percorre as larguras e resume os achados (exit 1)" "exit $code, faltou $s_bad; $(tail -n 5 <<<"$out") $(head -c 300 "$UT/cap.err")"; fi
        [ -f "$R" ] || printf '{}\n' >"$R"
        if jq -e '.screens[0] | .route == "/" and .findings == [] and .dark == true and .breakpoints == [700] and (.images | length) == 6
            and ([.images[] | select(.theme == "escuro")] | length) == 2' "$R" >/dev/null 2>&1; then
          ok "ui capture: página limpa sem achado, uma imagem por tamanho e duas no tema escuro"
        else ko "ui capture: página limpa sem achado, uma imagem por tamanho e duas no tema escuro" "$(jq -c '.screens[0]' "$R" 2>&1 | head -c 500)"; fi
        if jq -e '.widths as $w | all((320, 360, 600, 699, 700, 701, 768, 899, 900, 901, 1280, 1920); . as $x | $w | index($x) != null)
            and .viewports == ["360x800", "768x1024", "1280x800", "1920x1080"] and .mode == "navegador" and .server == "iniciado"' "$R" >/dev/null 2>&1; then
          ok "ui capture: larguras padrão mais um pixel antes e depois de cada ponto de quebra do CSS"
        else ko "ui capture: larguras padrão mais um pixel antes e depois de cada ponto de quebra do CSS" "$(jq -c '{widths, viewports, mode, server}' "$R" 2>&1)"; fi
        if jq -e '.screens[1].findings as $f | def f3($r; $i; $l): any($f[]; .rule == $r and .id == $i and .level == $l);
            f3("rolagem-horizontal"; "B2"; "achado") and f3("sem-nome"; "B3"; "achado") and f3("sem-teclado"; "B3"; "achado")
            and f3("contraste"; "M1"; "achado") and f3("alvo-pequeno"; "M2"; "achado") and f3("so-placeholder"; "M8"; "achado")
            and f3("sem-alt"; "M8"; "achado") and f3("sem-lang"; "M8"; "achado") and f3("texto-pequeno"; "M7"; "conferir")
            and f3("titulos"; "M8"; "conferir") and f3("console"; "M9"; "achado") and f3("requisicao"; "M9"; "achado")' "$R" >/dev/null 2>&1; then
          ok "ui capture: página com defeitos sai com cada regra, id e nível"
        else ko "ui capture: página com defeitos sai com cada regra, id e nível" "$(jq -c '[.screens[1].findings[] | "\(.level) \(.id) \(.rule)"]' "$R" 2>&1)"; fi
        if jq -e 'any(.screens[1].findings[]; .rule == "rolagem-horizontal" and .widths == "320–600" and (.detail | contains("table (600px)")))
            and any(.screens[1].findings[]; .rule == "contraste" and (.detail | contains("2.32:1")) and (.detail | contains("#aaaaaa sobre #ffffff")))
            and any(.screens[1].findings[]; .rule == "alvo-pequeno" and .count == 3 and .widths == "")
            and .screens[1].breakpoints == [900]' "$R" >/dev/null 2>&1; then
          ok "ui capture: rolagem horizontal com a faixa de larguras e o elemento, contraste com a razão e as cores"
        else ko "ui capture: rolagem horizontal com a faixa de larguras e o elemento, contraste com a razão e as cores" "$(jq -c '[.screens[1].findings[] | select(.rule == "rolagem-horizontal" or .rule == "contraste" or .rule == "alvo-pequeno")]' "$R" 2>&1 | head -c 700)"; fi
        if jq -e '.screens[2] | (.findings | length) == 1 and .findings[0].rule == "contraste (tema escuro)" and .findings[0].id == "M1" and .dark == true' "$R" >/dev/null 2>&1; then
          ok "ui capture: contraste ruim só no tema escuro é achado"
        else ko "ui capture: contraste ruim só no tema escuro é achado" "$(jq -c '.screens[2].findings' "$R" 2>&1 | head -c 400)"; fi
        if jq -e '.screens[3] | .findings == [] and (.images | length) == 12 and ([.images[] | .parts] | unique) == [3]' "$R" >/dev/null 2>&1; then
          ok "ui capture: página longa sai em três partes por tamanho"
        else ko "ui capture: página longa sai em três partes por tamanho" "$(jq -c '.screens[3].images' "$R" 2>&1 | head -c 400)"; fi
        if jq -e '.screens[4] | (.findings | length) == 1 and .findings[0].rule == "nao-carregou" and .findings[0].id == "M9" and (.images | length) == 1' "$R" >/dev/null 2>&1; then
          ok "ui capture: rota 404 vira um achado, sem sondar a página de erro"
        else ko "ui capture: rota 404 vira um achado, sem sondar a página de erro" "$(jq -c '.screens[4]' "$R" 2>&1 | head -c 400)"; fi
        i_bad=""
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          [ -s "$C/.claude/state/ui/t/$f" ] || i_bad+="$f "
        done < <(jq -r '.screens[].images[].file' "$R" 2>/dev/null | tr -d '\r')
        dims="$(node -e 'const b = require("fs").readFileSync(process.argv[1]); process.stdout.write(b.toString("latin1", 1, 4) + " " + b.readUInt32BE(16) + "x" + b.readUInt32BE(20));' "$C/.claude/state/ui/t/raiz-360x800-1.png" 2>&1)"
        if [ -z "$i_bad" ] && [ "$dims" = "PNG 360x800" ] && jq -e '.totals == {findings: 13, check: 2, images: 29, incomplete: 0}' "$R" >/dev/null 2>&1; then
          ok "ui capture: toda imagem do relatório existe, PNG no tamanho pedido"
        else ko "ui capture: toda imagem do relatório existe, PNG no tamanho pedido" "faltam: $i_bad; $dims; $(jq -c '.totals' "$R" 2>&1)"; fi
        if ! url_up "$BASE/"; then ok "ui capture: o app que a captura subiu foi derrubado"; else ko "ui capture: o app que a captura subiu foi derrubado" "$BASE ainda responde"; fi

        # App ja rodando: nao e derrubado. --probe-only nao grava imagem e sai 0 em pagina limpa.
        (cd "$HERE/ui" && exec node server.mjs "$PORT") >/dev/null 2>&1 &
        srv=$!
        for _ in $(seq 1 40); do url_up "$BASE/" && break; sleep 0.25; done
        out="$(cap "$C" --name p --probe-only --routes / 2>&1)"; code=$?
        if [ "$code" = "0" ] && grep -qF 'app já estava rodando' <<<"$out" && grep -qF 'sem achados na sondagem' <<<"$out" &&
          [ -f "$C/.claude/state/ui/p/report.json" ] && ! ls "$C/.claude/state/ui/p/"*.png >/dev/null 2>&1 && url_up "$BASE/"; then
          ok "ui capture --probe-only: sem imagem, exit 0 em página limpa, app que já rodava continua rodando"
        else ko "ui capture --probe-only: sem imagem, exit 0 em página limpa, app que já rodava continua rodando" "exit $code, $out"; fi

        # axe-core do projeto: as regras dele entram; as que a sondagem ja mede ficam de fora.
        A="$UT/axe"
        mkdir -p "$A/.claude" "$A/node_modules/axe-core"
        cp "$C/.claude/kit.json" "$A/.claude/kit.json"
        printf '%s\n' 'window.axe = { run: async () => ({ violations: [{ id: "landmark-one-main", impact: "serious", help: "Documento precisa de um landmark main", helpUrl: "https://regras.test/landmark", nodes: [{ target: ["html"] }] }, { id: "color-contrast", impact: "serious", help: "x", helpUrl: "y", nodes: [{ target: ["p"] }] }, { id: "select-name", impact: "critical", help: "Select precisa de nome", helpUrl: "https://regras.test/select", nodes: [{ target: ["select"] }] }, { id: "aria-required-attr", impact: "critical", help: "Atributo ARIA obrigatório", helpUrl: "https://regras.test/aria", nodes: [{ target: ["div"] }] }] }) };' >"$A/node_modules/axe-core/axe.min.js"
        out="$(cap "$A" --name a --probe-only --routes / 2>&1)"; code=$?
        RX="$A/.claude/state/ui/a/report.json"
        if [ "$code" = "1" ] && jq -e '.screens[0].findings as $f | ($f | length) == 3
            and any($f[]; .rule == "axe:landmark-one-main" and .id == "M8" and .level == "achado" and (.detail | contains("https://regras.test/landmark")))' "$RX" >/dev/null 2>&1; then
          ok "ui capture: axe-core do projeto entra no relatório, sem repetir o que a sondagem mede"
        else ko "ui capture: axe-core do projeto entra no relatório, sem repetir o que a sondagem mede" "exit $code, $out"; fi
        if jq -e '.screens[0].findings as $f | any($f[]; .rule == "axe:select-name" and .id == "B3") and any($f[]; .rule == "axe:aria-required-attr" and .id == "M8" and .level == "achado")
            and all($f[]; .widths == "")' "$RX" >/dev/null 2>&1; then
          ok "ui capture: regra do axe de nome acessível sai como B3 e as outras como M8, sem faixa de larguras enganosa"
        else ko "ui capture: regra do axe de nome acessível sai como B3 e as outras como M8, sem faixa de larguras enganosa" "$(jq -c '[.screens[0].findings[] | {rule, id, level, widths}]' "$RX" 2>&1 | head -c 500)"; fi

        # Casos de borda numa rodada so: dialogo na carga, overflow-x oculto, texto sobre imagem, elemento
        # dimensionado por script, redirecionamento e rota que so muda a ancora.
        E="$UT/borda"
        mkdir -p "$E/.claude"
        jq -n --arg url "$BASE" '{ui: {globs: ["**/*.html"], url: $url, viewports: ["360x800", "1280x800"]}}' >"$E/.claude/kit.json"
        out="$(KIT_UI_LOAD_MS=4000 cap "$E" --name b --probe-only --routes '/borda,/grafico,/cortada,/vai/longa,/#topo' 2>&1)"; code=$?
        RB="$E/.claude/state/ui/b/report.json"
        if [ "$code" = "0" ] && jq -e '.screens[0] | any(.warnings[]; contains("alert: sessão expirada")) and .title == "Casos de borda"' "$RB" >/dev/null 2>&1; then
          ok "ui capture: diálogo aberto na carga é fechado e vira aviso, sem travar a captura"
        else ko "ui capture: diálogo aberto na carga é fechado e vira aviso, sem travar a captura" "exit $code, $(tail -n 8 <<<"$out")"; fi
        if jq -e '.screens[0].findings | length == 1 and .[0].rule == "contraste" and .[0].level == "conferir" and (.[0].detail | contains("há imagem na área do texto"))' "$RB" >/dev/null 2>&1; then
          ok "ui capture: menu fechado fora da tela não é rolagem horizontal; texto sobre imagem é conferir, não achado"
        else ko "ui capture: menu fechado fora da tela não é rolagem horizontal; texto sobre imagem é conferir, não achado" "$(jq -c '.screens[0].findings' "$RB" 2>&1 | head -c 500)"; fi
        if jq -e '.screens[1].findings == []' "$RB" >/dev/null 2>&1; then ok "ui capture: rolagem horizontal que some ao recarregar na largura sai do relatório"
        else ko "ui capture: rolagem horizontal que some ao recarregar na largura sai do relatório" "$(jq -c '.screens[1].findings' "$RB" 2>&1 | head -c 400)"; fi
        if jq -e '.screens[2].findings | length == 1 and .[0].rule == "corte-horizontal" and .[0].id == "B2" and .[0].level == "conferir"
            and .[0].widths == "320–820" and (.[0].detail | contains("div.larga (900px)"))' "$RB" >/dev/null 2>&1; then
          ok "ui capture: conteúdo cortado por overflow-x oculto é conferir, com a faixa de larguras"
        else ko "ui capture: conteúdo cortado por overflow-x oculto é conferir, com a faixa de larguras" "$(jq -c '.screens[2].findings' "$RB" 2>&1 | head -c 400)"; fi
        if jq -e '.screens[3] | (.final_url | endswith("/longa")) and any(.warnings[]; contains("redirecionou para"))' "$RB" >/dev/null 2>&1 &&
          grep -qF "/vai/longa → $BASE/longa" <<<"$out"; then
          ok "ui capture: rota redirecionada sai com o destino e um aviso"
        else ko "ui capture: rota redirecionada sai com o destino e um aviso" "$(jq -c '.screens[3] | {final_url, warnings}' "$RB" 2>&1 | head -c 400)"; fi
        if jq -e '.screens[4] | .warnings == [] and .findings == [] and .title == "Pedidos"' "$RB" >/dev/null 2>&1; then
          ok "ui capture: rota que só muda a âncora recarrega a página em vez de esperar o tempo de carga"
        else ko "ui capture: rota que só muda a âncora recarrega a página em vez de esperar o tempo de carga" "$(jq -c '.screens[4] | {warnings, findings}' "$RB" 2>&1 | head -c 400)"; fi

        # Tela sem sondagem nao sai como limpa: exit 5, linha incompleta e contagem no relatorio.
        out="$(KIT_UI_BUDGET_S=0 cap "$E" --name tempo --probe-only --routes / 2>&1)"; code=$?
        if [ "$code" = "5" ] && grep -qF 'incompleta: tempo esgotado' <<<"$out" && grep -qF '1 tela sem sondagem completa' <<<"$out" &&
          ! grep -qF 'sem achados na sondagem' <<<"$out" &&
          jq -e '.totals.incomplete == 1 and (.screens[0].incomplete | startswith("tempo esgotado"))' "$E/.claude/state/ui/tempo/report.json" >/dev/null 2>&1; then
          ok "ui capture: tela que não foi sondada sai como incompleta, com exit 5"
        else ko "ui capture: tela que não foi sondada sai como incompleta, com exit 5" "exit $code, $out"; fi

        # Rotas de mesmo slug nao gravam por cima uma da outra. --out so apaga o que a captura anterior gravou.
        FORA="$UT/fora"
        mkdir -p "$FORA"
        printf 'x\n' >"$FORA/minha.png"
        cap "$E" --name s --out "$(mixed_path "$FORA")" --routes '/grafico?a=1,/grafico?a-1' >/dev/null 2>&1; c1=$?
        RS="$FORA/report.json"
        s_ok=0
        jq -e '([.screens[].images[].file] | length) == 4 and ([.screens[].images[].file] | unique | length) == 4
            and any(.screens[1].images[]; .file == "grafico-a-1-2-360x800-1.png")' "$RS" >/dev/null 2>&1 && [ -s "$FORA/grafico-a-1-360x800-1.png" ] && s_ok=1
        cap "$E" --name s --out "$(mixed_path "$FORA")" --probe-only --routes /grafico >/dev/null 2>&1; c2=$?
        if [ "$c1" = "0" ] && [ "$s_ok" = "1" ]; then ok "ui capture: rotas com o mesmo nome de arquivo ganham sufixo e não se sobrescrevem"
        else ko "ui capture: rotas com o mesmo nome de arquivo ganham sufixo e não se sobrescrevem" "exit $c1, $(jq -c '[.screens[].images[].file]' "$RS" 2>&1 | head -c 400)"; fi
        if [ "$c2" = "0" ] && [ -s "$FORA/minha.png" ] && ! ls "$FORA"/grafico-*.png >/dev/null 2>&1; then
          ok "ui capture --out: apaga só as imagens da captura anterior; arquivo de outra origem fica"
        else ko "ui capture --out: apaga só as imagens da captura anterior; arquivo de outra origem fica" "exit $c2, $(ls "$FORA" | tr '\n' ' ')"; fi

        # App que ja ocupa a porta e demora a responder: a captura espera, nao sobe ui.dev e nao o derruba.
        LPORT="$(free_port)"
        LURL="http://127.0.0.1:$LPORT"
        L="$UT/lento"
        mkdir -p "$L/.claude"
        jq -n --arg url "$LURL" '{ui: {globs: ["**/*.html"], dev: "echo subiu > dev-rodou.txt; sleep 30", url: $url, viewports: ["360x800"]}}' >"$L/.claude/kit.json"
        (cd "$HERE/ui" && FIXTURE_HOLD_MS=6000 exec node server.mjs "$LPORT") >/dev/null 2>&1 &
        lsrv=$!
        for _ in $(seq 1 40); do node -e 'const s = require("net").connect(Number(process.argv[1]), "127.0.0.1"); s.on("connect", () => process.exit(0)); s.on("error", () => process.exit(1));' "$LPORT" && break; sleep 0.1; done
        out="$(cap "$L" --name l --probe-only --routes /grafico 2>&1)"; code=$?
        if [ "$code" = "0" ] && grep -qF 'app já estava rodando' <<<"$out" && [ ! -e "$L/dev-rodou.txt" ] && url_up "$LURL/"; then
          ok "ui capture: app lento que já ocupa a porta é esperado, sem subir ui.dev e sem ser derrubado"
        else ko "ui capture: app lento que já ocupa a porta é esperado, sem subir ui.dev e sem ser derrubado" "exit $code, dev rodou: $([ -e "$L/dev-rodou.txt" ] && echo sim || echo não), $(tail -n 4 <<<"$out")"; fi
        stop_pid "$lsrv"

        # Passos: preparo com login (senha por variavel de ambiente), menu que abre no pointerdown, campo cujo
        # valor so existe com o evento input e Enter que envia. O defeito so existe com o formulario aberto.
        STEPS='{"setup":[{"goto":"/entrar"},{"fill":"text=E-mail","value":"ana@exemplo.test"},{"fill":"text=Senha","value":"${KIT_UI_TESTE_SENHA}"},{"click":"text=Entrar"},{"wait":"text=Minha conta"}],"steps":[{"click":"#abrir-menu"},{"click":"text=Novo pedido"},{"fill":"#cliente","value":"Ana"},{"press":"Enter"},{"wait":"text=Pedido de Ana salvo"}]}'
        out="$(KIT_UI_TESTE_SENHA=abre-te-sesamo cap "$E" --name passos --routes /conta --steps "$STEPS" 2>&1)"; code=$?
        RP="$E/.claude/state/ui/passos/report.json"
        if [ "$code" = "1" ] && grep -qF 'passos: 5 de preparo, 5 por carga' <<<"$out" &&
          jq -e '.steps == {setup: 5, steps: 5} and (.screens[0] | .title == "Minha conta" and (has("final_url") | not) and (has("incomplete") | not)
            and any(.findings[]; .rule == "rolagem-horizontal" and .level == "achado" and (.detail | contains("div.linha (520px)"))))' "$RP" >/dev/null 2>&1; then
          ok "ui capture --steps: login no preparo, menu, campo e Enter levam ao estado, e o defeito que só existe nele é medido"
        else ko "ui capture --steps: login no preparo, menu, campo e Enter levam ao estado, e o defeito que só existe nele é medido" "exit $code, $(tail -n 6 <<<"$out")"; fi
        if [ -s "$E/.claude/state/ui/passos/conta-360x800-1.png" ] && ! grep -qF 'abre-te-sesamo' "$RP" && ! grep -qF 'abre-te-sesamo' <<<"$out"; then
          ok "ui capture --steps: o valor da variável de ambiente não aparece no resumo nem no relatório"
        else ko "ui capture --steps: o valor da variável de ambiente não aparece no resumo nem no relatório" "$(grep -c 'abre-te-sesamo' "$RP" 2>&1)"; fi
        out="$(cap "$E" --name semlogin --probe-only --routes /conta 2>&1)"
        if grep -qF "/conta → $BASE/entrar" <<<"$out" && grep -qF 'redirecionou para' <<<"$out"; then ok "ui capture: a mesma tela sem os passos cai no login e a captura avisa"
        else ko "ui capture: a mesma tela sem os passos cai no login e a captura avisa" "$(tail -n 5 <<<"$out")"; fi
        printf '%s\n' '[{"click": "text=Botão que não existe", "timeout": 1200}]' >"$UT/passos-ruins.json"
        out="$(cap "$E" --name falha --routes /entrar --steps "$UT/passos-ruins.json" 2>&1)"; code=$?
        if [ "$code" = "5" ] && grep -qF 'incompleta: passo 1 (click "text=Botão que não existe") falhou' <<<"$out" &&
          [ -s "$E/.claude/state/ui/falha/entrar-falha-360x800-1.png" ]; then
          ok "ui capture --steps: passo que falha deixa a tela incompleta (exit 5), com o passo e a imagem de onde parou"
        else ko "ui capture --steps: passo que falha deixa a tela incompleta (exit 5), com o passo e a imagem de onde parou" "exit $code, $(tail -n 5 <<<"$out")"; fi
        o1="$(cap "$E" --routes /entrar --steps '[{"fill":"#a","value":"${KIT_UI_VARIAVEL_QUE_NAO_EXISTE}"}]' 2>&1)"; c1=$?
        o2="$(cap "$E" --routes /entrar --steps '[{"clica":"#a"}]' 2>&1)"; c2=$?
        o3="$(cap "$E" --routes /entrar --steps '[{"click":"#a"}]' --attach http://127.0.0.1:9 2>&1)"; c3=$?
        o4="$(cap "$E" --name .. --routes /entrar 2>&1)"; c4=$?
        o5="$(cap "$E" --routes 'file:///etc/passwd' 2>&1)"; c5=$?
        if [ "$c1$c2$c3$c4$c5" = "22222" ] && grep -qF 'KIT_UI_VARIAVEL_QUE_NAO_EXISTE não está definida' <<<"$o1" && grep -qF 'precisa de uma ação só' <<<"$o2" &&
          grep -qF 'não combina com --attach' <<<"$o3" && grep -qF 'começa por letra ou número' <<<"$o4" && grep -qF 'precisa ser um caminho do app' <<<"$o5" &&
          [ ! -e "$E/.claude/state/report.json" ]; then
          ok "ui capture: variável ausente, ação desconhecida, --steps com --attach, nome que sobe de pasta e rota que não é http saem com 2"
        else ko "ui capture: variável ausente, ação desconhecida, --steps com --attach, nome que sobe de pasta e rota que não é http saem com 2" "$c1 $o1 | $c2 $o2 | $c3 $o3 | $c4 $o4 | $c5 $o5"; fi

        # Tema escuro ligado por classe (sem media query), app com o corpo fixo e rolagem num conteiner, e
        # classe .dark que e variante de componente.
        out="$(cap "$E" --name tema --tiles 2 --routes /classe,/painel 2>&1)"; code=$?
        RT="$E/.claude/state/ui/tema/report.json"
        if [ "$code" = "0" ] && grep -qF 'tema claro e escuro (ligado por .dark)' <<<"$out" &&
          jq -e '.screens[0] | .dark == true and .dark_by == ".dark" and (.findings | length) == 2
            and all(.findings[]; .rule == "contraste (tema escuro)" and .level == "conferir")
            and ([.images[] | select(.theme == "escuro")] | length) == 2' "$RT" >/dev/null 2>&1; then
          ok "ui capture: tema escuro ligado por classe é medido, e o contraste dele sai como conferir"
        else ko "ui capture: tema escuro ligado por classe é medido, e o contraste dele sai como conferir" "exit $code, $(jq -c '.screens[0] | {dark, dark_by, findings}' "$RT" 2>&1 | head -c 500)"; fi
        if jq -e '.screens[1] | (has("dark") | not) and .findings == [] and ([.images[] | .parts] | unique) == [2]
            and any(.warnings[]; contains("só as 2 primeiras foram fotografadas"))' "$RT" >/dev/null 2>&1 &&
          ! cmp -s "$E/.claude/state/ui/tema/painel-360x800-1.png" "$E/.claude/state/ui/tema/painel-360x800-2.png"; then
          ok "ui capture: app com o corpo fixo é fotografado rolando o contêiner; .dark de componente não é tema; parte que ficou de fora vira aviso"
        else ko "ui capture: app com o corpo fixo é fotografado rolando o contêiner; .dark de componente não é tema; parte que ficou de fora vira aviso" "$(jq -c '.screens[1] | {dark, findings, warnings, images}' "$RT" 2>&1 | head -c 600)"; fi

        # Pagina que trava a aba: aquela tela fica incompleta e a seguinte abre numa aba nova.
        out="$(KIT_UI_REPLY_S=3 cap "$E" --name trava --probe-only --routes /trava,/grafico 2>&1)"; code=$?
        if [ "$code" = "5" ] && jq -e '(.screens[0].incomplete | startswith("captura interrompida")) and .totals.incomplete == 1
            and (.screens[1] | (has("incomplete") | not) and .findings == [] and .title == "Gráfico")' "$E/.claude/state/ui/trava/report.json" >/dev/null 2>&1; then
          ok "ui capture: página que trava a aba fica incompleta, e a tela seguinte é capturada numa aba nova"
        else ko "ui capture: página que trava a aba fica incompleta, e a tela seguinte é capturada numa aba nova" "exit $code, $(tail -n 8 <<<"$out")"; fi

        # --attach: pagina ja aberta num navegador com porta de depuracao; nao recarrega.
        if [ "$ws" = "1" ]; then
          bpath="$(sed -n 's/^navegador: ok [^(]*(\(.*\))$/\1/p' <<<"$doc")"
          DPORT="$(free_port)"
          sandbox_flag=""
          [ "$TEST_PLATFORM" = "linux" ] && sandbox_flag="--no-sandbox"
          # shellcheck disable=SC2086
          "$bpath" --headless=new "--remote-debugging-port=$DPORT" "--user-data-dir=$(mixed_path "$UT/perfil")" --no-first-run --disable-gpu $sandbox_flag "$BASE/ruim" >/dev/null 2>&1 &
          bpid=$!
          page_open() { node -e 'require("http").get(process.argv[1], (r) => { let b = ""; r.on("data", (c) => (b += c)); r.on("end", () => { try { process.exit(JSON.parse(b).some((t) => t.type === "page" && (t.url || "").endsWith(process.argv[2])) ? 0 : 1); } catch { process.exit(1); } }); }).on("error", () => process.exit(1));' "http://127.0.0.1:$DPORT/json/list" "ruim"; }
          for _ in $(seq 1 60); do page_open && break; sleep 0.3; done
          out="$(cap "$C" --attach "http://127.0.0.1:$DPORT" --match /ruim --name anexo 2>&1)"; code=$?
          RA="$C/.claude/state/ui/anexo/report.json"
          if [ "$code" = "1" ] && grep -qF 'captura: navegador aberto' <<<"$out" && page_open &&
            jq -e '.mode == "navegador aberto" and (.screens[0].images | length) == 4
              and any(.screens[0].findings[]; .rule == "rolagem-horizontal" and .widths == "320–600")
              and any(.screens[0].findings[]; .rule == "sem-nome")' "$RA" >/dev/null 2>&1; then
            ok "ui capture --attach: mesma varredura numa página já aberta, sem recarregar"
          else ko "ui capture --attach: mesma varredura numa página já aberta, sem recarregar" "exit $code, $(tail -n 6 <<<"$out")"; fi
          out="$(cap "$C" --attach "http://127.0.0.1:$DPORT" --match nenhuma-pagina --name anexo2 2>&1)"; code=$?
          if [ "$code" = "3" ] && grep -qF 'nenhuma página com "nenhuma-pagina"' <<<"$out"; then ok "ui capture --attach: sem página que casa sai com 3 e lista as abertas"
          else ko "ui capture --attach: sem página que casa sai com 3 e lista as abertas" "exit $code, $out"; fi
          stop_pid "$bpid"
        else
          echo "  pulado ui capture --attach (node sem WebSocket nativo)"
        fi

        # Sem navegador: exit 3. Config invalida: exit 2.
        out="$(KIT_UI_BROWSER="$UT/nao-existe" cap "$C" 2>&1)"; code=$?
        if [ "$code" = "3" ] && grep -qF 'nenhum navegador Chromium encontrado' <<<"$out"; then ok "ui capture: sem navegador sai com 3"; else ko "ui capture: sem navegador sai com 3" "exit $code, $out"; fi
        stop_pid "$srv"
        V="$UT/inval"
        mkdir -p "$V/.claude"
        printf '%s\n' '{"ui":{"globs":["x"],"url":"http://127.0.0.1:9","viewports":["360"]}}' >"$V/.claude/kit.json"
        o1="$(cap "$V" 2>&1)"; c1=$?
        printf '%s\n' '{"commands":{}}' >"$V/.claude/kit.json"
        o2="$(cap "$V" 2>&1)"; c2=$?
        o3="$(cap "$V" --routes 2>&1)"; c3=$?
        if [ "$c1" = "2" ] && grep -qF 'precisa ser <largura>x<altura>' <<<"$o1" && [ "$c2" = "2" ] && grep -qF 'não tem a chave "ui"' <<<"$o2" &&
          [ "$c3" = "2" ] && grep -qF -- '--routes precisa de um valor' <<<"$o3"; then
          ok "ui capture: viewport inválido, kit.json sem ui e opção sem valor saem com 2"
        else ko "ui capture: viewport inválido, kit.json sem ui e opção sem valor saem com 2" "$c1 $o1 | $c2 $o2 | $c3 $o3"; fi

        # App que nao sobe: exit 4 com o fim do log, e o processo de ui.dev nao fica para tras.
        F="$UT/falha"
        mkdir -p "$F/.claude"
        FURL="http://127.0.0.1:$(free_port)"
        jq -n --arg url "$FURL" '{ui: {globs: ["x"], dev: "echo quebrou a subida; exit 7", url: $url}}' >"$F/.claude/kit.json"
        o1="$(cap "$F" 2>&1)"; c1=$?
        jq -n --arg url "$FURL" '{ui: {globs: ["x"], dev: "echo $$ > dev.pid; sleep 60", url: $url}}' >"$F/.claude/kit.json"
        o2="$(KIT_UI_WAIT_S=2 cap "$F" 2>&1)"; c2=$?
        sleep 1
        alive=0
        kill -0 "$(cat "$F/dev.pid" 2>/dev/null)" 2>/dev/null && alive=1
        jq -n --arg url "$FURL" '{ui: {globs: ["x"], url: $url}}' >"$F/.claude/kit.json"
        o3="$(cap "$F" 2>&1)"; c3=$?
        if [ "$c1" = "4" ] && grep -qF 'terminou (código 7)' <<<"$o1" && grep -qF 'quebrou a subida' <<<"$o1" &&
          [ "$c2" = "4" ] && grep -qF 'não respondeu em 2s' <<<"$o2" && [ "$alive" = "0" ] &&
          [ "$c3" = "4" ] && grep -qF 'não tem ui.dev' <<<"$o3"; then
          ok "ui capture: app que falha, não responde ou não tem ui.dev sai com 4, sem processo para trás"
        else ko "ui capture: app que falha, não responde ou não tem ui.dev sai com 4, sem processo para trás" "$c1 $o1 | $c2 $o2 vivo=$alive | $c3 $o3"; fi

        # ui.screenshot: a captura e o comando do projeto, sem sondagem.
        K="$UT/cmd"
        mkdir -p "$K/.claude"
        png="$(mixed_path "$C/.claude/state/ui/t/raiz-360x800-1.png")"
        jq -n --arg c "cp '$png' {out}" '{ui: {globs: ["lib/**"], screenshot: $c, routes: ["inicio", "perfil"]}}' >"$K/.claude/kit.json"
        o1="$(cap "$K" --name c 2>&1)"; c1=$?
        o2="$(cap "$K" --name c2 --probe-only 2>&1)"; c2=$?
        jq -n '{ui: {globs: ["lib/**"], screenshot: "echo sem simulador >&2; exit 1 # {out}", routes: ["inicio"]}}' >"$K/.claude/kit.json"
        o3="$(cap "$K" --name c3 2>&1)"; c3=$?
        if [ "$c1" = "0" ] && grep -qF 'captura: comando' <<<"$o1" && grep -qF 'sem sondagem' <<<"$o1" &&
          [ -s "$K/.claude/state/ui/c/inicio-1.png" ] && [ -s "$K/.claude/state/ui/c/perfil-1.png" ] &&
          [ "$c2" = "3" ] && [ "$c3" = "3" ] && grep -qF 'ui.screenshot não gravou inicio-1.png: sem simulador' <<<"$o3"; then
          ok "ui capture: ui.screenshot grava uma imagem por tela, sem sondagem; comando que falha sai com 3"
        else ko "ui capture: ui.screenshot grava uma imagem por tela, sem sondagem; comando que falha sai com 3" "$c1 $o1 | $c2 $o2 | $c3 $o3"; fi
        # {out} com aspas em volta, {route} com espaco e os mesmos valores nas variaveis KIT_UI_*.
        jq -n --arg c "cp '$png' \"{out}\" && printf '%s' {route} >rota.txt && printf '%s' \"\$KIT_UI_ROUTE\" >rota-env.txt" \
          '{ui: {globs: ["lib/**"], screenshot: $c, routes: ["a b"]}}' >"$K/.claude/kit.json"
        o4="$(cap "$K" --name c4 2>&1)"; c4=$?
        o5="$(cap "$K" --name c5 --steps '[{"click":"#a"}]' 2>&1)"; c5=$?
        if [ "$c4" = "0" ] && [ -s "$K/.claude/state/ui/c4/a-b-1.png" ] && [ "$(cat "$K/rota.txt" 2>/dev/null)" = "a b" ] && [ "$(cat "$K/rota-env.txt" 2>/dev/null)" = "a b" ] &&
          [ "$c5" = "2" ] && grep -qF 'não para o comando ui.screenshot' <<<"$o5"; then
          ok "ui capture: ui.screenshot com {out} entre aspas, {route} e as variáveis KIT_UI_*; --steps não vale para o comando"
        else ko "ui capture: ui.screenshot com {out} entre aspas, {route} e as variáveis KIT_UI_*; --steps não vale para o comando" "$c4 $o4 | $c5 $o5 | rota='$(cat "$K/rota.txt" 2>&1)'"; fi
      fi
    fi
  fi
fi
}

g_guardas() {
echo "guardas e gate: casos de sistema de arquivos"
if [ -z "$FILTER" ] || [[ "guardas" == *"$FILTER"* ]]; then
  # Erro inesperado num guarda bloqueia (exit 2), nunca libera.
  out="$("$TBASH" -c '. "$1/lib.sh"; kit_guard_fail_closed; set -u; echo "$KIT_VARIAVEL_INEXISTENTE"' _ "$SCRIPTS" 2>"$TMP_ALL/fc.err")"; code=$?
  if [ "$code" = "2" ] && grep -q 'erro interno no guarda' "$TMP_ALL/fc.err"; then ok "guardas: variavel nao definida bloqueia com exit 2"
  else ko "guardas: variavel nao definida bloqueia com exit 2" "exit $code, stderr=$(head -c 200 "$TMP_ALL/fc.err")"; fi
  out="$("$TBASH" -c '. "$1/lib.sh"; kit_guard_fail_closed; false; exit 1' _ "$SCRIPTS" 2>/dev/null)"; code=$?
  [ "$code" = "2" ] && ok "guardas: exit 1 inesperado vira exit 2" || ko "guardas: exit 1 inesperado vira exit 2" "exit $code"

  # Symlink: o alvo final tambem e checado.
  G="$(mktemp -d "$TMP_ALL/sym.XXXXXX")"
  mkdir -p "$G/p/.claude" "$G/p/src"
  printf '{"protected_paths":["**/Migrations/**"]}\n' >"$G/p/.claude/kit.json"
  printf 'X=1\n' >"$G/p/.env"
  git_q init "$G/p"
  if MSYS=winsymlinks:nativestrict ln -s "$G/p/.env" "$G/p/src/config.txt" 2>/dev/null && [ -L "$G/p/src/config.txt" ]; then
    out="$(jq -cn --arg f "$(native_path "$G/p/src/config.txt")" --arg d "$(native_path "$G/p")" \
      '{tool_name: "Edit", tool_input: {file_path: $f}, cwd: $d}' | "$TBASH" "$SCRIPTS/guard-files.sh" 2>&1)"
    if jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null 2>&1; then ok "guard-files: symlink para .env negado"
    else ko "guard-files: symlink para .env negado" "$out"; fi
  else
    echo "  pulado guard-files: symlink (sistema sem symlink de verdade)"
  fi

  # cwd em nome curto 8.3 (TEMP do runner do GitHub: C:\Users\RUNNER~1): a raiz do kit e a mesma pasta.
  if command -v cygpath >/dev/null 2>&1; then
    G="$TMP_ALL/pasta com nome longo do kit"
    mkdir -p "$G/.claude" "$G/src/views"
    printf '%s\n' '{"source_globs":["src/**"],"coupled_changes":[{"when":["src/views/**"],"require":["manual/**"],"level":"block","message":"Telas mudaram."}]}' >"$G/.claude/kit.json"
    git_q init "$G"; git_q -C "$G" add -A; git_q -C "$G" commit -m init
    printf 'x\n' >"$G/src/views/home.ts"
    short="$(cygpath -w -s "$G")"
    if [ "$short" != "$(cygpath -w "$G")" ]; then
      jq -cn --arg d "$short" '{cwd: $d, session_id: "curto"}' | TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" >/dev/null 2>"$TMP_ALL/curto.err"; code=$?
      if [ "$code" = "2" ] && grep -qF '1) [coupled_changes] Telas mudaram.' "$TMP_ALL/curto.err"; then ok "verify-gate: cwd em nome curto 8.3 é a mesma raiz do kit"
      else ko "verify-gate: cwd em nome curto 8.3 é a mesma raiz do kit" "exit $code, $(head -c 300 "$TMP_ALL/curto.err")"; fi
    else
      echo "  pulado verify-gate com cwd 8.3 (volume sem nomes curtos)"
    fi
  fi

  # TEMP com espaco e ~ (usuario "Joao Silva", C:\Users\RUNNER~1): o advise avisa uma vez so, sem erro.
  G="$TMP_ALL/adv"
  mkdir -p "$G/.claude" "$G/src/api" "$TMP_ALL/temp de Joao~1"
  printf '%s\n' '{"coupled_changes":[{"when":["src/api/**"],"require":["web/**"],"level":"warn","message":"Ajuste o site."}]}' >"$G/.claude/kit.json"
  printf 'x\n' >"$G/src/api/a.ts"
  git_q init "$G"
  adv_in="$(jq -cn --arg f "$(native_path "$G/src/api/a.ts")" --arg d "$(native_path "$G")" \
    '{hook_event_name: "PostToolUse", session_id: "temp-espaco", tool_name: "Edit", tool_input: {file_path: $f}, cwd: $d}')"
  out1="$(TMPDIR="$TMP_ALL/temp de Joao~1" "$TBASH" "$SCRIPTS/advise.sh" <<<"$adv_in" 2>"$TMP_ALL/adv.err")"
  out2="$(TMPDIR="$TMP_ALL/temp de Joao~1" "$TBASH" "$SCRIPTS/advise.sh" <<<"$adv_in" 2>>"$TMP_ALL/adv.err")"
  if grep -qF 'Ajuste o site.' <<<"$out1" && [ -z "$out2" ] && [ ! -s "$TMP_ALL/adv.err" ]; then ok "advise: TEMP com espaço e ~ avisa uma vez só, sem erro"
  else ko "advise: TEMP com espaço e ~ avisa uma vez só, sem erro" "1='$out1' 2='$out2' err='$(head -c 300 "$TMP_ALL/adv.err")'"; fi

  # advise com diff_deny warn: a mesma linha deslocada por uma edicao acima nao avisa de novo; uma
  # segunda linha com o padrao avisa.
  G="$TMP_ALL/adv-dd"
  mkdir -p "$G/.claude" "$G/src"
  printf '%s\n' '{"diff_deny":[{"pattern":"@ts-ignore","files":["**/*.ts"],"level":"warn","message":"Supressão nova."}]}' >"$G/.claude/kit.json"
  printf 'const a = 1;\n' >"$G/src/a.ts"
  git_q init "$G"; git_q -C "$G" add -A; git_q -C "$G" commit -m init
  adv_in="$(jq -cn --arg f "$(native_path "$G/src/a.ts")" --arg d "$(native_path "$G")" \
    '{hook_event_name: "PostToolUse", session_id: "adv-dd", tool_name: "Edit", tool_input: {file_path: $f}, cwd: $d}')"
  printf 'const a = 1;\n// @ts-ignore\n' >"$G/src/a.ts"
  out1="$(TMPDIR="$TMP_ALL" "$TBASH" "$SCRIPTS/advise.sh" <<<"$adv_in" 2>"$TMP_ALL/adv-dd.err")"
  printf 'const z = 0;\nconst a = 1;\n// @ts-ignore\n' >"$G/src/a.ts"
  out2="$(TMPDIR="$TMP_ALL" "$TBASH" "$SCRIPTS/advise.sh" <<<"$adv_in" 2>>"$TMP_ALL/adv-dd.err")"
  printf 'const z = 0;\nconst a = 1;\n// @ts-ignore\nconst b = 2;\n// @ts-ignore\n' >"$G/src/a.ts"
  out3="$(TMPDIR="$TMP_ALL" "$TBASH" "$SCRIPTS/advise.sh" <<<"$adv_in" 2>>"$TMP_ALL/adv-dd.err")"
  if grep -qF 'linhas novas: 2"' <<<"$out1" && [ -z "$out2" ] && grep -qF 'linhas novas: 3, 5"' <<<"$out3" && [ ! -s "$TMP_ALL/adv-dd.err" ]; then
    ok "advise: diff_deny warn não repete a linha deslocada e avisa a segunda"
  else ko "advise: diff_deny warn não repete a linha deslocada e avisa a segunda" "1='$out1' 2='$out2' 3='$out3' err='$(head -c 300 "$TMP_ALL/adv-dd.err")'"; fi

  # verify-gate com 2000 arquivos nao rastreados: uma chamada de kit_kit_roots por pasta e
  # source_globs lido uma vez. Nome com & e apostrofo chega intacto no {files}.
  G="$(mktemp -d "$TMP_ALL/big.XXXXXX")"
  mkdir -p "$G/.claude"
  printf '%s\n' '{"commands":{"test":"printf \"%s\\n\" {files} > out.txt"},"source_globs":["src/**/*.ts"],"verify_on_stop":["test"],"coupled_changes":[{"when":["src/api/**"],"require":["docs/api.md"],"level":"block"}]}' >"$G/.claude/kit.json"
  git_q init "$G"; git_q -C "$G" add -A; git_q -C "$G" commit -m init
  for d in $(seq 1 40); do mkdir -p "$G/src/m$d"; for f in $(seq 1 50); do : >"$G/src/m$d/f$f.ts"; done; done
  mkdir -p "$G/src/a&b"; : >"$G/src/a&b/x&y.ts"; : >"$G/src/it's.ts"
  t0="$(date +%s)"
  jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "grande"}' | TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" >/dev/null 2>"$TMP_ALL/big.err"; code=$?
  t1="$(date +%s)"
  if [ "$code" = "0" ] && [ "$(wc -l <"$G/out.txt" | tr -d ' ')" = "2002" ] && grep -qxF 'src/a&b/x&y.ts' "$G/out.txt" && grep -qxF "src/it's.ts" "$G/out.txt"; then
    ok "verify-gate: 2002 arquivos, & e apostrofo no {files} ($((t1 - t0))s)"
  else ko "verify-gate: 2002 arquivos, & e apostrofo no {files}" "exit $code, $(wc -l <"$G/out.txt" 2>/dev/null) linhas, $(head -c 300 "$TMP_ALL/big.err")"; fi
  [ "$((t1 - t0))" -le 30 ] && ok "verify-gate: 2002 arquivos em ate 30s ($((t1 - t0))s)" || ko "verify-gate: 2002 arquivos em ate 30s" "$((t1 - t0))s"

  # guard-files com 300 entradas em protected_paths: o casamento por regra nao cria processo, entao
  # o tempo nao cresce com a lista (no Git Bash, um processo por entrada estourava o limite do hook).
  G="$(mktemp -d "$TMP_ALL/pp.XXXXXX")"
  mkdir -p "$G/.claude" "$G/db/migrations" "$G/src"
  { printf '{"protected_paths":['
    for f in $(seq 1 300); do [ "$f" -gt 1 ] && printf ','; printf '{"glob":"db/migrations/%04d_*.sql","message":"Migração aplicada."}' "$f"; done
    printf ']}\n'; } >"$G/.claude/kit.json"
  printf 'x\n' >"$G/src/a.ts"; printf 'x\n' >"$G/db/migrations/0300_fim.sql"
  git_q init "$G"
  pp_in() { jq -cn --arg f "$(native_path "$G/$1")" --arg d "$(native_path "$G")" '{tool_name: "Edit", tool_input: {file_path: $f}, cwd: $d}'; }
  t0="$(date +%s)"
  out1="$(pp_in src/a.ts | "$TBASH" "$SCRIPTS/guard-files.sh" 2>&1)"; code=$?
  out2="$(pp_in db/migrations/0300_fim.sql | "$TBASH" "$SCRIPTS/guard-files.sh" 2>&1)"
  t1="$(date +%s)"
  if [ "$code" = "0" ] && [ -z "$out1" ] && jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("db/migrations/0300_fim.sql é protegido. Migração aplicada."))' <<<"$out2" >/dev/null 2>&1; then
    ok "guard-files: 300 protected_paths, libera o que não casa e nega a última entrada"
  else ko "guard-files: 300 protected_paths, libera o que não casa e nega a última entrada" "exit $code, 1='$(head -c 200 <<<"$out1")' 2='$(head -c 300 <<<"$out2")'"; fi
  [ "$((t1 - t0))" -le 10 ] && ok "guard-files: 300 protected_paths, duas chamadas em ate 10s ($((t1 - t0))s)" || ko "guard-files: 300 protected_paths, duas chamadas em ate 10s" "$((t1 - t0))s"

  # diff_deny com 500 arquivos rastreados alterados: a lista de caminhos passa de 32 mil caracteres
  # (limite da linha de comando do git.exe no Windows) e vai em lotes. Supressao antiga nao bloqueia
  # e a nova sai com o arquivo e a linha certos.
  G="$(mktemp -d "$TMP_ALL/lote.XXXXXX")"
  ld="src/componente-com-nome-comprido-para-encher-a-linha-de-comando"
  mkdir -p "$G/.claude" "$G/$ld"
  printf '%s\n' '{"diff_deny":[{"pattern":"@ts-ignore","files":["**/*.ts"],"message":"Supressão nova."}]}' >"$G/.claude/kit.json"
  for f in $(seq 1 500); do printf '// @ts-ignore antigo\n' >"$G/$ld/arquivo-$f.ts"; done
  git_q init "$G"; git_q -C "$G" add -A; git_q -C "$G" commit -m init
  for f in $(seq 1 500); do printf 'const x = 1;\n' >>"$G/$ld/arquivo-$f.ts"; done
  lote_in="$(jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "lote"}')"
  TMPDIR="$TMP_ALL" "$TBASH" "$SCRIPTS/verify-gate.sh" <<<"$lote_in" >/dev/null 2>"$TMP_ALL/lote.err"; code=$?
  if [ "$code" = "0" ]; then ok "diff_deny: 500 arquivos alterados, supressão antiga não bloqueia"
  else ko "diff_deny: 500 arquivos alterados, supressão antiga não bloqueia" "exit $code, $(head -c 300 "$TMP_ALL/lote.err")"; fi
  printf '// @ts-ignore\n' >>"$G/$ld/arquivo-500.ts"
  TMPDIR="$TMP_ALL" "$TBASH" "$SCRIPTS/verify-gate.sh" <<<"$lote_in" >/dev/null 2>"$TMP_ALL/lote.err"; code=$?
  if [ "$code" = "2" ] && grep -qF "  $ld/arquivo-500.ts:3: // @ts-ignore" "$TMP_ALL/lote.err" && [ "$(grep -c 'arquivo-[0-9]*\.ts:' "$TMP_ALL/lote.err")" = "1" ]; then
    ok "diff_deny: 500 arquivos alterados, supressão nova bloqueia com arquivo e linha"
  else ko "diff_deny: 500 arquivos alterados, supressão nova bloqueia com arquivo e linha" "exit $code, $(head -c 300 "$TMP_ALL/lote.err")"; fi

  # Entrada vazia ou JSON truncado: os guardas bloqueiam (exit 2), nunca liberam.
  in_bad=""
  for gs in guard-bash.sh guard-pwsh.sh guard-files.sh; do
    printf '' | "$TBASH" "$SCRIPTS/$gs" >/dev/null 2>&1; code=$?
    [ "$code" = "2" ] || in_bad+="$gs vazio=$code "
    printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /' | "$TBASH" "$SCRIPTS/$gs" >/dev/null 2>&1; code=$?
    [ "$code" = "2" ] || in_bad+="$gs truncado=$code "
  done
  [ -z "$in_bad" ] && ok "guardas: entrada vazia ou truncada bloqueia com exit 2" || ko "guardas: entrada vazia ou truncada bloqueia com exit 2" "$in_bad"

  # Git Bash: /c/... dentro do projeto e o mesmo caminho que C:/...; fora do projeto continua negado.
  if [ "$TEST_PLATFORM" = "windows" ]; then
    G="$(mktemp -d "$TMP_ALL/msys.XXXXXX")"
    mkdir -p "$G/p/build"
    np="$(native_path "$G/p")"
    msys="/$(printf '%s' "${np:0:1}" | tr 'A-Z' 'a-z')${np:2}"
    gb() { jq -cn --arg c "$1" --arg d "$np" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' | env -u CLAUDE_PROJECT_DIR "$TBASH" "$SCRIPTS/guard-bash.sh" 2>/dev/null; }
    o1="$(gb "rm -rf $msys/build")"
    o2="$(gb "cd $msys/build && rm -rf ../build")"
    o3="$(gb "rm -rf /c/Windows/Temp/kit-x")"
    if [ -z "$o1" ] && [ -z "$o2" ] && grep -qF '"deny"' <<<"$o3"; then ok "guard-bash: caminho /c/... dentro do projeto liberado, fora negado"
    else ko "guard-bash: caminho /c/... dentro do projeto liberado, fora negado" "1='$o1' 2='$o2' 3='$o3'"; fi
  fi

  # Stamp do gate: arquivo nao rastreado fora de source_globs muda o estado e o gate roda de novo.
  G="$(mktemp -d "$TMP_ALL/stamp.XXXXXX")"
  mkdir -p "$G/.claude" "$G/src"
  printf '%s\n' '{"commands":{"t":"test ! -e broken.json"},"verify_on_stop":["t"],"source_globs":["src/**"]}' >"$G/.claude/kit.json"
  git_q init "$G"; git_q -C "$G" add -A; git_q -C "$G" commit -m init
  printf 'x\n' >"$G/src/a.ts"
  gin="$(jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "stamp"}')"
  TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" <<<"$gin" >/dev/null 2>&1; c1=$?
  printf '{}\n' >"$G/broken.json"
  TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" <<<"$gin" >/dev/null 2>&1; c2=$?
  if [ "$c1" = "0" ] && [ "$c2" = "2" ]; then ok "verify-gate: não rastreado fora de source_globs invalida o stamp"
  else ko "verify-gate: não rastreado fora de source_globs invalida o stamp" "1=$c1 2=$c2"; fi

  # Commit feito dentro do turno: o gate compara com o HEAD gravado no UserPromptSubmit da mesma sessao.
  G="$(mktemp -d "$TMP_ALL/turno.XXXXXX")"
  mkdir -p "$G/.claude" "$G/src"
  printf '%s\n' '{"commands":{"t":"false"},"verify_on_stop":["t"],"source_globs":["src/**"]}' >"$G/.claude/kit.json"
  printf 'x\n' >"$G/src/a.ts"
  git_q init "$G"; git_q -C "$G" add -A; git_q -C "$G" commit -m init
  jq -cn --arg d "$(native_path "$G")" '{hook_event_name: "UserPromptSubmit", cwd: $d, session_id: "turno"}' |
    TMPDIR="$G" "$TBASH" "$SCRIPTS/session-context.sh" --plan-only >/dev/null 2>&1
  printf 'y\n' >>"$G/src/a.ts"
  git_q -C "$G" commit -am mudou
  jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "turno"}' | TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" >/dev/null 2>&1; c1=$?
  jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "outra"}' | TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" >/dev/null 2>&1; c2=$?
  if [ "$c1" = "2" ] && [ "$c2" = "0" ]; then ok "verify-gate: commit dentro do turno é verificado; marca de outra sessão é ignorada"
  else ko "verify-gate: commit dentro do turno é verificado; marca de outra sessão é ignorada" "mesma=$c1 outra=$c2"; fi

  # diff_deny: linha commitada dentro do turno conta; linha de antes do turno, nao.
  G="$(mktemp -d "$TMP_ALL/ddturno.XXXXXX")"
  mkdir -p "$G/.claude" "$G/src"
  printf '%s\n' '{"diff_deny":[{"pattern":"^proibido","message":"Linha proibida."}]}' >"$G/.claude/kit.json"
  printf 'proibido antigo\n' >"$G/src/a.ts"
  git_q init "$G"; git_q -C "$G" add -A; git_q -C "$G" commit -m init
  jq -cn --arg d "$(native_path "$G")" '{hook_event_name: "UserPromptSubmit", cwd: $d, session_id: "turno"}' |
    TMPDIR="$G" "$TBASH" "$SCRIPTS/session-context.sh" --plan-only >/dev/null 2>&1
  printf 'proibido novo\n' >>"$G/src/a.ts"
  git_q -C "$G" commit -am mudou
  e1="$(jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "turno"}' | TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" 2>&1 >/dev/null)"; c1=$?
  jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "outra"}' | TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" >/dev/null 2>&1; c2=$?
  if [ "$c1" = "2" ] && [ "$c2" = "0" ] && grep -qF 'src/a.ts:2: proibido novo' <<<"$e1" && ! grep -qF 'src/a.ts:1:' <<<"$e1"; then
    ok "verify-gate: diff_deny conta linha commitada no turno e ignora a de antes"
  else ko "verify-gate: diff_deny conta linha commitada no turno e ignora a de antes" "mesma=$c1 outra=$c2 $e1"; fi

  # Repositorio criado durante a sessao entra no gate (o cache de kit_repos e refeito no Stop).
  G="$(mktemp -d "$TMP_ALL/novo.XXXXXX")"
  mkdir -p "$G/.claude" "$G/api"
  printf '%s\n' '{"commands":{"t":"false"},"verify_on_stop":["t"],"source_globs":["**/*.ts"]}' >"$G/.claude/kit.json"
  printf 'x\n' >"$G/api/a.ts"
  git_q init "$G/api"; git_q -C "$G/api" add -A; git_q -C "$G/api" commit -m init
  gin="$(jq -cn --arg d "$(native_path "$G")" '{cwd: $d, session_id: "novo"}')"
  TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" <<<"$gin" >/dev/null 2>&1; c1=$?
  mkdir -p "$G/web"; git_q init "$G/web"; printf 'x\n' >"$G/web/b.ts"
  TMPDIR="$G" "$TBASH" "$SCRIPTS/verify-gate.sh" <<<"$gin" >/dev/null 2>&1; c2=$?
  if [ "$c1" = "0" ] && [ "$c2" = "2" ]; then ok "verify-gate: repositório criado na sessão entra na verificação"
  else ko "verify-gate: repositório criado na sessão entra na verificação" "antes=$c1 depois=$c2"; fi

  # ts-lsp: sem o comando de medicao de memoria, o guard avisa uma vez no stderr e segue repassando.
  if command -v node >/dev/null 2>&1; then
    GD="$(mktemp -d "$TMP_ALL/tsmed.XXXXXX")"
    mkdir -p "$GD/vazio"
    printf '%s\n' "process.stdin.on('data', () => {}); process.stdin.on('end', () => process.exit(0));" >"$GD/fake.cjs"
    out="$(timeout 20 env PATH="$GD/vazio" KIT_TS_LSP_SERVER="$GD/fake.cjs" KIT_TS_LSP_INTERVAL_S=1 "$(command -v node)" "$REPO/plugins/ts-lsp/scripts/guard.mjs" 2>&1 >/dev/null < <(sleep 4))"; code=$?
    if [ "$code" = "0" ] && [ "$(grep -c 'não consegui medir a memória' <<<"$out")" = "1" ]; then ok "ts-lsp guard: sem medição de memória avisa uma vez e segue"
    else ko "ts-lsp guard: sem medição de memória avisa uma vez e segue" "exit $code, $out"; fi
  fi
fi
}

g_estaticas() {
echo "checagens estaticas"
if [ -z "$FILTER" ]; then
  stack_hits="$(grep -nE '(^|[^a-z_.-])(dotnet|npm|npx|pnpm|yarn|pytest|uv run|pip|poetry|cargo|mvn|gradlew?|go (build|test|vet)|golangci-lint|ruff|prettier|eslint|tsc)([^a-z_-]|$)' "$SCRIPTS"/*.sh || true)"
  if [ -z "$stack_hits" ]; then ok "nenhum script referencia comando de stack"; else ko "nenhum script referencia comando de stack" "$stack_hits"; fi

  # O relatorio do init nao manda o usuario fazer nada; extras opcionais ficam no README.
  INIT_MD="$REPO/plugins/kit/skills/init/SKILL.md"
  init_bad="$(grep -nE 'run-skill-generator|/verify|instalar LSP|plugin LSP oficial da linguagem \(ver|kit-settings\.suggested|sugest' "$INIT_MD" || true)"
  if [ -z "$init_bad" ] && grep -qF 'Pronto. Próximo: /kit:spec <ideia>' "$INIT_MD" && grep -qF 'no máximo ~10 linhas' "$INIT_MD" &&
    grep -qF 'setup.sh" plans' "$INIT_MD" && grep -qF 'merge-json.sh" --apply' "$INIT_MD"; then
    ok "init: relatório curto termina no /kit:spec, sem tarefa para o usuário"
  else ko "init: relatório curto termina no /kit:spec, sem tarefa para o usuário" "$init_bad"; fi
  # Modo do zero: o init aponta para o new.md, que entrevista, cria o esqueleto e volta aos passos.
  NEW_MD="$REPO/plugins/kit/skills/init/new.md"
  zero_bad=""
  grep -qF '**modo do zero**' "$INIT_MD" && grep -qF '[new.md](new.md)' "$INIT_MD" || zero_bad+="init:modo "
  tr -d '\r' <"$INIT_MD" | grep -q '^allowed-tools:.* Bash(git init) ' || zero_bad+="init:git-init "
  for want in 'AskUserQuestion' 'Criar o esqueleto com isso?' 'Stack, como conjunto' 'git init' 'Nunca escreva número de versão de memória' \
    'Nenhuma feature do app' 'o kit nunca commita' 'Passos 1 a 12 do SKILL.md'; do
    grep -qF -- "$want" "$NEW_MD" 2>/dev/null || zero_bad+="new:'$want' "
  done
  grep -qF 'modo do zero' "$REPO/README.md" && grep -qF '## Modo do zero' "$REPO/docs/reference.md" || zero_bad+="docs "
  if [ -z "$zero_bad" ]; then ok "init: modo do zero entrevista, cria o esqueleto sem commit e volta aos passos"
  else ko "init: modo do zero entrevista, cria o esqueleto sem commit e volta aos passos" "$zero_bad"; fi
  readme_adv="$(awk '/^## Avançado \(opcional\)/ { on = 1; next } on && /^## / { on = 0 } on' "$REPO/README.md")"
  if grep -qF '/run-skill-generator' <<<"$readme_adv" && grep -qF '/verify' <<<"$readme_adv" &&
    [ "$(grep -c 'run-skill-generator' "$REPO/README.md")" = "$(grep -c 'run-skill-generator' <<<"$readme_adv")" ]; then
    ok "README: /run-skill-generator e /verify só em Avançado (opcional)"
  else ko "README: /run-skill-generator e /verify só em Avançado (opcional)" "$(grep -n 'run-skill-generator\|/verify' "$REPO/README.md")"; fi
  # Limites do kit num lugar so: secao Modelo de ameaca, apontada pelos Guardas.
  tm_bad=""
  readme_tm="$(awk '/^## Modelo de ameaça$/ { on = 1; next } on && /^## / { on = 0 } on' "$REPO/README.md")"
  for want in '**Protege:**' '**Não protege:**' '**Camadas por plataforma:**' '**Recomendações:**' 'Windows nativo' 'docs/reference.md#hooks'; do
    grep -qF -- "$want" <<<"$readme_tm" || tm_bad+="'$want' "
  done
  readme_auto="$(awk '/^## O que o kit faz sozinho$/ { on = 1; next } on && /^## / { on = 0 } on' "$REPO/README.md")"
  grep -qF '[Modelo de ameaça](#modelo-de-ameaça)' <<<"$readme_auto" || tm_bad+="link-guardas "
  grep -qxF '## Hooks' "$REPO/docs/reference.md" || tm_bad+="reference:hooks "
  if [ -z "$tm_bad" ]; then ok "README: modelo de ameaça com protege, não protege, camadas e recomendações"
  else ko "README: modelo de ameaça com protege, não protege, camadas e recomendações" "$tm_bad"; fi
  manual="$(grep -rnE 'kit-settings\.suggested|merge-json\.sh --additions|aplique a sugestão|aplica se quiser|Mescle .*user-settings' \
    "$REPO/README.md" "$REPO/CONTRIBUTING.md" "$REPO/docs" "$REPO/plugins/kit" || true)"
  if [ -z "$manual" ]; then ok "nenhum resto do fluxo de sugestão (kit-settings.suggested) em docs, skills e scripts"; else ko "nenhum resto do fluxo de sugestão" "$manual"; fi
  # A tabela LSP do stacks.md tem os mesmos plugins e binarios do templates/lsp-plugins.txt.
  lsp_tpl="$(tr -d '\r' <"$REPO/plugins/kit/templates/lsp-plugins.txt" | awk -F"|" 'NF { p = $1; if (p !~ /@/) p = p "@claude-plugins-official"; print p " " $2 }' | sort)"
  lsp_doc="$(tr -d '\r' <"$REPO/plugins/kit/skills/init/stacks.md" | awk -F'|' '/^## / { lsp = ($0 == "## Plugin LSP") } lsp && NF > 5 && $4 ~ /@/ { p = $4; b = $5; gsub(/[ `]/, "", p); gsub(/[ `]/, "", b); print p " " b }' | sort)"
  if [ -n "$lsp_tpl" ] && [ "$lsp_tpl" = "$lsp_doc" ]; then ok "stacks.md: tabela LSP igual a templates/lsp-plugins.txt"
  else ko "stacks.md: tabela LSP igual a templates/lsp-plugins.txt" "$(diff <(printf '%s\n' "$lsp_tpl") <(printf '%s\n' "$lsp_doc") | tr '\n' ' ')"; fi
  lsp_marketplace="${HOME}/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json"
  if [ -f "$lsp_marketplace" ]; then
    lsp_missing=""
    while IFS='|' read -r plugin bin _; do
      [ -n "$plugin" ] || continue
      case "$plugin" in *@*) continue ;; esac
      jq -e --arg n "$plugin" --arg b "$bin" '[.plugins[] | select(.name == $n) | .lspServers[]?.command] | index($b) != null' "$lsp_marketplace" >/dev/null 2>&1 || lsp_missing+="$plugin/$bin "
    done < <(tr -d '\r' <"$REPO/plugins/kit/templates/lsp-plugins.txt")
    if [ -z "$lsp_missing" ]; then ok "lsp-plugins.txt: nomes e binários conferem com o marketplace oficial instalado"; else ko "lsp-plugins.txt: nomes e binários conferem com o marketplace oficial" "$lsp_missing"; fi
  else
    echo "  pulado conferência com o marketplace oficial (não instalado)"
  fi

  # ts-lsp: publicado no marketplace, guard com teto de heap; o guard repassa o stdio e mata a arvore acima do limite.
  TSL="$REPO/plugins/ts-lsp"
  if jq -e '.plugins[] | select(.name == "ts-lsp" and .source == "./plugins/ts-lsp")' "$REPO/.claude-plugin/marketplace.json" >/dev/null 2>&1 &&
    jq -e '.lspServers.typescript | .command == "node" and .args == ["${CLAUDE_PLUGIN_ROOT}/scripts/guard.mjs"] and .initializationOptions.maxTsServerMemory > 0 and .restartOnCrash == true' "$TSL/.claude-plugin/plugin.json" >/dev/null 2>&1 &&
    [ -f "$TSL/scripts/guard.mjs" ]; then ok "ts-lsp: no marketplace, guard.mjs como servidor e heap do tsserver limitado"
  else ko "ts-lsp: no marketplace, guard.mjs como servidor e heap do tsserver limitado" "$(jq -c '.lspServers' "$TSL/.claude-plugin/plugin.json" 2>&1)"; fi
  if command -v node >/dev/null 2>&1; then
    GD="$(mktemp -d "$TMP_ALL/tslsp.XXXXXX")"
    printf '%s\n' "const keep = []; for (let i = 0; i < Number(process.env.FAKE_MB || 0); i++) keep.push(Buffer.alloc(1048576, 1));" \
      "require('fs').writeFileSync(process.env.FAKE_PID, String(process.pid));" \
      "process.stdin.on('data', (d) => process.stdout.write('eco:' + d)); process.stdin.on('end', () => process.exit(0));" >"$GD/fake.cjs"
    out="$(printf 'oi' | KIT_TS_LSP_SERVER="$GD/fake.cjs" FAKE_PID="$GD/p1" timeout 20 node "$TSL/scripts/guard.mjs" 2>&1)"; code=$?
    if [ "$code" = "0" ] && [ "$out" = "eco:oi" ]; then ok "ts-lsp guard: repassa stdin e stdout do servidor"; else ko "ts-lsp guard: repassa stdin e stdout do servidor" "exit $code, $out"; fi
    out="$(KIT_TS_LSP_SERVER="$GD/fake.cjs" FAKE_PID="$GD/p2" FAKE_MB=300 KIT_TS_LSP_MAX_MB=150 KIT_TS_LSP_INTERVAL_S=1 timeout 40 node "$TSL/scripts/guard.mjs" 2>&1 < <(sleep 30))"; code=$?
    sleep 1
    gpid="$(cat "$GD/p2" 2>/dev/null)"; alive=0
    case "$(uname -s)" in
      MINGW* | MSYS* | CYGWIN*) tasklist //FI "PID eq $gpid" 2>/dev/null | grep -q node && alive=1 ;;
      *) kill -0 "$gpid" 2>/dev/null && alive=1 ;;
    esac
    if [ "$code" = "1" ] && [ -n "$gpid" ] && [ "$alive" = "0" ] && grep -qF '(limite 150 MB); reiniciando' <<<"$out"; then
      ok "ts-lsp guard: acima do limite mata o servidor e sai com 1"
    else ko "ts-lsp guard: acima do limite mata o servidor e sai com 1" "exit $code, $out"; fi
  else
    echo "  pulado guard do ts-lsp (sem node)"
  fi

  TPL="$REPO/plugins/kit/skills/plan/template.md"
  tpl_got="$(grep -E '^##+ |^  - (files|behavior|action|verify|done):' "$TPL" | sed -E 's/^(##+ [^—]*[^ —]).*/\1/; s/:.*//; s/^ *- //' | tr -d '\r' | paste -sd'|' -)"
  tpl_want="## must_haves|### truths|### artifacts|### tests|## Interfaces|## Wave 1|files|behavior|action|verify|done|## Wave final|## Decisões|## Riscos"
  if [ "$tpl_got" = "$tpl_want" ]; then ok "template do PLAN.md: seções e campos na ordem"; else ko "template do PLAN.md: seções e campos na ordem" "$tpl_got"; fi
  tpl_bad="$(grep -E '\[[ xX]\]' "$TPL" | grep -vE '^- \[ \] ([0-9]+\.|Checkpoint wave [0-9]+:|F[0-9]+\.) ' || true)"
  if [ -z "$tpl_bad" ]; then ok "template do PLAN.md: caixa so em tarefa, checkpoint e wave final"; else ko "template do PLAN.md: caixa so em tarefa, checkpoint e wave final" "$tpl_bad"; fi

  # Agent com Bash le arquivo com Read: cat/cd pelo Bash cai em regra ask do projeto e pede aprovacao.
  bash_agents=0
  read_bad=""
  for f in "$REPO"/plugins/kit/agents/*.md; do
    tr -d '\r' <"$f" | grep -qE '^tools:.*\bBash\b' || continue
    bash_agents=$((bash_agents + 1))
    grep -qF 'Para ler arquivo use Read; para buscar, Grep/Glob.' "$f" && grep -qF 'Bash só para git (`log`, `blame`, `show`, `diff`, `status`)' "$f" &&
      grep -qF 'Nunca `cat`/`head`/`tail`/`sed`/`grep`/`find` via Bash, nem `cd <repo>;` no início do comando' "$f" &&
      grep -qF 'Um comando por chamada de Bash, sem encadear com `&&`, `;` ou `|`.' "$f" || read_bad+="$(basename "$f") "
  done
  if [ "$bash_agents" -ge 3 ] && [ -z "$read_bad" ]; then ok "agents com Bash: leitura por Read, busca por Grep/Glob, um comando por chamada, sem cat nem cd <repo>; ($bash_agents agents)"
  else ko "agents com Bash: leitura por Read, busca por Grep/Glob, um comando por chamada, sem cat nem cd <repo>;" "agents=$bash_agents sem instrução: $read_bad"; fi

  # Subagent general-purpose do execute recebe o bloco fixo de regras de leitura e Bash.
  SUB_RULES="$REPO/plugins/kit/skills/execute/subagent-rules.md"
  sub_want='Leitura e busca: para ler arquivo use Read; para buscar, Grep/Glob. Bash só para git (log/blame/show/diff/status) e para os comandos do .claude/kit.json. Um comando por chamada de Bash: nunca encadeie com &&, ; ou |. Nunca cat/head/tail/sed/grep/find/ls via Bash, nem `cd <repo>;` no início (use git -C <repo>). Nunca entregue ao usuário comando com placeholder.'
  sub_bad=""
  [ "$(tr -d '\r' <"$SUB_RULES" 2>/dev/null)" = "$sub_want" ] || sub_bad+="subagent-rules.md "
  for f in "$REPO"/plugins/kit/skills/*/SKILL.md; do
    grep -qF 'general-purpose' "$f" || continue
    grep -qF '${CLAUDE_SKILL_DIR}/subagent-rules.md' "$f" && grep -qF 'sem mudar uma palavra' "$f" || sub_bad+="$(basename "$(dirname "$f")") "
  done
  grep -qF '${CLAUDE_SKILL_DIR}/subagent-rules.md' "$REPO/plugins/kit/skills/execute/SKILL.md" || sub_bad+="execute "
  if [ -z "$sub_bad" ]; then ok "delegação a general-purpose inclui o bloco de subagent-rules.md"
  else ko "delegação a general-purpose inclui o bloco de subagent-rules.md" "$sub_bad"; fi

  # Nenhum placeholder em comando entregue ao usuario.
  ph_bad=""
  for s in spec plan execute fix hunt init map drift design; do
    grep -qF 'Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`)' "$REPO/plugins/kit/skills/$s/SKILL.md" || ph_bad+="$s "
  done
  grep -qF 'Nunca entregue comando com placeholder' "$REPO/plugins/kit/templates/CLAUDE.project.md" || ph_bad+="CLAUDE.project.md "
  if [ -z "$ph_bad" ]; then ok "skills e template do CLAUDE.md: nenhum placeholder em comando para o usuário"
  else ko "skills e template do CLAUDE.md: nenhum placeholder em comando para o usuário" "sem a regra: $ph_bad"; fi

  # O kit nunca escreve no settings do usuario: nada de propose/apply, escopo ou --prefer.
  usr_bad="$(grep -rnE 'setup\.sh"? (propose|apply)|user-settings\.json|--prefer|Só nos projetos que o habilitam|settings\.kit-proposta' \
    "$REPO/README.md" "$REPO/CONTRIBUTING.md" "$REPO/docs" "$REPO/plugins/kit" || true)"
  if [ -z "$usr_bad" ] && grep -qF 'nunca toca no ~/.claude/settings.json' "$REPO/plugins/kit/skills/setup/SKILL.md" &&
    grep -qF 'Settings do usuário nunca é tocado.' "$INIT_MD" && grep -qF 'multiSelect: true' "$INIT_MD" && grep -qF 'permissions.groups' "$INIT_MD"; then
    ok "setup e init: settings do usuário nunca escrito; grupos por projeto em multiSelect"
  else ko "setup e init: settings do usuário nunca escrito; grupos por projeto em multiSelect" "$usr_bad"; fi

  # Spec e plano grandes: limites com padrao, pergunta unica de quebra e M8 no revisor.
  SPEC_MD="$REPO/plugins/kit/skills/spec/SKILL.md"
  PLAN_MD="$REPO/plugins/kit/skills/plan/SKILL.md"
  size_bad=""
  for want in 'spec.max_scope_items` (padrão 8)' 'spec.max_files` (padrão 25)' 'no máximo 2 repositórios' 'uma vez só' \
    'Quebrar em fatias agora (Recomendado)' 'sem precisar rodar outro comando' 'Manter numa spec só' 'Reduzir escopo' 'skills/epic/SKILL.md' 'tamanho: manter'; do
    grep -qF -- "$want" "$SPEC_MD" || size_bad+="spec:'$want' "
  done
  for want in 'plan.max_tasks` (padrão 15)' 'plan.max_waves` (padrão 6)' 'não grave o PLAN.md' 'uma vez só' \
    'Quebrar em fatias agora (Recomendado)' 'sem precisar rodar outro comando' 'Manter num plano só' 'Reduzir escopo' 'skills/epic/SKILL.md' '· usuário · tamanho: manter'; do
    grep -qF -- "$want" "$PLAN_MD" || size_bad+="plan:'$want' "
  done
  for f in "$SPEC_MD" "$PLAN_MD"; do
    tr -d '\r' <"$f" | grep -qF 'allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**)' || size_bad+="$(basename "$(dirname "$f")"):allowed-tools "
  done
  grep -qE '^- \*\*M8\*\* .*plan\.max_tasks.*plan\.max_waves.*tamanho: manter' "$REPO/plugins/kit/agents/plan-reviewer.md" || size_bad+="plan-reviewer:M8 "
  jq -e '.spec.max_scope_items == 8 and .spec.max_files == 25 and .plan.max_tasks == 15 and .plan.max_waves == 6' \
    "$REPO/plugins/kit/templates/kit.example.json" >/dev/null 2>&1 || size_bad+="kit.example.json "
  grep -qF '**`/kit:epic` ou `/kit:spec`?**' "$REPO/README.md" || size_bad+="README "
  # "via /kit:epic" fazia parecer que o usuario precisa rodar o /kit:epic depois de escolher quebrar.
  via_epic="$(grep -rnF 'via /kit:epic' "$REPO/README.md" "$REPO/docs" "$REPO/plugins/kit" || true)"
  [ -z "$via_epic" ] || size_bad+="'via /kit:epic': $via_epic "
  if [ -z "$size_bad" ]; then ok "spec e plano grandes: limites, pergunta única de quebra, M8 e README"
  else ko "spec e plano grandes: limites, pergunta única de quebra, M8 e README" "$size_bad"; fi

  # Revisor de SPEC e drift: ids fixos, veredito na ultima linha, somente leitura e chamados pelas skills.
  SR="$REPO/plugins/kit/agents/spec-reviewer.md"
  DC="$REPO/plugins/kit/agents/drift-checker.md"
  sd_bad=""
  for id in B1 B2 B3 B4 B5 M1 M2 M3 M4 M5 M6 M7 M8 M9; do grep -qE "^- \*\*$id\*\* " "$SR" || sd_bad+="spec-reviewer:$id "; done
  for id in D1 D2 D3 D4 D5; do grep -qE "^- \*\*$id\*\* " "$DC" || sd_bad+="drift-checker:$id "; done
  for f in "$SR" "$DC"; do
    tr -d '\r' <"$f" | grep -qx 'tools: Read, Grep, Glob' || sd_bad+="$(basename "$f"):tools "
  done
  grep -qF '## Calibração' "$SR" && grep -qF '**O que a SPEC propõe**' "$SR" && grep -qF '`reprovado`' "$SR" && grep -qF '`aprovado`' "$SR" || sd_bad+="spec-reviewer:saída "
  grep -qF '`divergente`' "$DC" && grep -qF '`sem divergência`' "$DC" && grep -qF 'corrigir: spec | código' "$DC" || sd_bad+="drift-checker:saída "
  grep -qF 'kit:spec-reviewer' "$SPEC_MD" && grep -qF '(decisão de produto)' "$SPEC_MD" || sd_bad+="spec:revisão "
  grep -qF 'kit:spec-reviewer' "$REPO/plugins/kit/skills/epic/SKILL.md" || sd_bad+="epic:revisão "
  DRIFT_MD="$REPO/plugins/kit/skills/drift/SKILL.md"
  grep -qF 'kit:drift-checker' "$DRIFT_MD" && grep -qF 'disable-model-invocation: true' "$DRIFT_MD" && grep -qF 'nenhuma caixa `- [ ]`' "$DRIFT_MD" || sd_bad+="drift:skill "
  tr -d '\r' <"$DRIFT_MD" | grep -qF 'allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**) Bash(git rev-parse *) Edit(docs/specs/DRIFT.md) Write(docs/specs/DRIFT.md)' || sd_bad+="drift:allowed-tools "
  for a in spec-reviewer drift-checker; do
    grep -qF "$a" "$REPO/plugins/kit/skills/init/adopt.md" || sd_bad+="adopt:$a "
    grep -qF "$a" "$REPO/CONTRIBUTING.md" || sd_bad+="CONTRIBUTING:$a "
    grep -qF "$a" "$REPO/docs/reference.md" || sd_bad+="reference:$a "
  done
  grep -qF '/kit:drift' "$REPO/README.md" || sd_bad+="README:drift "
  if [ -z "$sd_bad" ]; then ok "spec-reviewer e drift-checker: ids, saída, somente leitura, chamados pelas skills e documentados"
  else ko "spec-reviewer e drift-checker: ids, saída, somente leitura, chamados pelas skills e documentados" "$sd_bad"; fi

  # Interface: revisor com ids fixos e somente leitura, regras nas skills, script liberado, sem variavel
  # de skill em arquivo lido com Read, e todo id que a sondagem usa existe no revisor.
  UR="$REPO/plugins/kit/agents/ui-reviewer.md"
  EXE_DIR="$REPO/plugins/kit/skills/execute"
  ui_bad=""
  for id in B1 B2 B3 M1 M2 M3 M4 M5 M6 M7 M8 M9; do grep -qE "^- \*\*$id\*\* " "$UR" || ui_bad+="ui-reviewer:$id "; done
  tr -d '\r' <"$UR" | grep -qx 'tools: Read, Grep, Glob' || ui_bad+="ui-reviewer:tools "
  grep -qF '`reprovado`' "$UR" && grep -qF '`aprovado`' "$UR" && grep -qF '## Calibração' "$UR" && grep -qF 'report.json' "$UR" &&
    grep -qF 'revisão só pelo código (sem captura)' "$UR" || ui_bad+="ui-reviewer:saída "
  for id in $(grep -ohE '"[BM][0-9]+"' "$SCRIPTS/ui-probe.js" "$SCRIPTS/ui-capture.mjs" | tr -d '"' | sort -u); do
    grep -qE "^- \*\*$id\*\* " "$UR" || ui_bad+="id da sondagem sem regra no revisor:$id "
  done
  for rule in $(grep -oE 'add\("[a-z-]+"' "$SCRIPTS/ui-probe.js" | sed -E 's/add\("//; s/"//' | sort -u) console requisicao nao-carregou; do
    grep -qF "\`$rule\`" "$REPO/docs/reference.md" || ui_bad+="reference sem a regra $rule "
  done
  for id in M10 M11; do grep -qE "^- \*\*$id\*\* " "$SR" || ui_bad+="spec-reviewer:$id "; done
  grep -qE '^- \*\*M9\*\* .*ui\.globs' "$REPO/plugins/kit/agents/plan-reviewer.md" && grep -qE '^- \*\*B3\*\* .*estado de tela' "$REPO/plugins/kit/agents/plan-reviewer.md" || ui_bad+="plan-reviewer "
  for want in '## Telas' '**Feature com tela.**' 'ui.globs' 'Estados: vazio' 'Tela pequena:' 'Padrão visual:'; do
    grep -qF -- "$want" "$SPEC_MD" || ui_bad+="spec:'$want' "
  done
  grep -qF 'ui.globs' "$PLAN_MD" && grep -qF 'kit:ui-reviewer' "$PLAN_MD" && grep -qF 'seção Telas' "$PLAN_MD" || ui_bad+="plan "
  grep -qE '^- \[ \] F1\. .*<; em plano com tela: e `kit:ui-reviewer`[^>]*>$' "$TPL" || ui_bad+="template:F1 "
  EXE_MD="$EXE_DIR/SKILL.md"
  tr -d '\r' <"$EXE_MD" | grep -q '^allowed-tools:.* Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui.sh" \*)' || ui_bad+="execute:allowed-tools "
  for want in '${CLAUDE_SKILL_DIR}/ui.md' '${CLAUDE_SKILL_DIR}/ui-rules.md' 'kit:ui-reviewer' 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui.sh"' '"ui": false'; do
    grep -qF -- "$want" "$EXE_MD" || ui_bad+="execute:'$want' "
  done
  for want in '--probe-only' '--steps' '"setup"' 'text=<texto visível>' '${NOME}' '--attach' 'incompleta' 'kit:ui-reviewer' 'sem captura' 'timeout: 600000' \
    '## No checkpoint da wave' '## Na wave final (F1)'; do
    grep -qF -- "$want" "$EXE_DIR/ui.md" || ui_bad+="ui.md:'$want' "
  done
  # A sondagem e a captura vem antes do verify e dos revisores, para as correcoes delas passarem por eles.
  grep -qE '^   1\. Interface: .*sondagem do checkpoint' "$EXE_MD" && grep -qE '^   2\. Re-rode os `verify`' "$EXE_MD" &&
    grep -qE '^   1\. F1: em plano com tela .*comece pela captura completa' "$EXE_MD" || ui_bad+="execute:ordem da sondagem "
  # Toda acao de passo que o script aceita esta descrita para quem vai usa-la, e a captura nao depende de plugin de terceiro.
  for act in $(sed -n 's/^const STEP_ACTIONS = \[\(.*\)\];$/\1/p' "$SCRIPTS/ui-capture.mjs" | tr -d '",'); do
    grep -qF "{\"$act\":" "$EXE_DIR/ui.md" || ui_bad+="ui.md sem o passo $act "
    grep -qF "{\"$act\":" "$REPO/docs/reference.md" || ui_bad+="reference sem o passo $act "
  done
  ! grep -rqiE 'dev-browser|9223' "$REPO/plugins/kit" || ui_bad+="plugin ainda cita dev-browser: $(grep -rliE 'dev-browser|9223' "$REPO/plugins/kit" | tr '\n' ' ')"
  ! grep -qF '${CLAUDE_' "$EXE_DIR/ui.md" "$EXE_DIR/ui-rules.md" || ui_bad+="variável de skill em arquivo lido com Read "
  [ "$(head -n 1 "$EXE_DIR/ui-rules.md" | tr -d '\r')" = "Interface: vale para todo arquivo de tela, componente ou estilo." ] &&
    [ "$(grep -cE '^[0-9]+\. ' "$EXE_DIR/ui-rules.md")" = "10" ] && ! grep -q '^#' "$EXE_DIR/ui-rules.md" || ui_bad+="ui-rules.md "
  tr -d '\r' <"$INIT_MD" | grep -q '^allowed-tools:.* Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui.sh" status) ' || ui_bad+="init:allowed-tools "
  for want in 'ui.sh" status' '.claude/rules/kit-ui.md' 'templates/kit-ui.rule.md' 'skills/execute/ui-rules.md' 'já foi respondido: não proponha de novo' \
    '`rule: ausente`' '`rule: desatualizada`' '`rule: do projeto`' 'não acrescenta plugin nem marketplace'; do
    grep -qF -- "$want" "$INIT_MD" || ui_bad+="init:'$want' "
  done
  # Cada estado que o ui.sh imprime na linha rule tem instrucao no init.
  for st in ausente desatualizada 'do projeto' ok; do
    grep -qF "echo \"$st" "$SCRIPTS/ui.sh" || ui_bad+="ui.sh sem o estado de rule '$st' "
  done
  grep -qF '## Interface (`ui`)' "$REPO/plugins/kit/skills/init/stacks.md" || ui_bad+="stacks "
  jq -e '(.ui.globs | length) > 0 and .ui.viewports == ["360x800", "768x1024", "1280x800", "1920x1080"] and (.ui.dev | length) > 0 and (.ui.url | test("^http://"))' \
    "$REPO/plugins/kit/templates/kit.example.json" >/dev/null 2>&1 || ui_bad+="kit.example.json "
  grep -qx 'paths:' "$REPO/plugins/kit/templates/kit-ui.rule.md" && grep -qxF '<!-- kit:ui v1 -->' "$REPO/plugins/kit/templates/kit-ui.rule.md" || ui_bad+="kit-ui.rule.md "
  grep -qE '^ext\|tsx\|' "$REPO/plugins/kit/templates/ui-markers.txt" && grep -qE '^arquivo\|' "$REPO/plugins/kit/templates/ui-markers.txt" &&
    grep -qE '^dep\|' "$REPO/plugins/kit/templates/ui-markers.txt" || ui_bad+="ui-markers.txt "
  for a in adopt.md; do grep -qF 'ui-reviewer' "$REPO/plugins/kit/skills/init/$a" || ui_bad+="adopt:ui-reviewer "; done
  grep -qF 'ui-reviewer' "$REPO/CONTRIBUTING.md" && grep -qF '| `ui-reviewer` |' "$REPO/docs/reference.md" || ui_bad+="docs:ui-reviewer "
  grep -qxF '## Interface' "$REPO/README.md" && grep -qF 'Tela atrás de login ou clique' "$REPO/README.md" && grep -qF '| `ui` |' "$REPO/README.md" &&
    grep -qxF '## Interface' "$REPO/docs/reference.md" && grep -qxF '### `ui`' "$REPO/docs/reference.md" || ui_bad+="README/reference "
  grep -qF 'ui.sh" capture --probe-only' "$REPO/plugins/kit/skills/fix/SKILL.md" || ui_bad+="fix "
  if command -v node >/dev/null 2>&1; then
    node --check "$SCRIPTS/ui-capture.mjs" >/dev/null 2>&1 || ui_bad+="ui-capture.mjs não compila "
    node -e 'new Function("return " + require("fs").readFileSync(process.argv[1], "utf8"))' "$SCRIPTS/ui-probe.js" >/dev/null 2>&1 || ui_bad+="ui-probe.js não compila "
  fi
  if [ -z "$ui_bad" ]; then ok "interface: revisor, regras nas skills, script liberado, sondagem e docs coerentes"
  else ko "interface: revisor, regras nas skills, script liberado, sondagem e docs coerentes" "$ui_bad"; fi

  # Direcao visual: skill com os passos e os blocos em arquivos lidos com Read (sem variavel de skill),
  # bloco de direcao curto e sem palavra proibida, molde da rule com cabecalho e paths, e docs.
  DSG="$REPO/plugins/kit/skills/design"
  DSG_TPL="$REPO/plugins/kit/templates/kit-design.rule.md"
  dg_bad=""
  for want in 'name: design' 'argument-hint: "[app | rota ou arquivo da página | componente]"' 'allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**)'; do
    tr -d '\r' <"$DSG/SKILL.md" | grep -qxF -- "$want" || dg_bad+="skill:'$want' "
  done
  tr -d '\r' <"$DSG/SKILL.md" | grep -qE '^description: .*amostras.*kit-design\.md.*DESIGN\.md' || dg_bad+="skill:description "
  for want in '${CLAUDE_SKILL_DIR}/passos.md' '`<raiz-do-plugin>` em [passos.md](passos.md): `${CLAUDE_PLUGIN_ROOT}`' 'Argumento: $ARGUMENTS' \
    'Não escreva código de produção nesta skill' 'Não grave SPEC' 'Sem `AskUserQuestion` disponível' 'subagent_tokens'; do
    grep -qF -- "$want" "$DSG/SKILL.md" || dg_bad+="skill:'$want' "
  done
  ! grep -qF -e '${CLAUDE_' -e '$ARGUMENTS' "$DSG/passos.md" "$DSG/visual.md" || dg_bad+="variável de skill em arquivo lido com Read "
  for want in 'general-purpose' 'todas na mesma mensagem' '<raiz-do-plugin>/skills/design/visual.md' '<raiz-do-plugin>/skills/execute/ui-rules.md' \
    '<raiz-do-plugin>/skills/execute/subagent-rules.md' '<raiz-do-plugin>/templates/kit-design.rule.md' 'sem mudar uma palavra' \
    '.claude/state/ui/design/<slug>/<n>-<nome>.html' 'kit:investigator' 'recomende `/kit:init`' 'em 360 e em 1280px' 'só dado fictício' 'fonte de reserva' \
    'No máximo 3 rodadas' '<!-- kit:design v1 -->' 'docs/specs/<slug>/amostra.html' 'docs/specs/<slug>/DESIGN.md' 'kit-design-<area>.md' \
    '`/kit:spec docs/specs/<slug>/DESIGN.md`' 'Custo: <N> subagents'; do
    grep -qF -- "$want" "$DSG/passos.md" || dg_bad+="passos:'$want' "
  done
  for sec in Escopo 'Problema de hoje' Decisões 'Direção escolhida' Amostra 'Componentes base' 'Telas afetadas' 'Fora do redesenho'; do
    tr -d '\r' <"$DSG/passos.md" | grep -qxF "## $sec" || dg_bad+="DESIGN.md sem a seção '$sec' "
  done
  head -n 1 "$DSG/visual.md" | grep -q '^Direção visual: ' && ! grep -q '^#' "$DSG/visual.md" &&
    [ "$(grep -cE '^[0-9]+\. ' "$DSG/visual.md")" -ge 8 ] && [ "$(grep -c '' "$DSG/visual.md")" -le 15 ] || dg_bad+="visual.md "
  for want in 'Inter, Roboto e Arial' 'prefers-reduced-motion' 'visual padrão de template' 'O que continua valendo sempre'; do
    grep -qF -- "$want" "$DSG/visual.md" || dg_bad+="visual:'$want' "
  done
  dg_words="$(grep -nwE 'IA|AI|Claude|[Ss]lop' "$DSG/SKILL.md" "$DSG/passos.md" "$DSG/visual.md" "$DSG_TPL" || true)"
  [ -z "$dg_words" ] || dg_bad+="palavra proibida no conteúdo de direção: $dg_words "
  tr -d '\r' <"$DSG_TPL" | grep -qx 'paths:' && tr -d '\r' <"$DSG_TPL" | grep -qxF '<!-- kit:design v1 -->' || dg_bad+="kit-design.rule.md "
  for field in Direção Tipografia Paleta Composição Movimento Acabamento 'O que evitar' Amostra; do
    grep -qE "^- $field: " "$DSG_TPL" || dg_bad+="kit-design.rule.md sem o campo '$field' "
  done
  grep -qF '| `/kit:design` |' "$REPO/README.md" && grep -qF '/kit:design' "$REPO/docs/reference.md" && grep -qF '/kit:design' "$REPO/docs/design.md" &&
    grep -qF 'anthropics/skills' "$REPO/docs/design.md" || dg_bad+="README/reference/design "
  grep -qF ',drift,design}/SKILL.md' "$REPO/CONTRIBUTING.md" && grep -qF 'kit-design.rule.md' "$REPO/CONTRIBUTING.md" || dg_bad+="CONTRIBUTING "
  grep -qE '^- Skills: .*`design`' "$REPO/plugins/kit/skills/init/adopt.md" || dg_bad+="adopt "
  if [ -z "$dg_bad" ]; then ok "direção visual: skill, passos, bloco de direção, molde da rule e docs coerentes"
  else ko "direção visual: skill, passos, bloco de direção, molde da rule e docs coerentes" "$dg_bad"; fi

  # Notificacoes: opcionais, perguntadas uma vez, sem duplicar alertas existentes nem guardar segredo.
  nt_bad=""
  for want in 'setup.sh" alerts' 'vai duplicar' 'nenhuma com `(Recomendado)`' '"notify": false' 'já foi respondido: não pergunte de novo' \
    'Alertas existentes são intocáveis' 'nunca o tópico nem a URL'; do
    grep -qF -- "$want" "$INIT_MD" || nt_bad+="init:'$want' "
  done
  for want in '## Notificações' 'preferredNotifChannel' 'KIT_NTFY_TOPIC' '"notify": false'; do
    grep -qF -- "$want" "$REPO/README.md" || nt_bad+="README:'$want' "
  done
  jq -e '.notify.push == {"ntfy_topic_env": "KIT_NTFY_TOPIC", "discord_webhook_env": "KIT_DISCORD_WEBHOOK"} and .notify.done_min_seconds == 60' \
    "$REPO/plugins/kit/templates/kit.example.json" >/dev/null 2>&1 || nt_bad+="kit.example.json "
  jq -e '[.hooks.Notification[].hooks[] | select(.async == true and (.command | endswith("/scripts/notify.sh\"")))] | length == 1' \
    "$REPO/plugins/kit/hooks/hooks.json" >/dev/null 2>&1 || nt_bad+="hooks.json "
  if [ -z "$nt_bad" ]; then ok "notificações: init pergunta uma vez sem recomendar, avisa duplicação; README, exemplo e hook async"
  else ko "notificações: init pergunta uma vez sem recomendar, avisa duplicação; README, exemplo e hook async" "$nt_bad"; fi

  bad_json=""
  while IFS= read -r f; do
    jq empty "$f" >/dev/null 2>&1 || bad_json+="$f "
  done < <(find "$REPO" -name '*.json' -not -path '*/.git/*' -not -path '*/node_modules/*')
  if [ -z "$bad_json" ]; then ok "todos os JSON do repositorio sao validos"; else ko "JSON invalido" "$bad_json"; fi

  # bash 3.2 (macOS): sem arrays associativos, mapfile/readarray, ${x,,}/${x^^}, local -n, [[ -v ]],
  # |& nem ;&. Expansao de array precisa da forma ${a[@]+"${a[@]}"}: no bash < 4.4 com set -u,
  # "${a[@]}" de array vazio aborta o script.
  b4="$(grep -nE 'declare -A|local -A|typeset -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)|local -n|declare -n|\[\[ -v |[[:space:]]\|&[[:space:]]|[[:space:]];;?&([[:space:]]|$)' "$SCRIPTS"/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  if [ -z "$b4" ]; then ok "bash 3.2: nenhum recurso de bash 4 nos scripts"; else ko "bash 3.2: nenhum recurso de bash 4 nos scripts" "$b4"; fi
  arr_bad="$(grep -nE '"\$\{[A-Za-z_]+\[@\]' "$SCRIPTS"/*.sh | grep -vE '\$\{([A-Za-z_]+)\[@\]\+"\$\{\1\[[@*]\]' || true)"
  # Excecoes conferidas: arrays com tamanho testado na linha ou preenchidos com "$@" de chamada nao vazia.
  arr_bad="$(printf '%s\n' "$arr_bad" | grep -vE '# array nao vazio|\[ "\$\{#[A-Za-z_]+\[@\]\}" -gt 0 \]|"\$\{(w|c|violations|FAILS|globs|when|require)\[@\]' | sed '/^$/d' || true)"
  if [ -z "$arr_bad" ]; then ok "bash 3.2: expansao de array protegida contra set -u"; else ko "bash 3.2: expansao de array protegida contra set -u" "$arr_bad"; fi
  # Exclamacao seguida de crase no meio do texto de uma skill vira injecao de comando e, sem
  # permissao, impede a skill de carregar. So pode aparecer no inicio da linha (Estado atual).
  inj="$(grep -rnE '.!`|`!`' "$REPO/plugins/kit/skills" --include='*.md' || true)"
  if [ -z "$inj" ]; then ok "skills: injecao de comando so no inicio da linha"; else ko "skills: injecao de comando so no inicio da linha" "$inj"; fi
  nort="$(grep -nE 'realpath|readlink -f|readlink -m' "$SCRIPTS"/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  if [ -z "$nort" ]; then ok "nenhum script depende de realpath ou readlink -f (ausentes no macOS antigo)"; else ko "nenhum script depende de realpath ou readlink -f" "$nort"; fi

  if command -v claude >/dev/null 2>&1; then
    if claude plugin validate "$REPO/plugins/kit" >"$TMP_ALL/validate" 2>&1; then ok "claude plugin validate plugins/kit"; else ko "claude plugin validate plugins/kit" "$(tail -n 20 "$TMP_ALL/validate")"; fi
    if claude plugin validate "$REPO" >"$TMP_ALL/validate" 2>&1; then ok "claude plugin validate (marketplace)"; else ko "claude plugin validate (marketplace)" "$(tail -n 20 "$TMP_ALL/validate")"; fi
  else
    echo "  pulado claude plugin validate (CLI nao encontrada)"
  fi
fi
}

# Grupos na ordem da saida: fixtures em fatias de FX_SHARD casos, depois os blocos de unidade.
# Grupos sao independentes: cada um roda num subshell com o proprio diretorio temporario.
ALL_GROUPS=()
for fx in "$HERE"/fixtures/*.json; do
  n="$(jq '.cases | length' "$fx" | tr -d '\r')"
  for ((i = 0; i < n; i += FX_SHARD)); do ALL_GROUPS+=("fx:${fx##*/}:$i:$((i + FX_SHARD))"); done
done
ALL_GROUPS+=(semjq forma_shell apoio_init wave_base map_partition setup notify interface guardas estaticas)

# Grupos afetados por um arquivo alterado (padroes casados contra "fx:<fixture>" ou o nome do grupo).
# "*" e a suite inteira; arquivo sem script nem fixture (docs, skills, agents) so roda as estaticas.
groups_for_file() {
  local hooks="semjq forma_shell"
  case "$1" in
    plugins/kit/scripts/lib.sh | tests/run-tests.sh | tests/sample/*) echo "*" ;;
    plugins/kit/scripts/guard-bash.sh | plugins/kit/scripts/guard-pwsh.sh) echo "fx:guard-bash.json fx:guard-pwsh.json $hooks guardas" ;;
    plugins/kit/scripts/guard-files.sh) echo "fx:guard-files*.json $hooks guardas" ;;
    plugins/kit/scripts/verify-gate.sh) echo "fx:verify-gate*.json $hooks guardas" ;;
    plugins/kit/scripts/notify.sh) echo "fx:notify.json fx:verify-gate-notify.json notify $hooks" ;;
    plugins/kit/scripts/format.sh | plugins/kit/scripts/advise.sh | plugins/kit/scripts/pre-compact.sh | plugins/kit/scripts/session-context.sh)
      local b="${1##*/}"; echo "fx:${b%.sh}.json $hooks" ;;
    plugins/kit/scripts/ui.sh | plugins/kit/scripts/ui-capture.mjs | plugins/kit/scripts/ui-probe.js | plugins/kit/templates/ui-markers.txt | tests/ui/*) echo "interface" ;;
    plugins/kit/scripts/merge-json.sh) echo "apoio_init setup" ;;
    plugins/kit/scripts/inventory.sh) echo "apoio_init" ;;
    plugins/kit/scripts/map-partition.sh) echo "map_partition" ;;
    plugins/kit/scripts/setup.sh) echo "setup notify" ;;
    plugins/kit/templates/*) echo "setup" ;;
    plugins/kit/scripts/wave-base.sh) echo "wave_base" ;;
    plugins/kit/scripts/*) echo "*" ;;
    plugins/kit/hooks/hooks.json) echo "forma_shell" ;;
    tests/fixtures/*.json) echo "fx:${1##*/}" ;;
    tests/adopt/*) echo "apoio_init" ;;
  esac
}

SELECTED=("${ALL_GROUPS[@]}")
if [ "$CHANGED" = "1" ]; then
  pats="estaticas"
  while IFS= read -r f; do
    [ -n "$f" ] && pats="$pats $(groups_for_file "$f")"
  done < <({ git -C "$REPO" diff --name-only HEAD; git -C "$REPO" ls-files --others --exclude-standard; } 2>/dev/null | tr -d '\r' | sort -u)
  SELECTED=()
  set -f
  for g in "${ALL_GROUPS[@]}"; do
    key="$g"
    case "$g" in fx:*) key="${g%:*:*}" ;; esac
    for p in $pats; do
      # shellcheck disable=SC2254
      case "$key" in $p) SELECTED+=("$g"); break ;; esac
    done
  done
  set +f
  echo "--changed: $(printf '%s\n' "${SELECTED[@]}" | sed 's/:[0-9]*:[0-9]*$//' | awk '!seen[$0]++' | paste -sd' ' -)"
fi

run_group() {
  local g="$1" f from to
  TMP_ALL="$TMP_ALL/g$2"
  mkdir -p "$TMP_ALL"
  case "$g" in
    fx:*)
      f="${g#fx:}"; to="${f##*:}"; f="${f%:*}"; from="${f##*:}"; f="${f%:*}"
      g_fixture "$HERE/fixtures/$f" "$from" "$to" ;;
    *) "g_$g" ;;
  esac
}

OUTD="$TMP_ALL/saida"
mkdir -p "$OUTD"
t_start="$(date +%s)"
idx=0
for g in "${SELECTED[@]}"; do
  idx=$((idx + 1))
  if [ "$JOBS" = "1" ]; then
    (run_group "$g" "$idx") 2>&1 | tee "$OUTD/$idx.log"
  else
    while [ "$(jobs -pr | wc -l)" -ge "$JOBS" ]; do sleep 0.2; done
    (run_group "$g" "$idx") >"$OUTD/$idx.log" 2>&1 &
  fi
done
wait
if [ "$JOBS" != "1" ]; then
  i=0
  while [ "$i" -lt "$idx" ]; do i=$((i + 1)); cat "$OUTD/$i.log"; done
fi

# Contagem pelas linhas de resultado de todos os grupos.
i=0
while [ "$i" -lt "$idx" ]; do
  i=$((i + 1))
  PASS=$((PASS + $(grep -c '^  ok    ' "$OUTD/$i.log")))
  FAIL=$((FAIL + $(grep -c '^  FALHA ' "$OUTD/$i.log")))
done

echo
echo "$PASS passaram, $FAIL falharam ($(($(date +%s) - t_start))s, --jobs $JOBS)"
if [ "$FAIL" -gt 0 ]; then
  i=0
  while [ "$i" -lt "$idx" ]; do i=$((i + 1)); grep '^  FALHA ' "$OUTD/$i.log" | sed 's/^  FALHA / - /'; done
  exit 1
fi
exit 0
