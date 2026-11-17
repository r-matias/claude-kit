#!/usr/bin/env bash
# PreToolUse/Edit|Write|MultiEdit|NotebookEdit: nega escrita em segredos, em guards.deny_write e em
# protected_paths do kit.json (este com excecao por guards.allow_write). Nome com sufixo .example,
# .sample, .template ou .dist nao e segredo.
# O caminho e normalizado antes de casar (.., //, relativo ao cwd) e, se for symlink, o alvo final
# tambem e checado. Em Windows e macOS a comparacao ignora maiusculas. Erro inesperado bloqueia.
# Roda a cada edicao, com limite de tempo: a entrada e lida num jq so, cada kit.json em outro, e o
# casamento por regra nao cria processo (no Git Bash cada um custa dezenas de milissegundos).
set -u
KIT_HERE="${BASH_SOURCE[0]%/*}"
[ "$KIT_HERE" != "${BASH_SOURCE[0]}" ] || KIT_HERE="."
. "$KIT_HERE/lib.sh"
kit_guard_fail_closed
kit_require_jq_strict
kit_read_input

TOOL=""
RAW=""
NOTEBOOK=""
CWD=""
if ! kit_fields TOOL '.tool_name' RAW '.tool_input.file_path' NOTEBOOK '.tool_input.notebook_path' CWD '.cwd'; then
  echo "kit: entrada do hook vazia ou ilegível; chamada bloqueada" >&2
  exit 2
fi
[ -n "$RAW" ] || RAW="$NOTEBOOK"
[ -n "$RAW" ] || exit 0

[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
CWD="${CWD//\\//}"
KIT_CEILING="$CWD"
# No shell principal: os subshells herdam o sistema ja lido.
kit_case_insensitive || true

# Windows ignora espaco e ponto no fim de cada nome e trata "nome:fluxo" (ADS) como o proprio nome.
# O sed so roda quando o caminho tem um desses casos.
win_clean() {
  case "${1#[A-Za-z]:}" in
    *:* | *[.\ ]/* | *[.\ ]) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  printf '%s' "$1" | sed -E 's#^([A-Za-z]):#\1|#; s#:[^/]*##g; s#^([A-Za-z])\|#\1:#; s#([^/.])[. ]+(/|$)#\1\2#g'
}

FILE="${RAW//\\//}"
case "$KIT_UNAME" in MINGW* | MSYS* | CYGWIN*) FILE="$(win_clean "$FILE")" ;; esac
FILE="$(kit_path_norm "$FILE" "$CWD")"

# Alvo final de um symlink (encadeado ate 20 niveis) e pasta real do primeiro ancestral existente.
real_path() {
  local p="$1" t n=0 dir rest="" real
  while [ -L "$p" ] && [ "$n" -lt 20 ]; do
    t="$(readlink "$p" 2>/dev/null)" || break
    kit_parent_to "$p"
    p="$(kit_path_norm "$t" "$KIT_PARENT")"
    n=$((n + 1))
  done
  kit_parent_to "$p"
  dir="$KIT_PARENT"
  while [ ! -d "$dir" ]; do
    rest="/${dir##*/}$rest"
    kit_parent_to "$dir"
    [ "$KIT_PARENT" = "$dir" ] && break
    dir="$KIT_PARENT"
  done
  real="$(cd -P "$dir" 2>/dev/null && pwd -P)" || real=""
  if [ -n "$real" ] && command -v cygpath >/dev/null 2>&1; then real="$(cygpath -m "$real" 2>/dev/null)"; fi
  [ -n "$real" ] || real="$dir"
  printf '%s' "$(kit_path_norm "${real%/}$rest/${p##*/}" /)"
}

# Write de arquivo novo so e negado por item com "write": "deny"; Write sobre arquivo existente conta como edicao.
NEW_FILE=0
if [ "$TOOL" = "Write" ] && [ ! -e "$FILE" ]; then NEW_FILE=1; fi

ALLOW_HINT="Se este arquivo não é segredo, adicione o caminho em guards.allow_write no .claude/kit.json."
EXAMPLE_HINT="Arquivo de exemplo: use o sufixo .example, .sample, .template ou .dist."

# Raizes de kit.json que valem para o caminho (a mais proxima e as de cima, ate a pasta-mae) e as
# regras de cada uma (kit_guard_rules), lidas uma vez por caminho.
ROOTS=()
RULES=()
load_rules() {
  local root r
  ROOTS=()
  RULES=()
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    r="$(kit_guard_rules "$root/.claude/kit.json")"
    # O CR sai numa atribuicao simples: dentro de ( ) de array o bash nao expande o $'\r' do padrao.
    r="${r//$'\r'/}"
    ROOTS+=("$root")
    RULES+=("$r")
  done < <(kit_kit_roots "$1")
}

# Caminho relativo a KIT_ROOT em REL (o proprio caminho se estiver fora) e em minusculas em CMP.
REL=""
CMP=""
rel_of() {
  REL="$1"
  if [ -n "$KIT_ROOT" ] && [ "${1#"$KIT_ROOT"/}" != "$1" ]; then REL="${1#"$KIT_ROOT"/}"; fi
  kit_fold_to "$REL"
  CMP="$KIT_FOLDED"
}

check_path() {
  local file="$1" base rules tag glob a b allowed=0 broad="" i
  kit_fold_to "${file##*/}"
  base="$KIT_FOLDED"
  if ! kit_is_example_name "$base"; then
    case "$base" in
      .env | .env.*) kit_deny_pretool "kit: escrita em arquivo de segredo (${file##*/}) bloqueada. $EXAMPLE_HINT" ;;
      *.pem | *.key) kit_deny_pretool "kit: escrita em chave/certificado (${file##*/}) bloqueada." ;;
    esac
  fi
  kit_fold_to "$file"
  case "/$KIT_FOLDED" in
    */secrets/*) kit_deny_pretool "kit: escrita em diretorio secrets/ bloqueada." ;;
    */keys/*) kit_deny_pretool "kit: escrita em diretorio keys/ bloqueada." ;;
  esac

  # Valem os guards e o protected_paths do kit.json mais proximo e dos kit.json acima dele (pasta-mae).
  # guards.deny_write bloqueia sempre; guards.allow_write (sem glob largo nem segredo) libera o protected_paths.
  load_rules "$file"
  for ((i = 0; i < ${#ROOTS[@]}; i++)); do
    kit_use_root "${ROOTS[$i]}"
    rules="${RULES[$i]}"
    rel_of "$file"
    # kit.json ilegivel: as regras nao podem ser conferidas. So o proprio kit.json pode ser escrito.
    if [ "$CMP" != ".claude/kit.json" ]; then
      case "$rules" in
        OK | OK$'\n'*) ;;
        X | X$'\n'*)
          kit_deny_pretool "kit: $KIT_JSON tem protected_paths ou guards com tipo errado (precisam ser lista); as regras não podem ser conferidas. Corrija o kit.json e tente de novo." ;;
        *)
          kit_deny_pretool "kit: $KIT_JSON não é JSON válido; protected_paths e guards não podem ser conferidos. Corrija o kit.json (jq . mostra o erro) e tente de novo." ;;
      esac
    fi
    case "$rules" in OK$'\n'*) ;; *) continue ;; esac
    # As linhas D (deny_write) vem antes das A (allow_write), como no kit_guard_rules.
    while IFS=$'\t' read -r tag glob a b; do
      case "$tag" in
        D)
          kit_fold_to "$glob"
          glob_match "$KIT_FOLDED" "$CMP" || continue
          [ -n "$a" ] && kit_deny_pretool "kit: $REL é bloqueado. $a"
          kit_deny_pretool "kit: $REL casa guards.deny_write ($glob) do kit.json." ;;
        A)
          kit_glob_secret "$glob" && continue
          kit_fold_to "$glob"
          glob_match "$KIT_FOLDED" "$CMP" || continue
          if kit_glob_broad "$glob"; then broad="$glob"; continue; fi
          allowed=1 ;;
      esac
    done <<<"$rules"
  done
  [ "$allowed" -eq 1 ] && return 0
  if [ -n "$broad" ]; then
    ALLOW_HINT="guards.allow_write ignora \"$broad\": glob largo demais; liste o caminho exato."
  fi

  for ((i = 0; i < ${#ROOTS[@]}; i++)); do
    kit_use_root "${ROOTS[$i]}"
    rules="${RULES[$i]}"
    case "$rules" in OK$'\n'*) ;; *) continue ;; esac
    rel_of "$file"
    while IFS=$'\t' read -r tag glob a b; do
      [ "$tag" = "P" ] || continue
      kit_fold_to "$glob"
      glob_match "$KIT_FOLDED" "$CMP" || continue
      [ "$NEW_FILE" -eq 1 ] && [ "$a" != "deny" ] && continue
      if [ -n "$b" ]; then
        kit_deny_pretool "kit: $REL é protegido. $b $ALLOW_HINT"
      fi
      if [ "$NEW_FILE" -eq 1 ]; then
        kit_deny_pretool "kit: $REL casa protected_paths ($glob) com write: deny no kit.json. Nem arquivo novo pode ser criado aqui. $ALLOW_HINT"
      fi
      kit_deny_pretool "kit: $REL casa protected_paths ($glob) do kit.json. Gere um arquivo novo ou edite manualmente. $ALLOW_HINT"
    done <<<"$rules"
  done
  return 0
}

check_path "$FILE"
REAL="$(real_path "$FILE")"
kit_fold_to "$REAL"
REAL_CMP="$KIT_FOLDED"
kit_fold_to "$FILE"
[ "$REAL_CMP" != "$KIT_FOLDED" ] && check_path "$REAL"

exit 0
