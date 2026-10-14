#!/usr/bin/env bash
# Passa as fixtures de tests/fixtures pelos scripts do kit e confere decisao, exit code e saidas.
# Uso: tests/run-tests.sh [filtro-por-nome]
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPTS="$REPO/plugins/kit/scripts"
FILTER="${1:-}"

command -v jq >/dev/null 2>&1 || { echo "jq nao encontrado" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git nao encontrado" >&2; exit 1; }

PASS=0
FAIL=0
FAILED=()
TMP_ALL="$(mktemp -d)"
trap 'rm -rf "$TMP_ALL"' EXIT

# Caminho no formato que o Claude Code envia na plataforma atual.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

native_join() {
  local base="$1" rel="$2"
  if command -v cygpath >/dev/null 2>&1; then printf '%s\\%s' "$base" "${rel//\//\\}"; else printf '%s/%s' "$base" "$rel"; fi
}

git_q() { git -c user.name=kit-test -c user.email=kit@test -c init.defaultBranch=main -c core.autocrlf=false "$@" >/dev/null 2>&1; }

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

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); FAILED+=("$1: $2"); printf '  FALHA %s -- %s\n' "$1" "$2"; }

# Monta um workspace novo: sample (git, commitado), nokit (git sem kit.json) e nogit.
setup_ws() {
  local case_json="$1" ws kit_patch change plan
  ws="$(mktemp -d "$TMP_ALL/ws.XXXXXX")"
  cp -r "$HERE/sample" "$ws/sample"
  mkdir -p "$ws/nokit/src" "$ws/nogit"
  printf 'x\n' >"$ws/nokit/notes.md"

  kit_patch="$(jq -c '.kit // empty' <<<"$case_json")"
  if [ -n "$kit_patch" ]; then
    jq --argjson p "$kit_patch" '. * $p' "$ws/sample/.claude/kit.json" >"$ws/kit.tmp" && mv "$ws/kit.tmp" "$ws/sample/.claude/kit.json"
  fi
  plan="$(jq -r '.plan // empty' <<<"$case_json")"
  if [ -n "$plan" ]; then
    mkdir -p "$ws/sample/docs/specs/feat"
    printf '%b' "$plan" >"$ws/sample/docs/specs/feat/PLAN.md"
  fi
  local base
  base="$(case_base "$ws" "$case_json")"
  [ "$base" = "$ws/sample" ] && write_map "$ws/sample" "$(jq -c '.files // {}' <<<"$case_json")"

  git_q init "$ws/sample"
  git_q -C "$ws/sample" add -A
  git_q -C "$ws/sample" commit -m init
  git_q init "$ws/nokit"
  git_q -C "$ws/nokit" add -A
  git_q -C "$ws/nokit" commit -m init
  printf 'class X {}\n' >"$ws/nokit/src/X.cs"

  # Pasta-mae sem git com repositorios filhos: workspace.repos = {nome: {caminho: conteudo}}.
  if [ "$base" = "$ws/mroot" ]; then
    mkdir -p "$ws/mroot"
    local repo
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      mkdir -p "$ws/mroot/$repo"
      write_map "$ws/mroot/$repo" "$(jq -c --arg r "$repo" '.workspace.repos[$r]' <<<"$case_json")"
      git_q init "$ws/mroot/$repo"
      git_q -C "$ws/mroot/$repo" add -A
      git_q -C "$ws/mroot/$repo" commit -m init
    done < <(jq -r '.workspace.repos // {} | keys_unsorted[]' <<<"$case_json" | tr -d '\r')
    write_map "$ws/mroot" "$(jq -c '.files // {}' <<<"$case_json")"
  fi

  while IFS= read -r change; do
    [ -n "$change" ] || continue
    mkdir -p "$(dirname "$base/$change")"
    printf '// alterado\n' >>"$base/$change"
  done < <(jq -r '.change // empty | if type == "array" then .[] else . end' <<<"$case_json" | tr -d '\r')
  write_map "$base" "$(jq -c '.edit // {}' <<<"$case_json")"

  # touch: {caminho: minutos atras} para simular arquivos antigos.
  local k mins
  while IFS=$'\t' read -r k mins; do
    [ -n "$k" ] || continue
    touch -d "@$(($(date +%s) - mins * 60))" "$base/$k"
  done < <(jq -r '(.touch // {}) | to_entries[] | "\(.key)\t\(.value)"' <<<"$case_json" | tr -d '\r')
  printf '%s' "$ws"
}

case_base() {
  if jq -e '.workspace' <<<"$2" >/dev/null 2>&1; then printf '%s' "$1/mroot"; else printf '%s' "$1/sample"; fi
}

# Grava {caminho: valor} sob a raiz dada: string vira conteudo, objeto/array vira JSON, null apaga.
write_map() {
  local root="$1" map="$2" k v t dest
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    v="$(jq -c --arg k "$k" '.[$k]' <<<"$map")"
    t="$(jq -r 'type' <<<"$v" | tr -d '\r')"
    dest="$root/$k"
    case "$t" in
      null) rm -f "$dest" ;;
      string) mkdir -p "$(dirname "$dest")"; jq -j '.' <<<"$v" | tr -d '\r' >"$dest" ;;
      *) mkdir -p "$(dirname "$dest")"; jq '.' <<<"$v" | tr -d '\r' >"$dest" ;;
    esac
  done < <(jq -r 'keys_unsorted[]' <<<"$map" | tr -d '\r')
}

# Lista de strings de um campo do caso (string unica ou array).
case_list() {
  jq -r --arg f "$1" '.[$f] // empty | if type == "array" then .[] else . end' <<<"$2" | tr -d '\r'
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
  local script="$1" case_json="$2" name ws base input out err code cwd file tool sid
  name="$(jq -r '.name' <<<"$case_json")"
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then return; fi

  ws="$(setup_ws "$case_json")"
  base="$(case_base "$ws" "$case_json")"
  cwd="$(jq -r '.cwd // empty' <<<"$case_json")"
  case "$cwd" in
    __NOKIT__) cwd="$(native_path "$ws/nokit")" ;;
    __NOGIT__) cwd="$(native_path "$ws/nogit")" ;;
    "") cwd="$(native_path "$base")" ;;
    *) cwd="$(native_join "$(native_path "$base")" "$cwd")" ;;
  esac
  sid="teste-${ws##*.}"
  mkdir -p "$ws/tmp"

  case "$script" in
    guard-bash.sh)
      input="$(jq -cn --arg c "$(jq -r '.command' <<<"$case_json")" --arg d "$cwd" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')" ;;
    guard-files.sh | format.sh | advise.sh)
      tool="$(jq -r '.tool' <<<"$case_json")"
      file="$(resolve_token "$(jq -r '.file' <<<"$case_json")" "$ws" "$base")"
      local ev="PreToolUse"; [ "$script" != "guard-files.sh" ] && ev="PostToolUse"
      input="$(jq -cn --arg t "$tool" --arg f "$file" --arg d "$cwd" --arg e "$ev" --arg s "$sid" \
        '{hook_event_name: $e, session_id: $s, tool_name: $t, tool_input: {file_path: $f}, cwd: $d}')" ;;
    verify-gate.sh)
      input="$(jq -cn --arg d "$cwd" --arg s "$sid" --argjson a "$(jq '.stop_hook_active // false' <<<"$case_json")" \
        '{hook_event_name: "Stop", session_id: $s, stop_hook_active: $a, cwd: $d}')" ;;
    session-context.sh)
      input="$(jq -cn --arg d "$cwd" --arg s "$sid" --arg o "$(jq -r '.source // "startup"' <<<"$case_json")" \
        '{hook_event_name: "SessionStart", session_id: $s, source: $o, cwd: $d}')" ;;
    pre-compact.sh)
      input="$(jq -cn --arg d "$cwd" --arg s "$sid" '{hook_event_name: "PreCompact", session_id: $s, trigger: "auto", cwd: $d}')" ;;
  esac

  local -a args=()
  while IFS= read -r s; do [ -n "$s" ] && args+=("$s"); done < <(jq -r '(.args // [])[]' <<<"$case_json" | tr -d '\r')

  out="$ws/stdout"
  err="$ws/stderr"
  local cpath
  cpath="$(case_path "$ws" "$(jq -r '.fake_claude // empty' <<<"$case_json" | tr -d '\r')")"
  (cd "$ws" && PATH="$cpath" TMPDIR="$ws/tmp" env -u CLAUDE_PROJECT_DIR bash "$SCRIPTS/$script" "${args[@]}" <<<"$input" >"$out" 2>"$err")
  code=$?
  if [ "$(jq -r '.repeat_empty // false' <<<"$case_json")" = "true" ]; then
    (cd "$ws" && PATH="$cpath" TMPDIR="$ws/tmp" env -u CLAUDE_PROJECT_DIR bash "$SCRIPTS/$script" "${args[@]}" <<<"$input" >"$ws/stdout2" 2>/dev/null)
  fi

  local expect exp_exit why=""
  expect="$(jq -r '.expect // empty' <<<"$case_json")"
  exp_exit="$(jq -r 'if has("exit") then .exit else 0 end' <<<"$case_json")"

  [ "$code" = "$exp_exit" ] || why="exit $code, esperado $exp_exit"
  case "$expect" in
    deny)
      [ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$out" 2>/dev/null)" = "deny" ] || why="${why:+$why; }esperava deny, stdout='$(head -c 200 "$out")'" ;;
    allow)
      [ ! -s "$out" ] || why="${why:+$why; }esperava liberar, stdout='$(head -c 200 "$out")'" ;;
  esac
  local s pos last=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qF -- "$s" "$err" || why="${why:+$why; }stderr sem '$s'"
  done < <(case_list stderr "$case_json")
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ! grep -qF -- "$s" "$err" || why="${why:+$why; }stderr contem '$s'"
  done < <(case_list stderr_not "$case_json")
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    pos="$(grep -nF -- "$s" "$err" | head -n 1 | cut -d: -f1)"
    if [ -z "$pos" ] || [ "$pos" -lt "$last" ]; then why="${why:+$why; }ordem do stderr: '$s' fora de ordem"; else last="$pos"; fi
  done < <(case_list stderr_order "$case_json")
  if [ "$script" = "verify-gate.sh" ] && [ "$code" = "2" ]; then
    [ "$(grep -c '^kit verify-gate:' "$err")" = "1" ] || why="${why:+$why; }esperava uma unica mensagem do gate"
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ ! -e "$base/$s" ] || why="${why:+$why; }deveria nao existir: $s"
  done < <(jq -r '(.after.absent // [])[]' <<<"$case_json" | tr -d '\r')
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ -e "$base/$s" ] || why="${why:+$why; }deveria existir: $s"
  done < <(jq -r '(.after.exists // [])[]' <<<"$case_json" | tr -d '\r')
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    local want
    while IFS= read -r want; do
      [ -n "$want" ] || continue
      grep -qF -- "$want" "$base/$s" 2>/dev/null || why="${why:+$why; }$s sem '$want'"
    done < <(jq -r --arg k "$s" '.after.contains[$k] | if type == "array" then .[] else . end' <<<"$case_json" | tr -d '\r')
  done < <(jq -r '(.after.contains // {}) | keys_unsorted[]' <<<"$case_json" | tr -d '\r')
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qF -- "$s" "$out" || why="${why:+$why; }stdout sem '$s'"
  done < <(jq -r '(.stdout // [])[]' <<<"$case_json" | tr -d '\r')
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    ! grep -qF -- "$s" "$out" || why="${why:+$why; }stdout contem '$s'"
  done < <(jq -r '(.stdout_not // [])[]' <<<"$case_json" | tr -d '\r')
  if [ "$(jq -r '.stdout_empty // false' <<<"$case_json")" = "true" ] && [ -s "$out" ]; then
    why="${why:+$why; }stdout deveria ser vazio"
  fi
  local has_out_expect
  has_out_expect="$(jq -r 'has("stdout") or has("json_check")' <<<"$case_json")"
  if [ "$expect" != "deny" ] && [ "$script" != "session-context.sh" ] && [ "$has_out_expect" != "true" ] && [ -s "$out" ]; then
    why="${why:+$why; }stdout deveria ser vazio"
  fi
  s="$(jq -r '.reason // empty' <<<"$case_json" | tr -d '\r')"
  if [ -n "$s" ] && ! jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$out" 2>/dev/null | grep -qF -- "$s"; then
    why="${why:+$why; }motivo sem '$s': $(head -c 300 "$out")"
  fi
  s="$(jq -r '.json_check // empty' <<<"$case_json" | tr -d '\r')"
  if [ -n "$s" ] && ! jq -e "$s" "$out" >/dev/null 2>&1; then
    why="${why:+$why; }json_check falhou ($s): $(head -c 300 "$out")"
  fi
  if [ "$(jq -r '.repeat_empty // false' <<<"$case_json")" = "true" ] && [ -s "$ws/stdout2" ]; then
    why="${why:+$why; }segunda execucao deveria ter saida vazia: $(head -c 200 "$ws/stdout2")"
  fi

  [ -n "${KIT_TEST_DEBUG:-}" ] && { echo "--- input: $input"; echo "--- stdout:"; cat "$out"; echo "--- stderr:"; cat "$err"; }
  if [ -z "$why" ]; then ok "$name"; else
    [ -s "$err" ] && why="$why; stderr='$(tail -c 300 "$err" | tr '\n' ' ')'"
    ko "$name" "$why"
  fi
}

for fx in "$HERE"/fixtures/*.json; do
  script="$(jq -r '.script' "$fx")"
  echo "$script"
  while IFS= read -r c; do
    run_case "$script" "$c"
  done < <(jq -c '(.defaults // {}) as $d | .cases[] | $d * .' "$fx" | tr -d '\r')
done

echo "sem jq no PATH"
if [ -z "$FILTER" ] || [[ "sem jq" == *"$FILTER"* ]]; then
  NOJQ_PATH="$(path_without jq)"
  BASH_BIN="$(command -v bash)"
  if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
    ko "PATH de teste sem jq" "jq ainda encontrado em $(PATH="$NOJQ_PATH" command -v jq)"
  else
    for s in guard-bash.sh guard-files.sh; do
      out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/$s" 2>"$TMP_ALL/nojq.err")"
      code=$?
      if [ "$code" = "2" ] && [ -z "$out" ] && grep -qF "kit: jq não encontrado; instale o jq" "$TMP_ALL/nojq.err"; then
        ok "$s sem jq bloqueia com exit 2"
      else ko "$s sem jq bloqueia com exit 2" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
    done
    for s in format.sh verify-gate.sh advise.sh pre-compact.sh; do
      out="$(printf '%s' '{"cwd":"."}' | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/$s" 2>"$TMP_ALL/nojq.err")"
      code=$?
      if [ "$code" = "0" ] && [ -z "$out" ] && [ ! -s "$TMP_ALL/nojq.err" ]; then
        ok "$s sem jq sai 0 sem fazer nada"
      else ko "$s sem jq sai 0 sem fazer nada" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
    done
    out="$(printf '%s' '{"cwd":"."}' | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/session-context.sh" 2>"$TMP_ALL/nojq.err")"
    code=$?
    if [ "$code" = "0" ] && grep -qF 'kit: jq não encontrado' <<<"$out" && grep -qE '`(winget install jqlang.jq|brew install jq|sudo apt install jq)`' <<<"$out" &&
      grep -qF '/kit:setup' <<<"$out" && [ ! -s "$TMP_ALL/nojq.err" ]; then
      ok "session-context.sh sem jq avisa com o comando de instalação e /kit:setup"
    else ko "session-context.sh sem jq avisa com o comando de instalação e /kit:setup" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
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
    if [ ! -x "$GIT_BASH" ]; then
      ko "simulacao de PATH sem bash" "Git Bash nao encontrado em $GIT_BASH"
    elif PATH="$SIM_PATH" command -v bash >/dev/null 2>&1; then
      ko "simulacao de PATH sem bash" "bash ainda encontrado em $(PATH="$SIM_PATH" command -v bash)"
    else
      ok "forma exec falharia: bash fora do PATH simulado"
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
    fi
  else
    echo "  pulado simulacao de PATH sem bash (so no Windows)"
  fi
fi

echo "scripts de apoio do init"
if [ -z "$FILTER" ] || [[ "merge-json inventory" == *"$FILTER"* ]]; then
  U="$(mktemp -d "$TMP_ALL/unit.XXXXXX")"
  M="$SCRIPTS/merge-json.sh"
  printf '%s' '{"permissions":{"allow":["A","B"],"deny":["X"]},"model":"opus"}' >"$U/old.json"
  printf '%s' '{"permissions":{"allow":["B","C"],"ask":["Q"]},"model":"sonnet","enabledPlugins":{"kit@claude-kit":true}}' >"$U/new.json"
  bash "$M" "$U/old.json" "$U/new.json" >"$U/merged.json" 2>"$U/conflicts"
  if jq -e '.permissions.allow == ["A","B","C"] and .permissions.deny == ["X"] and .permissions.ask == ["Q"] and .model == "opus" and .enabledPlugins["kit@claude-kit"] == true' "$U/merged.json" >/dev/null 2>&1; then
    ok "merge-json: chave a chave, arrays por uniao, existente vence"
  else ko "merge-json: chave a chave, arrays por uniao, existente vence" "$(tr '\n' ' ' <"$U/merged.json")"; fi
  if grep -qF 'conflito em $.model' "$U/conflicts"; then ok "merge-json: conflito reportado no stderr"; else ko "merge-json: conflito reportado no stderr" "$(cat "$U/conflicts")"; fi
  if bash "$M" "$U/nao-existe.json" "$U/new.json" | jq -e '.model == "sonnet"' >/dev/null 2>&1; then ok "merge-json: existente ausente usa a proposta"; else ko "merge-json: existente ausente usa a proposta" ""; fi
  if bash "$M" --check "$U/old.json" "$U/merged.json" 2>/dev/null; then ok "merge-json --check: so adicoes passa"; else ko "merge-json --check: so adicoes passa" ""; fi
  if ! bash "$M" --check "$U/merged.json" "$U/old.json" 2>"$U/lost" && grep -qF '$.enabledPlugins: removido' "$U/lost"; then
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
  bash "$SCRIPTS/inventory.sh" "$U/adopt" >"$U/inv" 2>&1
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
fi

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
  base="$(bash "$WS" "$WB" 2>/dev/null)"
  printf 'b\n' >>"$WB/a.txt"
  printf 'novo\n' >"$WB/n.txt"
  printf 'x\n' >"$WB/ign.txt"
  now="$(bash "$WS" "$WB" 2>/dev/null)"
  wdiff="$(git -C "$WB" diff --name-status "$base" "$now" 2>/dev/null | tr -d '\r' | paste -sd' ' -)"
  if [ "$wdiff" = "$(printf 'M\ta.txt A\tn.txt')" ]; then ok "wave-base: diff da wave tem alterado e novo, sem ignorado nem o que já existia"; else ko "wave-base: diff da wave tem alterado e novo, sem ignorado nem o que já existia" "$wdiff"; fi
  if [ "$(git -C "$WB" diff --cached --name-only | tr -d '\r')" = "s.txt" ]; then ok "wave-base: index do usuário intacto"; else ko "wave-base: index do usuário intacto" "$(git -C "$WB" diff --cached --name-only | tr '\n' ' ')"; fi
  if [ "$(git -C "$WB" rev-list --count HEAD | tr -d '\r')" = "1" ]; then ok "wave-base: nenhum commit criado"; else ko "wave-base: nenhum commit criado" ""; fi
  if ! bash "$WS" "$(mktemp -d "$TMP_ALL/nogit.XXXXXX")" >/dev/null 2>&1; then ok "wave-base: fora de repo git sai com erro"; else ko "wave-base: fora de repo git sai com erro" ""; fi
fi

echo "setup"
if [ -z "$FILTER" ] || [[ "setup" == *"$FILTER"* ]]; then
  SU="$SCRIPTS/setup.sh"
  TPL_USER="$REPO/plugins/kit/templates/user-settings.json"
  # Stubs de plataforma e versao: uname responde $1, claude responde $2. WSL via WSL_DISTRO_NAME.
  setup_bin() {
    local d
    d="$(mktemp -d "$TMP_ALL/setup-bin.XXXXXX")"
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" >"$d/uname"
    printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "${2:-9.9.9}" >"$d/claude"
    chmod +x "$d/uname" "$d/claude"
    printf '%s' "$d"
  }
  LINUX_BIN="$(setup_bin Linux)"
  WIN_BIN="$(setup_bin MINGW64_NT-10.0-26100)"
  MAC_BIN="$(setup_bin Darwin)"
  # Uso: run_setup <config> <PATH> <subcomando...>. Sem WSL_DISTRO_NAME herdado.
  run_setup() {
    local cfg="$1" path="$2"
    shift 2
    env -u WSL_DISTRO_NAME CLAUDE_CONFIG_DIR="$cfg" PATH="$path" bash "$SU" "$@"
  }
  NOJQ_PATH="${NOJQ_PATH:-$(path_without jq)}"

  # settings inexistente: a proposta vira o settings, kit ligado em todos.
  C1="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")/claude"
  run_setup "$C1" "$LINUX_BIN:$NOCLAUDE_PATH" propose todos >"$TMP_ALL/su.out" 2>"$TMP_ALL/su.err"
  code=$?
  if [ "$code" = "0" ] && grep -qF '(novo)' "$TMP_ALL/su.out" && [ ! -e "$C1/settings.json" ]; then
    ok "setup propose: settings inexistente mostra diff e não grava"
  else ko "setup propose: settings inexistente mostra diff e não grava" "exit $code, $(head -c 300 "$TMP_ALL/su.err")"; fi
  run_setup "$C1" "$LINUX_BIN:$NOCLAUDE_PATH" apply >"$TMP_ALL/su.out" 2>"$TMP_ALL/su.err"
  code=$?
  if [ "$code" = "0" ] && jq -e --slurpfile t "$TPL_USER" '.permissions.deny == $t[0].permissions.deny and .sandbox.failIfUnavailable == true
      and .enabledPlugins["kit@claude-kit"] == true' "$C1/settings.json" >/dev/null 2>&1 && [ ! -e "$C1/settings.kit-proposta.json" ]; then
    ok "setup apply: settings inexistente criado com o template e kit ligado"
  else ko "setup apply: settings inexistente criado com o template e kit ligado" "exit $code, $(head -c 300 "$TMP_ALL/su.err")"; fi

  # settings existente: chaves preservadas, arrays unidos, opt-in desliga o kit no usuario.
  C2="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  printf '%s' '{"model":"opus","permissions":{"allow":["Bash(ls *)"],"deny":["Bash(rm *)","Bash(curl *)"]},"enabledPlugins":{"kit@claude-kit":true,"outro@mkt":true},"sandbox":{"enabled":true,"network":{"allowedDomains":["example.com"]}}}' >"$C2/settings.json"
  cp "$C2/settings.json" "$TMP_ALL/su.before"
  run_setup "$C2" "$LINUX_BIN:$NOCLAUDE_PATH" propose opt-in >"$TMP_ALL/su.out" 2>"$TMP_ALL/su.err" &&
    run_setup "$C2" "$LINUX_BIN:$NOCLAUDE_PATH" apply >>"$TMP_ALL/su.out" 2>>"$TMP_ALL/su.err"
  code=$?
  if [ "$code" = "0" ] && jq -e '.model == "opus" and .permissions.allow == ["Bash(ls *)"] and (.permissions.deny | index("Bash(rm *)") != null)
      and ([.permissions.deny[] | select(. == "Bash(curl *)")] | length) == 1 and (.permissions.deny | index("PowerShell") != null)
      and .enabledPlugins["outro@mkt"] == true and .enabledPlugins["kit@claude-kit"] == false
      and .sandbox.network.allowedDomains == ["example.com"] and .sandbox.failIfUnavailable == true' "$C2/settings.json" >/dev/null 2>&1; then
    ok "setup: settings existente preserva chaves, une arrays e opt-in desliga o kit"
  else ko "setup: settings existente preserva chaves, une arrays e opt-in desliga o kit" "exit $code, $(tr -d '\n' <"$C2/settings.json" | head -c 400)"; fi
  lost="$(bash "$SCRIPTS/merge-json.sh" --check "$TMP_ALL/su.before" "$C2/settings.json" 2>&1 | tr -d '\r')"
  if [ "$lost" = '$.enabledPlugins.kit@claude-kit: true -> false' ]; then ok "setup: única troca é enabledPlugins do kit"; else ko "setup: única troca é enabledPlugins do kit" "$lost"; fi

  # Proposta que remove valor: apply recusa e restaura o original.
  cp "$C2/settings.json" "$TMP_ALL/su.before"
  jq 'del(.model)' "$C2/settings.json" >"$C2/settings.kit-proposta.json"
  run_setup "$C2" "$LINUX_BIN:$NOCLAUDE_PATH" apply >"$TMP_ALL/su.out" 2>"$TMP_ALL/su.err"
  code=$?
  if [ "$code" = "1" ] && grep -qF '$.model: removido' "$TMP_ALL/su.err" && cmp -s "$TMP_ALL/su.before" "$C2/settings.json"; then
    ok "setup apply: proposta que remove valor é recusada e o settings restaurado"
  else ko "setup apply: proposta que remove valor é recusada e o settings restaurado" "exit $code, $(head -c 300 "$TMP_ALL/su.err")"; fi

  # Windows nativo simulado: sem sandbox, failIfUnavailable false; WSL mantem true.
  C3="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  out="$(run_setup "$C3" "$WIN_BIN:$NOCLAUDE_PATH" check 2>&1)"
  code=$?
  if [ "$code" = "0" ] && grep -qF 'plataforma: windows nativo — sem sandbox' <<<"$out"; then
    ok "setup check: Windows nativo simulado avisa que não há sandbox"
  else ko "setup check: Windows nativo simulado avisa que não há sandbox" "exit $code, $out"; fi
  run_setup "$C3" "$WIN_BIN:$NOCLAUDE_PATH" propose todos >/dev/null 2>&1
  if jq -e '.sandbox.failIfUnavailable == false and .sandbox.enabled == true' "$C3/settings.kit-proposta.json" >/dev/null 2>&1; then
    ok "setup propose: Windows nativo simulado usa failIfUnavailable false"
  else ko "setup propose: Windows nativo simulado usa failIfUnavailable false" "$(head -c 300 "$C3/settings.kit-proposta.json" 2>&1)"; fi
  C4="$(mktemp -d "$TMP_ALL/cfg.XXXXXX")"
  out="$(WSL_DISTRO_NAME=Ubuntu CLAUDE_CONFIG_DIR="$C4" PATH="$LINUX_BIN:$NOCLAUDE_PATH" bash "$SU" check 2>&1)"
  WSL_DISTRO_NAME=Ubuntu CLAUDE_CONFIG_DIR="$C4" PATH="$LINUX_BIN:$NOCLAUDE_PATH" bash "$SU" propose todos >/dev/null 2>&1
  if grep -qF 'plataforma: wsl2' <<<"$out" && jq -e '.sandbox.failIfUnavailable == true' "$C4/settings.kit-proposta.json" >/dev/null 2>&1; then
    ok "setup: WSL2 simulado mantém failIfUnavailable true"
  else ko "setup: WSL2 simulado mantém failIfUnavailable true" "$out"; fi
  rm -f "$C4/settings.kit-proposta.json"

  # jq ausente simulado: check falha com o comando de instalacao da plataforma; propose recusa.
  out="$(run_setup "$C4" "$WIN_BIN:$NOJQ_PATH" check 2>&1)"
  code=$?
  if [ "$code" = "1" ] && grep -qF 'falta jq — instale: winget install jqlang.jq' <<<"$out" && grep -qF 'ok git' <<<"$out"; then
    ok "setup check: jq ausente (Windows) falha com winget install jqlang.jq"
  else ko "setup check: jq ausente (Windows) falha com winget install jqlang.jq" "exit $code, $out"; fi
  out="$(run_setup "$C4" "$MAC_BIN:$NOJQ_PATH" check 2>&1)"
  if grep -qF 'falta jq — instale: brew install jq' <<<"$out"; then ok "setup check: jq ausente (macOS) sugere brew install jq"; else ko "setup check: jq ausente (macOS) sugere brew install jq" "$out"; fi
  out="$(run_setup "$C4" "$LINUX_BIN:$NOJQ_PATH" check 2>&1)"
  if grep -qF 'falta jq — instale: sudo apt install jq' <<<"$out"; then ok "setup check: jq ausente (Linux) sugere sudo apt install jq"; else ko "setup check: jq ausente (Linux) sugere sudo apt install jq" "$out"; fi
  run_setup "$C4" "$LINUX_BIN:$NOJQ_PATH" propose todos >/dev/null 2>&1
  code=$?
  if [ "$code" = "2" ] && [ ! -e "$C4/settings.json" ] && [ ! -e "$C4/settings.kit-proposta.json" ]; then ok "setup propose: sem jq recusa e não grava"; else ko "setup propose: sem jq recusa e não grava" "exit $code"; fi

  # Claude Code abaixo da minima: check falha com claude update.
  OLD_BIN="$(setup_bin Linux 2.1.200)"
  out="$(run_setup "$C4" "$OLD_BIN:$NOCLAUDE_PATH" check 2>&1)"
  code=$?
  if [ "$code" = "1" ] && grep -qF 'falta claude >= 2.1.295 (atual 2.1.200) — rode: claude update' <<<"$out"; then
    ok "setup check: Claude Code antigo falha com claude update"
  else ko "setup check: Claude Code antigo falha com claude update" "exit $code, $out"; fi
fi

echo "checagens estaticas"
if [ -z "$FILTER" ]; then
  stack_hits="$(grep -nE '(^|[^a-z_-])(dotnet|npm|npx|pnpm|yarn|pytest|uv run|pip|poetry|cargo|mvn|gradlew?|go (build|test|vet)|golangci-lint|ruff|prettier|eslint|tsc)([^a-z_-]|$)' "$SCRIPTS"/*.sh || true)"
  if [ -z "$stack_hits" ]; then ok "nenhum script referencia comando de stack"; else ko "nenhum script referencia comando de stack" "$stack_hits"; fi

  TPL="$REPO/plugins/kit/skills/plan/template.md"
  tpl_got="$(grep -E '^##+ |^  - (files|behavior|action|verify|done):' "$TPL" | sed -E 's/^(##+ [^—]*[^ —]).*/\1/; s/:.*//; s/^ *- //' | tr -d '\r' | paste -sd'|' -)"
  tpl_want="## must_haves|### truths|### artifacts|### tests|## Interfaces|## Wave 1|files|behavior|action|verify|done|## Wave final|## Decisões|## Riscos"
  if [ "$tpl_got" = "$tpl_want" ]; then ok "template do PLAN.md: seções e campos na ordem"; else ko "template do PLAN.md: seções e campos na ordem" "$tpl_got"; fi
  tpl_bad="$(grep -E '\[[ xX]\]' "$TPL" | grep -vE '^- \[ \] ([0-9]+\.|Checkpoint wave [0-9]+:|F[0-9]+\.) ' || true)"
  if [ -z "$tpl_bad" ]; then ok "template do PLAN.md: caixa so em tarefa, checkpoint e wave final"; else ko "template do PLAN.md: caixa so em tarefa, checkpoint e wave final" "$tpl_bad"; fi

  bad_json=""
  while IFS= read -r f; do
    jq empty "$f" >/dev/null 2>&1 || bad_json+="$f "
  done < <(find "$REPO" -name '*.json' -not -path '*/.git/*' -not -path '*/node_modules/*')
  if [ -z "$bad_json" ]; then ok "todos os JSON do repositorio sao validos"; else ko "JSON invalido" "$bad_json"; fi

  if command -v claude >/dev/null 2>&1; then
    if claude plugin validate "$REPO/plugins/kit" >"$TMP_ALL/validate" 2>&1; then ok "claude plugin validate plugins/kit"; else ko "claude plugin validate plugins/kit" "$(tail -n 20 "$TMP_ALL/validate")"; fi
    if claude plugin validate "$REPO" >"$TMP_ALL/validate" 2>&1; then ok "claude plugin validate (marketplace)"; else ko "claude plugin validate (marketplace)" "$(tail -n 20 "$TMP_ALL/validate")"; fi
  else
    echo "  pulado claude plugin validate (CLI nao encontrada)"
  fi
fi

echo
echo "$PASS passaram, $FAIL falharam"
if [ "$FAIL" -gt 0 ]; then
  printf ' - %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0
