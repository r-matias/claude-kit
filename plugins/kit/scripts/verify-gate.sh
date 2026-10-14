#!/usr/bin/env bash
# Stop: roda verify_on_stop, key_parity e coupled_changes sobre os arquivos alterados.
# Todas as falhas saem numa unica mensagem com exit 2; Claude continua ate resolver.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

[ "$(kit_field '.stop_hook_active')" = "true" ] && exit 0

CWD="$(kit_cwd)"
command -v git >/dev/null 2>&1 || exit 0
TOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
TOP="$(kit_norm_path "$TOP")"

CHANGED="$(
  {
    git -c core.quotepath=off -C "$TOP" diff --name-only HEAD 2>/dev/null ||
      git -c core.quotepath=off -C "$TOP" diff --name-only --cached 2>/dev/null
    git -c core.quotepath=off -C "$TOP" ls-files --others --exclude-standard 2>/dev/null
  } | tr -d '\r' | sort -u
)"
[ -n "$CHANGED" ] || exit 0

# Agrupa arquivos alterados pelo kit.json mais proximo (monorepo).
declare -A GROUP=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  KIT_JSON="" KIT_ROOT=""
  find_kit_json "$TOP/$f" || continue
  GROUP["$KIT_ROOT"]+="$TOP/$f"$'\n'
done <<<"$CHANGED"
[ "${#GROUP[@]}" -gt 0 ] || exit 0

GIT_DIR_ABS="$(git -C "$TOP" rev-parse --absolute-git-dir 2>/dev/null)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
OUT="$TMPD/out"

FAILS=()
declare -A SKIP_RELEASED=()

where_label() {
  if [ "$KIT_ROOT" = "$TOP" ]; then printf ''; else printf ' (%s)' "${KIT_ROOT#"$TOP"/}"; fi
}

is_changed() {
  local want="${1#./}" r
  for r in "${RELS[@]}"; do [ "$r" = "$want" ] && return 0; done
  return 1
}

run_verify() {
  local matched=() rel glob state="" stamp="" files="" m key cmd
  for rel in "${RELS[@]}"; do
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      if glob_match "$glob" "$rel"; then matched+=("$rel"); break; fi
    done < <(kit_list source_globs)
  done
  [ "${#matched[@]}" -gt 0 ] || return 0

  # Estado ja verificado com sucesso nao roda de novo.
  if [ -n "$GIT_DIR_ABS" ]; then
    state="$(
      {
        cat "$KIT_JSON"
        git -C "$KIT_ROOT" diff HEAD -- . 2>/dev/null
        for m in "${matched[@]}"; do
          printf '%s\n' "$m"
          [ -f "$KIT_ROOT/$m" ] && git hash-object "$KIT_ROOT/$m" 2>/dev/null
        done
      } | git hash-object --stdin 2>/dev/null
    )"
    stamp="$GIT_DIR_ABS/kit-verify-$(printf '%s' "$KIT_ROOT" | git hash-object --stdin | cut -c1-12)"
    [ -n "$state" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$state" ] && return 0
  fi

  for m in "${matched[@]}"; do files+="$(kit_quote "$m") "; done
  files="${files% }"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    cmd="$(kit_cmd "$key")"
    [ -n "$cmd" ] || continue
    cmd="$(kit_subst_files "$cmd" "$files")"
    if ! kit_run "$cmd" "$OUT"; then
      FAILS+=("'$key' falhou em ${KIT_ROOT}
comando: $cmd
$(tail -n 60 "$OUT")")
      return 0
    fi
  done < <(kit_list verify_on_stop)

  [ -n "$stamp" ] && [ -n "$state" ] && printf '%s' "$state" >"$stamp"
  return 0
}

run_key_parity() {
  local n i j f msg hit files=() labels=() problems union base dup missing
  n="$(kit_rule_count key_parity)"
  for ((i = 0; i < ${n:-0}; i++)); do
    mapfile -t files < <(kit_rule_list key_parity "$i" files)
    [ "${#files[@]}" -gt 0 ] || continue
    hit=0
    for f in "${files[@]}"; do is_changed "$f" && { hit=1; break; }; done
    [ "$hit" -eq 1 ] || continue
    msg="$(kit_rule_str key_parity "$i" message "Chaves divergentes entre arquivos pareados.")"

    # Rotulo curto (nome do arquivo) quando nao ha nomes repetidos; senao o caminho declarado.
    labels=()
    dup="$(for f in "${files[@]}"; do printf '%s\n' "${f##*/}"; done | sort | uniq -d)"
    for f in "${files[@]}"; do
      if [ -z "$dup" ]; then labels+=("${f##*/}"); else labels+=("${f#./}"); fi
    done

    problems=""
    union="$TMPD/kp-union"
    : >"$union"
    for j in "${!files[@]}"; do
      f="${files[$j]#./}"
      rm -f "$TMPD/kp-$j"
      if [ ! -f "$KIT_ROOT/$f" ]; then
        problems+="  $f não existe"$'\n'
        continue
      fi
      if ! kit_json_keys "$KIT_ROOT/$f" >"$TMPD/kp-$j"; then
        rm -f "$TMPD/kp-$j"
        problems+="  $f não é JSON válido"$'\n'
        continue
      fi
      cat "$TMPD/kp-$j" >>"$union"
    done
    LC_ALL=C sort -u -o "$union" "$union"

    missing="$(
      for j in "${!files[@]}"; do
        [ -f "$TMPD/kp-$j" ] || continue
        LC_ALL=C comm -23 "$union" "$TMPD/kp-$j" | awk -v l="${labels[$j]}" '{ print $0 "\t" l }'
      done | awk -F'\t' '{ if ($1 in a) a[$1] = a[$1] ", " $2; else { a[$1] = $2; k[++c] = $1 } }
        END { for (x = 1; x <= c; x++) print "  " k[x] " falta em " a[k[x]] }' | LC_ALL=C sort
    )"
    if [ -n "$missing" ]; then
      local total
      total="$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
      problems+="$(printf '%s\n' "$missing" | head -n 50)"$'\n'
      [ "$total" -gt 50 ] && problems+="  ... e mais $((total - 50)) chave(s)"$'\n'
    fi

    if [ -n "$problems" ]; then
      FAILS+=("[key_parity]$(where_label) $msg
${problems%$'\n'}")
    fi
  done
}

run_coupled() {
  local n i rel g msg when=() require=() triggers=() ok violations=() skip_file skip_text
  n="$(kit_rule_count coupled_changes)"
  for ((i = 0; i < ${n:-0}; i++)); do
    mapfile -t when < <(kit_rule_list coupled_changes "$i" when)
    mapfile -t require < <(kit_rule_list coupled_changes "$i" require)
    msg="$(kit_rule_str coupled_changes "$i" message "Arquivos acoplados precisam mudar juntos.")"
    triggers=()
    for rel in "${RELS[@]}"; do
      for g in "${when[@]}"; do
        [ -n "$g" ] || continue
        if glob_match "$g" "$rel"; then triggers+=("$rel"); break; fi
      done
    done
    [ "${#triggers[@]}" -gt 0 ] || continue
    ok=0
    for rel in "${RELS[@]}"; do
      for g in "${require[@]}"; do
        [ -n "$g" ] || continue
        if glob_match "$g" "$rel"; then ok=1; break 2; fi
      done
    done
    [ "$ok" -eq 1 ] && continue
    local shown
    shown="$(printf '%s\n' "${triggers[@]:0:20}" | paste -sd ',' - | sed 's/,/, /g')"
    [ "${#triggers[@]}" -gt 20 ] && shown+=" ... (+$((${#triggers[@]} - 20)))"
    violations+=("[coupled_changes]$(where_label) $msg
  disparado por: ${shown}
  esperado também alteração em: ${require[*]}")
  done
  [ "${#violations[@]}" -gt 0 ] || return 0

  skip_file="$KIT_ROOT/.claude/kit-skip"
  if [ -f "$skip_file" ]; then
    skip_text="$(tr -d '\r' <"$skip_file" | sed '/^[[:space:]]*$/d' | head -n 1)"
    if [ -n "$skip_text" ]; then
      SKIP_RELEASED["$KIT_ROOT"]="$(printf '%s\n' "${violations[@]}" | sed -n 's/^\[coupled_changes\][^ ]* //p' | paste -sd ';' -)"
      return 0
    fi
    violations[0]+=$'\n'"  .claude/kit-skip está vazio: escreva uma linha de justificativa para liberar."
  else
    violations[0]+=$'\n'"  Se esta mudança realmente não exige o par, grave uma linha de justificativa em .claude/kit-skip (fica registrada)."
  fi
  FAILS+=("${violations[@]}")
}

# Apaga o kit-skip usado e registra a justificativa.
consume_skip() {
  local root="$1" skip_file="$1/.claude/kit-skip" text log released stamp
  [ -f "$skip_file" ] || return 0
  text="$(tr -d '\r' <"$skip_file" | sed '/^[[:space:]]*$/d' | head -n 1)"
  [ -n "$text" ] || return 0
  released="${SKIP_RELEASED[$root]:-nenhuma regra violada}"
  stamp="$(date '+%Y-%m-%d %H:%M')"
  if [ -f "$root/docs/claude-adoption.md" ]; then
    log="$root/docs/claude-adoption.md"
  elif [ -f "$TOP/docs/claude-adoption.md" ]; then
    log="$TOP/docs/claude-adoption.md"
  else
    log="$root/.claude/kit-skip.log"
  fi
  if [ "${log##*/}" = "claude-adoption.md" ] && ! grep -q '^## Registro de kit-skip' "$log"; then
    printf '\n## Registro de kit-skip\n\n' >>"$log"
  fi
  printf -- '- %s — %s — liberado: %s\n' "$stamp" "$text" "$released" >>"$log"
  rm -f "$skip_file"
}

ROOTS=()
while IFS= read -r r; do ROOTS+=("$r"); done < <(printf '%s\n' "${!GROUP[@]}" | sort)

for root in "${ROOTS[@]}"; do
  KIT_ROOT="$root"
  KIT_JSON="$root/.claude/kit.json"
  RELS=()
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    rel="$(kit_rel "$abs")"
    case "$rel" in .claude/kit-skip | .claude/kit-skip.log) continue ;; esac
    RELS+=("$rel")
  done <<<"${GROUP[$root]}"

  run_verify
  run_key_parity
  run_coupled
done

if [ "${#FAILS[@]}" -gt 0 ]; then
  {
    echo "kit verify-gate: ${#FAILS[@]} problema(s) neste turno."
    n=0
    for f in "${FAILS[@]}"; do
      n=$((n + 1))
      echo
      echo "$n) $f"
    done
    echo
    echo "Corrija a causa e tente terminar de novo."
  } >&2
  exit 2
fi

for root in "${ROOTS[@]}"; do consume_skip "$root"; done
exit 0
