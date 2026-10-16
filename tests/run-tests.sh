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
    while IFS= read -r f0; do [ -n "$f0" ] && sed -i "s/__HEAD0__/$h0/g" "$f0"; done < <(grep -rlF __HEAD0__ "$ws/sample" --exclude-dir=.git 2>/dev/null)
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
    c_message c_env l_stderr l_stderr_not l_stderr_order l_absent l_exists l_contains l_stdout l_stdout_not stdout_empty has_out_expect reason json_check
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
    guard-bash.sh)
      local gcmd="$c_command"
      gcmd="${gcmd//__PROJ__/$(native_path "$base")}"
      input="$(jq -cn --arg c "$gcmd" --arg d "$cwd" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')" ;;
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
  if [ "$expect" != "deny" ] && [ "$script" != "session-context.sh" ] && [ "$has_out_expect" != "true" ] && [ -s "$out" ]; then
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
  if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
    ko "PATH de teste sem jq" "jq ainda encontrado em $(PATH="$NOJQ_PATH" command -v jq)"
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
  if PATH="$NOGIT_PATH" command -v git >/dev/null 2>&1; then
    ko "PATH de teste sem git" "git ainda encontrado em $(PATH="$NOGIT_PATH" command -v git)"
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
  NR="$U/netrules"
  mkdir -p "$NR/.claude" "$U/home/.claude"
  printf '%s' '{"permissions":{"ask":["Bash(curl *rubinot.com.br*)"]}}' >"$NR/.claude/settings.json"
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

  # Windows nativo simulado: check avisa que nao ha sandbox.
  C3="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  out="$(run_setup "$C3" "$WIN_BIN:$NOCLAUDE_PATH" check 2>&1)"
  code=$?
  if [ "$code" = "0" ] && grep -qF 'plataforma: windows nativo — sem sandbox' <<<"$out"; then
    ok "setup check: Windows nativo simulado avisa que não há sandbox"
  else ko "setup check: Windows nativo simulado avisa que não há sandbox" "exit $code, $out"; fi
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
  if [ "$code" = "0" ] && grep -qxF 'lsp typescript-lsp@claude-plugins-official typescript-language-server: ok' <<<"$out" &&
    grep -qxF 'lsp gopls-lsp@claude-plugins-official gopls: falta — instale: go install golang.org/x/tools/gopls@latest' <<<"$out" &&
    grep -qxF 'lsp jdtls-lsp@claude-plugins-official jdtls: falta — sem instalação automática nesta plataforma' <<<"$out" &&
    [ "$(grep -c . <<<"$out")" = "3" ]; then
    ok "setup lsp: plugin oficial por linguagem, binário ok, ausente com instalação ou sem instalação"
  else ko "setup lsp: plugin oficial por linguagem, binário ok, ausente com instalação ou sem instalação" "exit $code, $out"; fi
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
  readme_adv="$(awk '/^## Avançado \(opcional\)/ { on = 1; next } on && /^## / { on = 0 } on' "$REPO/README.md")"
  if grep -qF '/run-skill-generator' <<<"$readme_adv" && grep -qF '/verify' <<<"$readme_adv" &&
    [ "$(grep -c 'run-skill-generator' "$REPO/README.md")" = "$(grep -c 'run-skill-generator' <<<"$readme_adv")" ]; then
    ok "README: /run-skill-generator e /verify só em Avançado (opcional)"
  else ko "README: /run-skill-generator e /verify só em Avançado (opcional)" "$(grep -n 'run-skill-generator\|/verify' "$REPO/README.md")"; fi
  manual="$(grep -rnE 'kit-settings\.suggested|merge-json\.sh --additions|aplique a sugestão|aplica se quiser|Mescle .*user-settings' \
    "$REPO/README.md" "$REPO/CONTRIBUTING.md" "$REPO/docs" "$REPO/plugins/kit" || true)"
  if [ -z "$manual" ]; then ok "nenhum resto do fluxo de sugestão (kit-settings.suggested) em docs, skills e scripts"; else ko "nenhum resto do fluxo de sugestão" "$manual"; fi
  # A tabela LSP do stacks.md tem os mesmos plugins e binarios do templates/lsp-plugins.txt.
  lsp_tpl="$(tr -d '\r' <"$REPO/plugins/kit/templates/lsp-plugins.txt" | awk -F'|' 'NF { print $1 "@claude-plugins-official " $2 }' | sort)"
  lsp_doc="$(tr -d '\r' <"$REPO/plugins/kit/skills/init/stacks.md" | awk -F'|' '/@claude-plugins-official/ { p = $4; b = $5; gsub(/[ `]/, "", p); gsub(/[ `]/, "", b); print p " " b }' | sort)"
  if [ -n "$lsp_tpl" ] && [ "$lsp_tpl" = "$lsp_doc" ]; then ok "stacks.md: tabela LSP igual a templates/lsp-plugins.txt"
  else ko "stacks.md: tabela LSP igual a templates/lsp-plugins.txt" "$(diff <(printf '%s\n' "$lsp_tpl") <(printf '%s\n' "$lsp_doc") | tr '\n' ' ')"; fi
  lsp_marketplace="${HOME}/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json"
  if [ -f "$lsp_marketplace" ]; then
    lsp_missing=""
    while IFS='|' read -r plugin bin _; do
      [ -n "$plugin" ] || continue
      jq -e --arg n "$plugin" --arg b "$bin" '[.plugins[] | select(.name == $n) | .lspServers[]?.command] | index($b) != null' "$lsp_marketplace" >/dev/null 2>&1 || lsp_missing+="$plugin/$bin "
    done < <(tr -d '\r' <"$REPO/plugins/kit/templates/lsp-plugins.txt")
    if [ -z "$lsp_missing" ]; then ok "lsp-plugins.txt: nomes e binários conferem com o marketplace oficial instalado"; else ko "lsp-plugins.txt: nomes e binários conferem com o marketplace oficial" "$lsp_missing"; fi
  else
    echo "  pulado conferência com o marketplace oficial (não instalado)"
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
  for s in spec plan execute fix hunt init map; do
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
ALL_GROUPS+=(semjq forma_shell apoio_init wave_base map_partition setup notify guardas estaticas)

# Grupos afetados por um arquivo alterado (padroes casados contra "fx:<fixture>" ou o nome do grupo).
# "*" e a suite inteira; arquivo sem script nem fixture (docs, skills, agents) so roda as estaticas.
groups_for_file() {
  local hooks="semjq forma_shell"
  case "$1" in
    plugins/kit/scripts/lib.sh | tests/run-tests.sh | tests/sample/*) echo "*" ;;
    plugins/kit/scripts/guard-bash.sh) echo "fx:guard-bash.json $hooks" ;;
    plugins/kit/scripts/guard-files.sh) echo "fx:guard-files*.json $hooks guardas" ;;
    plugins/kit/scripts/verify-gate.sh) echo "fx:verify-gate*.json $hooks guardas" ;;
    plugins/kit/scripts/notify.sh) echo "fx:notify.json fx:verify-gate-notify.json notify $hooks" ;;
    plugins/kit/scripts/format.sh | plugins/kit/scripts/advise.sh | plugins/kit/scripts/pre-compact.sh | plugins/kit/scripts/session-context.sh)
      local b="${1##*/}"; echo "fx:${b%.sh}.json $hooks" ;;
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
