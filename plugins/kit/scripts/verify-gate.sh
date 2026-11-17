#!/usr/bin/env bash
# Stop: roda verify_on_stop, key_parity, coupled_changes e diff_deny (level block) sobre os arquivos
# alterados (inclusive os commitados neste turno) de todos os repositorios da sessao. Roda todos os
# comandos, mesmo depois de uma falha, e todas as falhas saem numa unica mensagem com exit 2. Na
# passada seguinte a um bloqueio (stop_hook_active) verifica de novo: se ainda falhar, libera o
# turno com a falha em systemMessage e sem notificacao de concluido.
# Turno liberado (gate passou ou nada a verificar): notificacao de concluido, se notify.done.
# Compativel com bash 3.2: sem arrays associativos nem mapfile; os mapas ficam em arquivos de $TMPD.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
kit_require_jq
kit_read_input

# Saida com o turno liberado. Nunca roda quando o gate bloqueia (exit 2) nem no SubagentStop.
finish() {
  [ "$(kit_field '.hook_event_name')" = "SubagentStop" ] || kit_notify_done "${CWD:-$(kit_cwd)}" "$(kit_field '.session_id')"
  exit 0
}

ACTIVE="$(kit_field '.stop_hook_active')"

command -v git >/dev/null 2>&1 || finish

CWD="$(kit_cwd)"
# cwd na forma que o git devolve (nome longo no lugar do 8.3 do Windows, symlink resolvido): as
# raizes comparadas com ele vem do git. Fora de repositorio, fica como veio.
if top_pfx="$(git -C "$CWD" rev-parse --show-toplevel --show-prefix 2>/dev/null | tr -d '\r')" && [ -n "$top_pfx" ]; then
  top="${top_pfx%%$'\n'*}"
  pfx="${top_pfx#*$'\n'}"
  [ "$pfx" = "$top_pfx" ] && pfx=""
  pfx="${pfx%/}"
  CWD="$(kit_norm_path "$top")${pfx:+/$pfx}"
fi
KIT_CEILING="$CWD"
SID="$(kit_field '.session_id')"

REPOS=()
while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(kit_repos "$CWD" "$SID" refresh)
[ "${#REPOS[@]}" -gt 0 ] || finish
MULTI=0
[ "${#REPOS[@]}" -gt 1 ] && MULTI=1

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Arquivos dos commits feitos neste turno: do HEAD gravado no UserPromptSubmit ate o HEAD de agora.
turn_committed() {
  local base
  base="$(kit_turn_mark "$1" "$SID")"
  [ -n "$base" ] || return 0
  git -c core.quotepath=off -C "$1" diff --name-only "$base" HEAD 2>/dev/null
  return 0
}

# Arquivos alterados (diff contra HEAD + nao rastreados + commitados no turno) de todos os
# repositorios, caminho absoluto.
for repo in ${REPOS[@]+"${REPOS[@]}"}; do
  {
    git -c core.quotepath=off -C "$repo" diff --name-only HEAD 2>/dev/null ||
      git -c core.quotepath=off -C "$repo" diff --name-only --cached 2>/dev/null
    git -c core.quotepath=off -C "$repo" ls-files --others --exclude-standard 2>/dev/null
    turn_committed "$repo"
  } | tr -d '\r' | sed '/^$/d' | sort -u | R="$repo" awk 'BEGIN { r = ENVIRON["R"] } { print r "/" $0 }'
done >"$TMPD/all"
[ -s "$TMPD/all" ] || finish

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
[ -s "$TMPD/dirroots" ] || finish

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

# Caminhos de um arquivo (um por linha) citados como no kit_quote, sem um subshell por arquivo.
# Arquivo apagado nao entra.
quote_files() {
  local m out="" q="'" r="'\\''"
  while IFS= read -r m; do
    [ -e "$KIT_ROOT/$m" ] || continue
    out+="'${m//$q/$r}' "
  done <"$1"
  printf '%s' "${out% }"
}

# Roda todos os comandos de verify_on_stop que tem arquivo alterado e registra cada falha. Comando na
# forma objeto { "run", "files" } usa os proprios globs; na forma string, os de source_globs.
run_verify() {
  local state="" stamp="" files m key cmd gitdir n=0 i nfail=0 keep=60
  local -a globs=() cglobs=()
  read_lines globs < <(kit_list source_globs)
  : >"$TMPD/vrun"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    cmd="$(kit_cmd "$key")"
    [ -n "$cmd" ] || continue
    read_lines cglobs < <(kit_cmd_files "$key")
    n=$((n + 1))
    if [ "${#cglobs[@]}" -gt 0 ]; then
      kit_glob_filter ${cglobs[@]+"${cglobs[@]}"} <"$TMPD/grels" >"$TMPD/vm-$n"
    elif [ "${#globs[@]}" -gt 0 ]; then
      kit_glob_filter "${globs[@]}" <"$TMPD/grels" >"$TMPD/vm-$n"
    else
      continue
    fi
    [ -s "$TMPD/vm-$n" ] || continue
    printf '%s' "$cmd" >"$TMPD/vc-$n"
    printf '%s\t%s\n' "$n" "$key" >>"$TMPD/vrun"
  done < <(kit_list verify_on_stop)
  [ -s "$TMPD/vrun" ] || return 0

  # Estado ja verificado com sucesso nao roda de novo.
  gitdir="$(git -C "$KIT_ROOT" rev-parse --absolute-git-dir 2>/dev/null | tr -d '\r')"
  if [ -n "$gitdir" ]; then
    state="$(
      {
        cat "$KIT_JSON"
        git -C "$KIT_ROOT" diff HEAD -- . 2>/dev/null
        cat "$TMPD/rels"
        R="$KIT_ROOT" awk 'BEGIN { r = ENVIRON["R"] } { print r "/" $0 }' "$TMPD/rels" | while IFS= read -r m; do
          [ -f "$m" ] && printf '%s\n' "$m"
        done | git hash-object --stdin-paths 2>/dev/null
      } | git hash-object --stdin 2>/dev/null
    )"
    stamp="$gitdir/kit-verify-$(printf '%s' "$KIT_ROOT" | git hash-object --stdin | cut -c1-12)"
    [ -n "$state" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$state" ] && return 0
  fi

  : >"$TMPD/vfail"
  while IFS=$'\t' read -r i key; do
    cmd="$(cat "$TMPD/vc-$i")"
    files="$(quote_files "$TMPD/vm-$i")"
    # So arquivos apagados: comando que recebe {files} nao tem o que conferir.
    case "$cmd" in *'{files}'*) [ -n "$files" ] || continue ;; esac
    cmd="$(kit_subst_files "$cmd" "$files")"
    # stdin fechado: o comando nao pode consumir a lista do laco.
    if ! kit_run "$cmd" "$TMPD/vo-$i" </dev/null; then
      nfail=$((nfail + 1))
      printf '%s' "$cmd" >"$TMPD/vc-$i"
      printf '%s\t%s\n' "$i" "$key" >>"$TMPD/vfail"
    fi
  done <"$TMPD/vrun"

  if [ "$nfail" -gt 0 ]; then
    # Mais de uma falha: corte menor para a mensagem caber no teto de saida do hook.
    [ "$nfail" -gt 1 ] && keep=30
    while IFS=$'\t' read -r i key; do
      add_fail "'$key' falhou em ${KIT_ROOT}
comando: $(cat "$TMPD/vc-$i")
$(tail -n "$keep" "$TMPD/vo-$i")"
    done <"$TMPD/vfail"
    return 0
  fi

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

# Falhas de coupled_changes e diff_deny da raiz atual, que o .claude/kit-skip pode liberar.
SKIPPABLE=()

run_coupled() {
  local n i msg hint level shown v ntrig
  local -a when=() require=()
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
    SKIPPABLE+=("$v")
  done
}

# Linhas adicionadas dos alterados da raiz (sem apagados e sem o proprio kit.json) em $TMPD/dd-all,
# como "caminho-relativo-a-raiz<TAB>linha<TAB>texto". Um git ls-files e um git diff por repositorio.
dd_collect() {
  local rel abs r best idx k base
  : >"$TMPD/dd-all"
  rm -f "$TMPD"/ddl-*
  while IFS= read -r rel; do
    [ "$rel" = ".claude/kit.json" ] && continue
    abs="$KIT_ROOT/$rel"
    [ -f "$abs" ] || continue
    best=""
    idx=0
    k=0
    for r in ${REPOS[@]+"${REPOS[@]}"}; do
      k=$((k + 1))
      if [ "${abs#"$r"/}" != "$abs" ] && [ "${#r}" -gt "${#best}" ]; then best="$r"; idx="$k"; fi
    done
    [ -n "$best" ] || continue
    printf '%s\n' "$best" >"$TMPD/ddr-$idx"
    printf '%s\n' "${abs#"$best"/}" >>"$TMPD/ddl-$idx"
  done <"$TMPD/rels"
  for k in "$TMPD"/ddl-*; do
    [ -f "$k" ] || continue
    idx="${k##*-}"
    r="$(cat "$TMPD/ddr-$idx")"
    kit_path_batches "" git --literal-pathspecs -c core.quotepath=off -C "$r" ls-files -- <"$k" 2>/dev/null | tr -d '\r' >"$TMPD/dd-tracked"
    grep -vxF -f "$TMPD/dd-tracked" "$k" >"$TMPD/dd-untracked"
    base="$(kit_turn_base "$r" "$SID")"
    kit_added_lines "$r" "$base" "$TMPD/dd-tracked" "$TMPD/dd-untracked" |
      R="$r" K="$KIT_ROOT" awk '{ p = ENVIRON["R"] "/"; k = ENVIRON["K"] "/"; t = $0; f = t; sub(/\t.*/, "", f); sub(/^[^\t]*/, "", t)
        f = p f; if (index(f, k) == 1) f = substr(f, length(k) + 1); print f t }' >>"$TMPD/dd-all"
    rm -f "$TMPD/ddr-$idx" "$k"
  done
}

# diff_deny: padrao (ERE) proibido nas linhas adicionadas no turno dos alterados que casam "files"
# (todos, sem "files"). level "warn" fica para o advise.sh, na edicao.
run_diff_deny() {
  local n i pattern msg level rc total v collected=0
  local -a dglobs=()
  n="$(kit_rule_count diff_deny)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    level="$(kit_rule_str diff_deny "$i" level block)"
    pattern="$(kit_rule_str diff_deny "$i" pattern "")"
    msg="$(kit_rule_str diff_deny "$i" message "Padrão proibido em linha nova.")"
    read_lines dglobs < <(kit_rule_list diff_deny "$i" files)
    i=$((i + 1))
    [ "$level" = "warn" ] && continue
    [ -n "$pattern" ] || continue
    if [ "$collected" -eq 0 ]; then dd_collect; collected=1; fi
    [ -s "$TMPD/dd-all" ] || return 0
    if [ "${#dglobs[@]}" -gt 0 ]; then
      kit_glob_filter ${dglobs[@]+"${dglobs[@]}"} <"$TMPD/rels" >"$TMPD/dd-c"
    else
      cp "$TMPD/rels" "$TMPD/dd-c"
    fi
    # Texto das linhas candidatas num arquivo e "caminho:linha" no outro, na mesma ordem: o grep
    # roda so sobre o texto, entao ^ e $ do padrao valem para a linha do codigo.
    M="$TMPD/dd-m" T="$TMPD/dd-t" awk -F'\t' 'NR == FNR { c[$0] = 1; next }
      ($1 in c) { t = $0; sub(/^[^\t]*\t[^\t]*\t/, "", t); print $1 ":" $2 >ENVIRON["M"]; print t >ENVIRON["T"] }' "$TMPD/dd-c" "$TMPD/dd-all"
    [ -s "$TMPD/dd-t" ] || { rm -f "$TMPD/dd-m" "$TMPD/dd-t"; continue; }
    grep -nE -- "$pattern" "$TMPD/dd-t" >"$TMPD/dd-h" 2>/dev/null
    rc=$?
    if [ "$rc" -gt 1 ]; then
      add_fail "[diff_deny]$(where_label) padrão inválido em diff_deny[$((i - 1))]: $pattern"
    elif [ "$rc" -eq 0 ]; then
      awk 'NR == FNR { m[NR] = $0; next } { k = $0; sub(/:.*/, "", k); t = $0; sub(/^[0-9]+:[ \t]*/, "", t)
        if (length(t) > 160) t = substr(t, 1, 160) "..."; print "  " m[k] ": " t }' "$TMPD/dd-m" "$TMPD/dd-h" >"$TMPD/dd-r"
      total="$(wc -l <"$TMPD/dd-r" | tr -d ' ')"
      v="[diff_deny]$(where_label) $msg
$(head -n 20 "$TMPD/dd-r")"
      [ "$total" -gt 20 ] && v+=$'\n'"  ... e mais $((total - 20)) linha(s)"
      SKIPPABLE+=("$v")
    fi
    rm -f "$TMPD/dd-m" "$TMPD/dd-t"
  done
}

# Libera as falhas de coupled_changes e diff_deny com uma linha de justificativa em .claude/kit-skip.
apply_skip() {
  local skip_file skip_text v
  [ "${#SKIPPABLE[@]}" -gt 0 ] || return 0
  skip_file="$KIT_ROOT/.claude/kit-skip"
  if [ -f "$skip_file" ]; then
    skip_text="$(tr -d '\r' <"$skip_file" | sed '/^[[:space:]]*$/d' | head -n 1)"
    if [ -n "$skip_text" ]; then
      printf '%s\t%s\n' "$KIT_ROOT" "$(printf '%s\n' ${SKIPPABLE[@]+"${SKIPPABLE[@]}"} | sed -nE 's/^\[(coupled_changes|diff_deny)\][^ ]* //p' | paste -sd ';' -)" >>"$TMPD/skip-released"
      SKIPPABLE=()
      return 0
    fi
    SKIPPABLE[0]+=$'\n'"  .claude/kit-skip está vazio: escreva uma linha de justificativa para liberar."
  else
    SKIPPABLE[0]+=$'\n'"  Se a regra realmente não se aplica a esta mudança, grave uma linha de justificativa em .claude/kit-skip (fica registrada)."
  fi
  for v in ${SKIPPABLE[@]+"${SKIPPABLE[@]}"}; do add_fail "$v"; done
  SKIPPABLE=()
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
  if ! kit_json_ok "$KIT_JSON"; then
    add_fail "kit.json inválido em ${KIT_ROOT}: nenhuma verificação desta pasta pôde rodar. Corrija o arquivo (jq . .claude/kit.json mostra o erro)."
    continue
  fi
  rels_under "$root" 2 <"$TMPD/group" >"$TMPD/grels"
  rels_under "$root" 0 <"$TMPD/all" >"$TMPD/rels"
  run_verify
  run_key_parity
  run_coupled
  run_diff_deny
  apply_skip
done

# Encaixa as falhas em <teto> caracteres: as curtas ficam inteiras e as longas dividem o resto por
# igual, guardando o comeco (qual falha) e o fim (onde costuma estar o erro). Sem isso, uma saida
# longa de comando ocuparia a mensagem e esconderia as outras falhas.
fit_fails() {
  local budget="$1" left="${#FAILS[@]}" changed=1 i per f head tail
  local mark=$'\n... (cortado para caber no limite de saída do hook) ...\n'
  local -a kept=()
  for ((i = 0; i < ${#FAILS[@]}; i++)); do kept[i]=0; done
  while [ "$changed" -eq 1 ] && [ "$left" -gt 0 ]; do
    changed=0
    per=$((budget / left))
    for ((i = 0; i < ${#FAILS[@]}; i++)); do
      [ "${kept[i]}" -eq 0 ] && [ "${#FAILS[i]}" -le "$per" ] || continue
      kept[i]=1
      budget=$((budget - ${#FAILS[i]}))
      left=$((left - 1))
      changed=1
    done
  done
  [ "$left" -gt 0 ] || return 0
  per=$((budget / left))
  [ "$per" -ge 200 ] || per=200
  head=$((per / 4))
  [ "$head" -le 400 ] || head=400
  tail=$((per - head - ${#mark}))
  for ((i = 0; i < ${#FAILS[@]}; i++)); do
    [ "${kept[i]}" -eq 0 ] || continue
    f="${FAILS[i]}"
    FAILS[i]="${f:0:head}${mark}${f:$((${#f} - tail))}"
  done
}

if [ "${#FAILS[@]}" -gt 0 ]; then
  # Acima de 10.000 caracteres o modelo recebe so uma previa. Na passada seguinte a um bloqueio a
  # mensagem vai ao usuario (systemMessage) e sai inteira.
  [ "$ACTIVE" = "true" ] || fit_fails $((9000 - 8 * ${#FAILS[@]}))
  report="$(
    n=0
    for f in "${FAILS[@]}"; do
      n=$((n + 1))
      echo
      echo "$n) $f"
    done
  )"
  # Passada seguinte a um bloqueio: o turno termina, a falha vai ao usuario e nao ha "concluido".
  if [ "$ACTIVE" = "true" ]; then
    jq -cn --arg m "kit verify-gate: ${#FAILS[@]} problema(s) continuam depois da tentativa de correção; o turno terminou com a verificação vermelha.
$report" '{systemMessage: $m}'
    exit 0
  fi
  {
    echo "kit verify-gate: ${#FAILS[@]} problema(s) neste turno."
    printf '%s\n' "$report"
    echo
    echo "Corrija a causa e tente terminar de novo."
  } >&2
  exit 2
fi

for root in ${ROOTS[@]+"${ROOTS[@]}"}; do consume_skip "$root"; done
finish
