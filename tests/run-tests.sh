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
  (cd "$ws" && TMPDIR="$ws/tmp" env -u CLAUDE_PROJECT_DIR bash "$SCRIPTS/$script" "${args[@]}" <<<"$input" >"$out" 2>"$err")
  code=$?
  if [ "$(jq -r '.repeat_empty // false' <<<"$case_json")" = "true" ]; then
    (cd "$ws" && TMPDIR="$ws/tmp" env -u CLAUDE_PROJECT_DIR bash "$SCRIPTS/$script" "${args[@]}" <<<"$input" >"$ws/stdout2" 2>/dev/null)
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

# PATH sem nenhum diretorio que tenha jq. Se o jq estiver junto das ferramentas basicas
# (ex.: /usr/bin no Linux), o diretorio e trocado por um espelho com links para tudo menos o jq.
path_without_jq() {
  local IFS=: dir out="" shim f
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    if [ -e "$dir/jq" ] || [ -e "$dir/jq.exe" ]; then
      if [ -e "$dir/bash" ] || [ -e "$dir/bash.exe" ] || [ -e "$dir/dirname" ] || [ -e "$dir/dirname.exe" ]; then
        shim="$(mktemp -d "$TMP_ALL/nojq.XXXXXX")"
        for f in "$dir"/*; do
          case "${f##*/}" in jq | jq.exe) continue ;; esac
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

echo "sem jq no PATH"
if [ -z "$FILTER" ] || [[ "sem jq" == *"$FILTER"* ]]; then
  NOJQ_PATH="$(path_without_jq)"
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
    for s in format.sh verify-gate.sh session-context.sh advise.sh pre-compact.sh; do
      out="$(printf '%s' '{"cwd":"."}' | PATH="$NOJQ_PATH" "$BASH_BIN" "$SCRIPTS/$s" 2>"$TMP_ALL/nojq.err")"
      code=$?
      if [ "$code" = "0" ] && [ -z "$out" ] && [ ! -s "$TMP_ALL/nojq.err" ]; then
        ok "$s sem jq sai 0 sem fazer nada"
      else ko "$s sem jq sai 0 sem fazer nada" "exit $code, stdout='$out', stderr='$(cat "$TMP_ALL/nojq.err")'"; fi
    done
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

echo "checagens estaticas"
if [ -z "$FILTER" ]; then
  stack_hits="$(grep -nE '(^|[^a-z_-])(dotnet|npm|npx|pnpm|yarn|pytest|uv run|pip|poetry|cargo|mvn|gradlew?|go (build|test|vet)|golangci-lint|ruff|prettier|eslint|tsc)([^a-z_-]|$)' "$SCRIPTS"/*.sh || true)"
  if [ -z "$stack_hits" ]; then ok "nenhum script referencia comando de stack"; else ko "nenhum script referencia comando de stack" "$stack_hits"; fi

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
