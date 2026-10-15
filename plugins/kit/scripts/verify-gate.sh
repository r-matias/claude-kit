#!/usr/bin/env bash
# Stop: roda verify_on_stop, key_parity e coupled_changes (level block) sobre os arquivos alterados
# de todos os repositorios da sessao. Todas as falhas saem numa unica mensagem com exit 2.
# Compativel com bash 3.2: sem arrays associativos nem mapfile; os mapas ficam em arquivos de $TMPD.
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

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
OUT="$TMPD/out"

# Arquivos alterados (diff contra HEAD + nao rastreados) de todos os repositorios, caminho absoluto.
for repo in ${REPOS[@]+"${REPOS[@]}"}; do
  {
    git -c core.quotepath=off -C "$repo" diff --name-only HEAD 2>/dev/null ||
      git -c core.quotepath=off -C "$repo" diff --name-only --cached 2>/dev/null
    git -c core.quotepath=off -C "$repo" ls-files --others --exclude-standard 2>/dev/null
  } | tr -d '\r' | sed '/^$/d' | sort -u | R="$repo" awk 'BEGIN { r = ENVIRON["R"] } { print r "/" $0 }'
done >"$TMPD/all"
[ -s "$TMPD/all" ] || exit 0

# Raizes de kit.json por pasta (kit_kit_roots roda uma vez por pasta distinta, nao por arquivo):
# "pasta<TAB>raiz<TAB>1" para o kit.json mais proximo (comandos) e 0 para os de cima (dominio).
sed 's|/[^/]*$||' "$TMPD/all" | sort -u >"$TMPD/dirs"
while IFS= read -r d; do
  first=1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    printf '%s\t%s\t%s\n' "$d" "$root" "$first"
    first=0
  done < <(kit_kit_roots "$d")
done <"$TMPD/dirs" >"$TMPD/dirroots"
[ -s "$TMPD/dirroots" ] || exit 0

# "raiz<TAB>arquivo" de cada arquivo com o kit.json mais proximo.
awk -F'\t' 'NR == FNR { if ($3 == 1) R[$1] = $2; next }
  { d = $0; sub(/\/[^\/]*$/, "", d); if (d in R) print R[d] "\t" $0 }' "$TMPD/dirroots" "$TMPD/all" >"$TMPD/group"

FAILS=()
: >"$TMPD/skip-released"

# Nome do repositorio que contem um caminho, relativo a pasta da sessao.
repo_name() {
  local p="$1" best="" r
  for r in ${REPOS[@]+"${REPOS[@]}"}; do
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

# Le linhas do stdin para o array nomeado em $1 (substitui mapfile, que nao existe no bash 3.2).
read_lines() {
  local __name="$1" __line
  eval "$__name=()"
  while IFS= read -r __line; do
    [ -n "$__line" ] || continue
    eval "$__name+=(\"\$__line\")"
  done
}

run_verify() {
  local state="" stamp="" files="" m key cmd gitdir
  local -a globs=()
  read_lines globs < <(kit_list source_globs)
  [ "${#globs[@]}" -gt 0 ] || return 0
  kit_glob_filter "${globs[@]}" <"$TMPD/grels" >"$TMPD/matched"
  [ -s "$TMPD/matched" ] || return 0

  # Estado ja verificado com sucesso nao roda de novo.
  gitdir="$(git -C "$KIT_ROOT" rev-parse --absolute-git-dir 2>/dev/null | tr -d '\r')"
  if [ -n "$gitdir" ]; then
    state="$(
      {
        cat "$KIT_JSON"
        git -C "$KIT_ROOT" diff HEAD -- . 2>/dev/null
        cat "$TMPD/matched"
        R="$KIT_ROOT" awk 'BEGIN { r = ENVIRON["R"] } { print r "/" $0 }' "$TMPD/matched" | while IFS= read -r m; do
          [ -f "$m" ] && printf '%s\n' "$m"
        done | git hash-object --stdin-paths 2>/dev/null
      } | git hash-object --stdin 2>/dev/null
    )"
    stamp="$gitdir/kit-verify-$(printf '%s' "$KIT_ROOT" | git hash-object --stdin | cut -c1-12)"
    [ -n "$state" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$state" ] && return 0
  fi

  # Mesma citacao do kit_quote, sem um subshell por arquivo.
  while IFS= read -r m; do files+="'${m//\'/\'\\\'\'}' "; done <"$TMPD/matched"
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
  grep -qxF -- "${1#./}" "$TMPD/rels"
}

run_key_parity() {
  local n i j f msg hit problems union dup missing total
  local -a files=() labels=()
  n="$(kit_rule_count key_parity)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    read_lines files < <(kit_rule_list key_parity "$i" files)
    i=$((i + 1))
    [ "${#files[@]}" -gt 0 ] || continue
    hit=0
    for f in ${files[@]+"${files[@]}"}; do is_changed "$f" && { hit=1; break; }; done
    [ "$hit" -eq 1 ] || continue
    msg="$(kit_rule_str key_parity "$((i - 1))" message "Chaves divergentes entre arquivos pareados.")"

    # Rotulo curto (nome do arquivo) quando nao ha nomes repetidos; senao o caminho declarado.
    labels=()
    dup="$(for f in ${files[@]+"${files[@]}"}; do printf '%s\n' "${f##*/}"; done | sort | uniq -d)"
    for f in ${files[@]+"${files[@]}"}; do
      if [ -z "$dup" ]; then labels+=("${f##*/}"); else labels+=("${f#./}"); fi
    done

    problems=""
    union="$TMPD/kp-union"
    : >"$union"
    j=0
    while [ "$j" -lt "${#files[@]}" ]; do
      f="${files[$j]#./}"
      rm -f "$TMPD/kp-$j"
      if [ ! -f "$KIT_ROOT/$f" ]; then
        problems+="  $f não existe"$'\n'
      elif ! kit_json_keys "$KIT_ROOT/$f" >"$TMPD/kp-$j"; then
        rm -f "$TMPD/kp-$j"
        problems+="  $f não é JSON válido"$'\n'
      else
        cat "$TMPD/kp-$j" >>"$union"
      fi
      j=$((j + 1))
    done
    LC_ALL=C sort -u -o "$union" "$union"

    missing="$(
      j=0
      while [ "$j" -lt "${#files[@]}" ]; do
        if [ -f "$TMPD/kp-$j" ]; then
          LC_ALL=C comm -23 "$union" "$TMPD/kp-$j" | L="${labels[$j]}" awk 'BEGIN { l = ENVIRON["L"] } { print $0 "\t" l }'
        fi
        j=$((j + 1))
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
  local n i msg hint level skip_file skip_text shown v ntrig
  local -a when=() require=() violations=()
  n="$(kit_rule_count coupled_changes)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    level="$(kit_rule_str coupled_changes "$i" level block)"
    if [ "$level" = "warn" ]; then i=$((i + 1)); continue; fi
    read_lines when < <(kit_rule_list coupled_changes "$i" when)
    read_lines require < <(kit_rule_list coupled_changes "$i" require)
    msg="$(kit_rule_str coupled_changes "$i" message "Arquivos acoplados precisam mudar juntos.")"
    hint="$(kit_rule_str coupled_changes "$i" hint "")"
    i=$((i + 1))
    [ "${#when[@]}" -gt 0 ] || continue
    kit_glob_filter "${when[@]}" <"$TMPD/rels" >"$TMPD/triggers"
    [ -s "$TMPD/triggers" ] || continue
    if [ "${#require[@]}" -gt 0 ] && [ -n "$(kit_glob_filter "${require[@]}" <"$TMPD/rels" | head -n 1)" ]; then
      continue
    fi
    ntrig="$(wc -l <"$TMPD/triggers" | tr -d ' ')"
    shown="$(head -n 20 "$TMPD/triggers" | paste -sd ',' - | sed 's/,/, /g')"
    [ "$ntrig" -gt 20 ] && shown+=" ... (+$((ntrig - 20)))"
    v="[coupled_changes]$(where_label) $msg
  disparado por: ${shown}
  esperado também alteração em: ${require[*]+${require[*]}}"
    [ -n "$hint" ] && v+=$'\n'"  dica: $hint"
    violations+=("$v")
  done
  [ "${#violations[@]}" -gt 0 ] || return 0

  skip_file="$KIT_ROOT/.claude/kit-skip"
  if [ -f "$skip_file" ]; then
    skip_text="$(tr -d '\r' <"$skip_file" | sed '/^[[:space:]]*$/d' | head -n 1)"
    if [ -n "$skip_text" ]; then
      printf '%s\t%s\n' "$KIT_ROOT" "$(printf '%s\n' "${violations[@]}" | sed -n 's/^\[coupled_changes\][^ ]* //p' | paste -sd ';' -)" >>"$TMPD/skip-released"
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
  released="$(R="$root" awk -F'\t' '$1 == ENVIRON["R"] { print $2; exit }' "$TMPD/skip-released")"
  [ -n "$released" ] || released="nenhuma regra violada"
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
while IFS= read -r r; do [ -n "$r" ] && ROOTS+=("$r"); done < <(cut -f2 "$TMPD/dirroots" | sort -u | awk '{ print length($0) "\t" $0 }' | sort -t$'\t' -k1,1nr -k2,2 | cut -f2-)

# Caminhos relativos a raiz, sem o kit-skip e seu log.
rels_under() {
  R="$1" awk -F'\t' -v col="$2" 'BEGIN { r = ENVIRON["R"] "/" }
    { p = (col == 2) ? $2 : $0; if (col == 2 && $1 != ENVIRON["R"]) next
      if (index(p, r) != 1) next; p = substr(p, length(r) + 1)
      if (p == ".claude/kit-skip" || p == ".claude/kit-skip.log") next; print p }'
}

for root in ${ROOTS[@]+"${ROOTS[@]}"}; do
  kit_use_root "$root"
  rels_under "$root" 2 <"$TMPD/group" >"$TMPD/grels"
  rels_under "$root" 0 <"$TMPD/all" >"$TMPD/rels"
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

for root in ${ROOTS[@]+"${ROOTS[@]}"}; do consume_skip "$root"; done
exit 0
