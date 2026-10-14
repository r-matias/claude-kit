#!/usr/bin/env bash
# Stop: roda verify_on_stop, key_parity e coupled_changes (level block) sobre os arquivos alterados
# de todos os repositorios da sessao. Todas as falhas saem numa unica mensagem com exit 2.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

[ "$(kit_field '.stop_hook_active')" = "true" ] && exit 0
command -v git >/dev/null 2>&1 || exit 0

CWD="$(kit_cwd)"
KIT_CEILING="$CWD"
SID="$(kit_field '.session_id')"

REPOS=()
while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(kit_repos "$CWD" "$SID")
[ "${#REPOS[@]}" -gt 0 ] || exit 0
MULTI=0
[ "${#REPOS[@]}" -gt 1 ] && MULTI=1

# Arquivos alterados (diff contra HEAD + nao rastreados) de todos os repositorios, caminho absoluto.
ALL=()
for repo in "${REPOS[@]}"; do
  while IFS= read -r f; do
    [ -n "$f" ] && ALL+=("$repo/$f")
  done < <(
    {
      git -c core.quotepath=off -C "$repo" diff --name-only HEAD 2>/dev/null ||
        git -c core.quotepath=off -C "$repo" diff --name-only --cached 2>/dev/null
      git -c core.quotepath=off -C "$repo" ls-files --others --exclude-standard 2>/dev/null
    } | tr -d '\r' | sort -u
  )
done
[ "${#ALL[@]}" -gt 0 ] || exit 0

# GROUP: arquivos por kit.json mais proximo (comandos). KITS: todo kit.json acima de algum arquivo
# alterado (checks de dominio enxergam todos os arquivos abaixo da sua raiz).
declare -A GROUP=()
declare -A KITS=()
for abs in "${ALL[@]}"; do
  first=1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ "$first" -eq 1 ]; then GROUP["$root"]+="$abs"$'\n'; first=0; fi
    KITS["$root"]=1
  done < <(kit_kit_roots "$abs")
done
[ "${#KITS[@]}" -gt 0 ] || exit 0

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
OUT="$TMPD/out"

FAILS=()
declare -A SKIP_RELEASED=()

# Nome do repositorio que contem um caminho, relativo a pasta da sessao.
repo_name() {
  local p="$1" best="" r
  for r in "${REPOS[@]}"; do
    if [ "$p" = "$r" ] || [ "${p#"$r"/}" != "$p" ]; then
      [ "${#r}" -gt "${#best}" ] && best="$r"
    fi
  done
  if [ -z "$best" ] && [ "$p" = "$CWD" ]; then
    printf 'raiz'
  elif [ -z "$best" ]; then
    kit_rel_to "$CWD" "$p"
  elif [ "$best" = "$CWD" ]; then
    printf '%s' "${CWD##*/}"
  else
    kit_rel_to "$CWD" "$best"
  fi
}

add_fail() {
  if [ "$MULTI" -eq 1 ]; then FAILS+=("[$(repo_name "$KIT_ROOT")] $1"); else FAILS+=("$1"); fi
}

where_label() {
  if [ "$KIT_ROOT" = "$CWD" ] || [ "$MULTI" -eq 1 ]; then printf ''; else printf ' (%s)' "$(kit_rel_to "$CWD" "$KIT_ROOT")"; fi
}

run_verify() {
  local matched=() rel glob state="" stamp="" files="" m key cmd gitdir
  for rel in "${GROUP_RELS[@]}"; do
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      if glob_match "$glob" "$rel"; then matched+=("$rel"); break; fi
    done < <(kit_list source_globs)
  done
  [ "${#matched[@]}" -gt 0 ] || return 0

  # Estado ja verificado com sucesso nao roda de novo.
  gitdir="$(git -C "$KIT_ROOT" rev-parse --absolute-git-dir 2>/dev/null | tr -d '\r')"
  if [ -n "$gitdir" ]; then
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
    stamp="$gitdir/kit-verify-$(printf '%s' "$KIT_ROOT" | git hash-object --stdin | cut -c1-12)"
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
      add_fail "'$key' falhou em ${KIT_ROOT}
comando: $cmd
$(tail -n 60 "$OUT")"
      return 0
    fi
  done < <(kit_list verify_on_stop)

  [ -n "$stamp" ] && [ -n "$state" ] && printf '%s' "$state" >"$stamp"
  return 0
}

is_changed() {
  local want="${1#./}" r
  for r in "${RELS[@]}"; do [ "$r" = "$want" ] && return 0; done
  return 1
}

run_key_parity() {
  local n i j f msg hit files=() labels=() problems union dup missing total
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
      total="$(printf '%s\n' "$missing" | wc -l | tr -d ' ')"
      problems+="$(printf '%s\n' "$missing" | head -n 50)"$'\n'
      [ "$total" -gt 50 ] && problems+="  ... e mais $((total - 50)) chave(s)"$'\n'
    fi

    if [ -n "$problems" ]; then
      add_fail "[key_parity]$(where_label) $msg
${problems%$'\n'}"
    fi
  done
}

run_coupled() {
  local n i rel g msg hint level when=() require=() triggers=() ok violations=() skip_file skip_text shown v
  n="$(kit_rule_count coupled_changes)"
  for ((i = 0; i < ${n:-0}; i++)); do
    level="$(kit_rule_str coupled_changes "$i" level block)"
    [ "$level" = "warn" ] && continue
    mapfile -t when < <(kit_rule_list coupled_changes "$i" when)
    mapfile -t require < <(kit_rule_list coupled_changes "$i" require)
    msg="$(kit_rule_str coupled_changes "$i" message "Arquivos acoplados precisam mudar juntos.")"
    hint="$(kit_rule_str coupled_changes "$i" hint "")"
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
    shown="$(printf '%s\n' "${triggers[@]:0:20}" | paste -sd ',' - | sed 's/,/, /g')"
    [ "${#triggers[@]}" -gt 20 ] && shown+=" ... (+$((${#triggers[@]} - 20)))"
    v="[coupled_changes]$(where_label) $msg
  disparado por: ${shown}
  esperado também alteração em: ${require[*]}"
    [ -n "$hint" ] && v+=$'\n'"  dica: $hint"
    violations+=("$v")
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
  for v in "${violations[@]}"; do add_fail "$v"; done
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
  elif [ -f "$CWD/docs/claude-adoption.md" ]; then
    log="$CWD/docs/claude-adoption.md"
  else
    log="$root/.claude/kit-skip.log"
  fi
  if [ "${log##*/}" = "claude-adoption.md" ] && ! grep -q '^## Registro de kit-skip' "$log"; then
    printf '\n## Registro de kit-skip\n\n' >>"$log"
  fi
  printf -- '- %s — %s — liberado: %s\n' "$stamp" "$text" "$released" >>"$log"
  rm -f "$skip_file"
}

# Kits mais internos primeiro (repositorio antes da pasta-mae), ordem estavel.
ROOTS=()
while IFS= read -r r; do ROOTS+=("$r"); done < <(printf '%s\n' "${!KITS[@]}" | awk '{ print length($0) "\t" $0 }' | sort -t$'\t' -k1,1nr -k2,2 | cut -f2-)

for root in "${ROOTS[@]}"; do
  kit_use_root "$root"
  GROUP_RELS=()
  while IFS= read -r abs; do
    [ -n "$abs" ] || continue
    rel="$(kit_rel "$abs")"
    case "$rel" in .claude/kit-skip | .claude/kit-skip.log) continue ;; esac
    GROUP_RELS+=("$rel")
  done <<<"${GROUP[$root]:-}"
  RELS=()
  for abs in "${ALL[@]}"; do
    [ "${abs#"$root"/}" != "$abs" ] || continue
    rel="${abs#"$root"/}"
    case "$rel" in .claude/kit-skip | .claude/kit-skip.log) continue ;; esac
    RELS+=("$rel")
  done

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
