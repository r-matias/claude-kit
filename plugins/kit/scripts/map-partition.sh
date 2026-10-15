#!/usr/bin/env bash
# Apoio do /kit:map. Nao e hook e nao usa LLM: divide o codigo da sessao em unidades de mapeamento.
#
#   map-partition.sh [--root <pasta>] [--path <subpasta>] [--since <commit> | --since <repo>=<commit>]...
#
# Repositorios: "repos" do kit.json da raiz, o proprio repositorio ou os filhos (mesma descoberta dos
# hooks). Arquivos: git ls-files de cada um, filtrados por source_globs (do kit.json do repositorio ou
# da raiz) e sem vendor/dist/build, gerados, lockfiles, binarios, protected_paths, .env*, secrets/ e
# keys/. Unidade inicial: pacote (pasta com manifesto) ou pasta de topo. Unidade acima de
# map.unit_max_files arquivos ou map.unit_max_loc linhas e subdividida pelas subpastas; vizinhas
# pequenas sao agrupadas ate o limite. --path limita a uma area (relativa a raiz). --since marca as
# unidades com arquivo alterado desde o commit (git diff <commit> mais nao rastreados).
#
#   map-partition.sh [--root <pasta>] --status
#     Estado do docs/codemap.md: "ausente", "em dia" ou a linha de aviso do session-context. Exit 1 se
#     ausente ou desatualizado.
#
# Saida (stdout): JSON {root, primary, repos[{repo, path, commit}], limits, units[{repo, unit, paths[],
# file_count, loc, manifests[], changed, changed_files}], totals{units, files, loc, agents, changed}}.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "map-partition: jq não encontrado" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "map-partition: git não encontrado" >&2; exit 2; }

ROOT="."
AREA=""
SINCE=()
STATUS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --path) AREA="${2:-}"; shift 2 ;;
    --since) SINCE+=("${2:-}"); shift 2 ;;
    --status) STATUS=1; shift ;;
    *) echo "uso: map-partition.sh [--root <pasta>] [--status] [--path <subpasta>] [--since [<repo>=]<commit>]..." >&2; exit 2 ;;
  esac
done
ROOT="$(cd "$ROOT" 2>/dev/null && { pwd -W 2>/dev/null || pwd; })" || { echo "map-partition: pasta inexistente" >&2; exit 2; }
ROOT="$(kit_norm_path "$ROOT")"
AREA="$(kit_norm_path "$AREA")"
AREA="${AREA#./}"
AREA="${AREA%/}"
[ "$AREA" = "." ] && AREA=""

ROOT_KIT="$ROOT/.claude/kit.json"
cfg() {
  local v=""
  [ -f "$ROOT_KIT" ] && v="$(jq -r --arg k "$1" '(.map // {})[$k] // empty' "$ROOT_KIT" 2>/dev/null | tr -d '\r')"
  case "$v" in '' | *[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}
MAX_FILES="$(cfg unit_max_files 150)"
MAX_LOC="$(cfg unit_max_loc 20000)"
MAX_AGENTS="$(cfg max_agents 30)"
PARALLEL=8

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Exclusoes fixas, sobre o caminho relativo ao repositorio.
cat >"$TMPD/exclude" <<'EOF'
(^|/)(node_modules|vendor|dist|build|target|coverage|\.venv|venv|__pycache__|\.next|\.nuxt|\.git|generated|__generated__)/
(^|/)\.claude/
^docs/codemap\.md$
(^|/)\.env($|\.)
(^|/)(secrets|keys)/
\.(pem|key|p12|pfx|jks|keystore|crt|cer)$
(^|/)[^/]*\.lock$
-lock\.(json|ya?ml)$
(^|/)(go\.sum|npm-shrinkwrap\.json|packages\.lock\.json)$
\.(min\.js|min\.css|map)$
(^|/)[^/]*\.generated\.[^/]*$
\.(g|g\.i|[Dd]esigner)\.[^/.]+$
(_pb2\.py|\.pb\.go)$
\.(png|jpe?g|gif|bmp|ico|webp|svg|pdf|zip|gz|tgz|bz2|xz|7z|rar|jar|war|dll|exe|so|dylib|a|o|class|pyc|wasm|woff2?|ttf|otf|eot|mp[34]|mov|avi|db|sqlite3?|bin)$
EOF

MANIFEST_RE='^(package\.json|pyproject\.toml|setup\.py|requirements[^/]*\.txt|go\.mod|Cargo\.toml|pom\.xml|build\.gradle(\.kts)?|Gemfile|composer\.json|mix\.exs|deno\.jsonc?|[^/]*\.(csproj|fsproj|vbproj|sln))$'

# Globs (um por linha) viram ERE para grep -E -f. Glob sem "/" casa pelo nome do arquivo.
globs_to_ere() {
  local g re
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    re="$(glob_to_regex "$g")"
    if [[ "$g" == */* ]]; then printf '%s\n' "$re"; else printf '(^|/)%s\n' "${re#^}"; fi
  done
}

# Globs de um campo do kit.json de $1, aplicaveis ao repositorio de caminho relativo $2 ("." = raiz).
# Glob da raiz que comeca pelo repositorio perde o prefixo; os que comecam com ** ou nao tem "/" valem.
kit_globs() {
  local file="$1" rel="$2" field="$3" g
  [ -f "$file" ] || return 0
  jq -r --arg f "$field" '(.[$f] // [])[] | if type == "string" then . elif type == "object" then (.glob // empty) else empty end' "$file" 2>/dev/null |
    tr -d '\r' | while IFS= read -r g; do
      [ -n "$g" ] || continue
      if [ "$rel" = "." ] || [[ "$g" != */* ]] || [[ "$g" == '**'* ]]; then printf '%s\n' "$g"
      elif [ "${g#"$rel"/}" != "$g" ]; then printf '%s\n' "${g#"$rel"/}"
      fi
    done
}

REPOS=()
while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(kit_repos "$ROOT" "")
[ "${#REPOS[@]}" -gt 0 ] || { echo "map-partition: nenhum repositório git em $ROOT" >&2; exit 1; }

MULTI=0
[ "${#REPOS[@]}" -gt 1 ] && MULTI=1

# Repositorio principal (onde fica o docs/codemap.md): map.primary, o da propria raiz ou o primeiro.
PRIMARY=""
[ -f "$ROOT_KIT" ] && PRIMARY="$(jq -r '(.map // {}).primary // empty' "$ROOT_KIT" 2>/dev/null | tr -d '\r')"
PRIMARY="${PRIMARY#./}"
PRIMARY="${PRIMARY%/}"
if [ -z "$PRIMARY" ]; then
  if [ "${REPOS[0]}" = "$ROOT" ]; then PRIMARY="."; else PRIMARY="$(kit_rel_to "$ROOT" "${REPOS[0]}")"; fi
fi

if [ "$STATUS" -eq 1 ]; then
  found=0
  for d in "$ROOT" "${REPOS[@]}"; do
    [ -f "$d/docs/codemap.md" ] && head -n 5 "$d/docs/codemap.md" | grep -qF 'kit:map v' && found=1
  done
  [ "$found" -eq 1 ] || { echo "codemap: ausente"; exit 1; }
  note="$(kit_codemap_note "$ROOT" "${REPOS[@]}")"
  [ -z "$note" ] || { printf '%s\n' "$note"; exit 1; }
  echo "codemap: em dia"
  exit 0
fi

: >"$TMPD/units.tsv"
: >"$TMPD/repos.tsv"
for repo in "${REPOS[@]}"; do
  rel="$(kit_rel_to "$ROOT" "$repo")"
  commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null | tr -d '\r')"
  printf '%s\t%s\t%s\n' "$rel" "$repo" "$commit" >>"$TMPD/repos.tsv"
  W="$TMPD/r"
  rm -rf "$W"; mkdir -p "$W"

  git -C "$repo" -c core.quotepath=off ls-files 2>/dev/null | tr -d '\r' | grep -vEf "$TMPD/exclude" >"$W/all" || true

  # Area pedida, relativa a raiz; RAREA e a mesma area relativa ao repositorio (vazio = repo inteiro).
  RAREA=""
  if [ -n "$AREA" ]; then
    if [ "$rel" = "." ]; then RAREA="$AREA"; elif [ "${AREA#"$rel"/}" != "$AREA" ]; then RAREA="${AREA#"$rel"/}"; fi
    if [ "$rel" = "." ]; then pre=""; else pre="$rel/"; fi
    awk -v pre="$pre" -v area="$AREA" '{ p = pre $0; if (p == area || index(p, area "/") == 1) print }' "$W/all" >"$W/all.tmp"
    mv "$W/all.tmp" "$W/all"
  fi

  { kit_globs "$repo/.claude/kit.json" "." protected_paths
    [ "$repo" != "$ROOT" ] && kit_globs "$ROOT_KIT" "$rel" protected_paths; } | globs_to_ere >"$W/protected"
  if [ -s "$W/protected" ]; then grep -vEf "$W/protected" "$W/all" >"$W/kept" || true; else cp "$W/all" "$W/kept"; fi

  if [ -f "$repo/.claude/kit.json" ] && jq -e '(.source_globs // []) | length > 0' "$repo/.claude/kit.json" >/dev/null 2>&1; then
    kit_globs "$repo/.claude/kit.json" "." source_globs | globs_to_ere >"$W/src"
  elif [ "$repo" != "$ROOT" ] && [ -f "$ROOT_KIT" ] && jq -e '(.source_globs // []) | length > 0' "$ROOT_KIT" >/dev/null 2>&1; then
    kit_globs "$ROOT_KIT" "$rel" source_globs | globs_to_ere >"$W/src"
    [ -s "$W/src" ] || printf '^$\n' >"$W/src"
  elif [ -f "$ROOT_KIT" ] && jq -e '(.source_globs // []) | length > 0' "$ROOT_KIT" >/dev/null 2>&1; then
    kit_globs "$ROOT_KIT" "." source_globs | globs_to_ere >"$W/src"
  else
    : >"$W/src"
  fi
  if [ -s "$W/src" ]; then grep -Ef "$W/src" "$W/kept" >"$W/files" || true; else cp "$W/kept" "$W/files"; fi

  # Manifestos (pastas de pacote) vem da lista sem filtro de source_globs.
  MANIFEST_RE="$MANIFEST_RE" awk -F/ '$NF ~ ENVIRON["MANIFEST_RE"] { print }' "$W/kept" >"$W/manifests"

  # Texto nao vazio (grep -I pula binario) e numero de linhas.
  : >"$W/loc"
  if [ -s "$W/files" ]; then
    (cd "$repo" && tr '\n' '\0' <"$W/files" | xargs -0 grep -Il '' 2>/dev/null | tr -d '\r' |
      tr '\n' '\0' | xargs -0 awk 'FNR == 1 { if (f != "") print f "\t" c; f = FILENAME; c = 0 } { c++ } END { if (f != "") print f "\t" c }' 2>/dev/null) |
      LC_ALL=C sort >"$W/loc"
  fi

  : >"$W/changed"
  if [ "${#SINCE[@]}" -gt 0 ]; then
    since=""
    for s in "${SINCE[@]}"; do
      case "$s" in
        *=*) [ "${s%%=*}" = "$rel" ] && since="${s#*=}" ;;
        *) [ "$MULTI" -eq 0 ] && since="$s" ;;
      esac
    done
    if [ -n "$since" ]; then
      { git -C "$repo" -c core.quotepath=off diff --name-only "$since" 2>/dev/null
        git -C "$repo" -c core.quotepath=off ls-files -o --exclude-standard 2>/dev/null; } | tr -d '\r' | sort -u >"$W/changed"
    fi
  fi

  prefix=""
  if [ "$MULTI" -eq 1 ]; then
    if [ "$rel" = "." ]; then prefix="${repo##*/}"; else prefix="$rel"; fi
  fi

  awk -v maxf="$MAX_FILES" -v maxl="$MAX_LOC" -v prefix="$prefix" -v repo="$rel" -v area="$RAREA" \
    -v mfile="$W/manifests" -v cfile="$W/changed" '
    function dirof(p,   i) { i = match(p, /\/[^\/]*$/); return i ? substr(p, 1, i - 1) : "." }
    function parentof(d,   i) { if (d == ".") return ""; i = match(d, /\/[^\/]*$/); return i ? substr(d, 1, i - 1) : "." }
    function lastseg(d,   i) { if (d == ".") return "raiz"; i = match(d, /[^\/]*$/); return substr(d, i) }
    function slug(s) { s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); gsub(/^-+|-+$/, "", s); return s == "" ? "x" : s }
    function dname(d) { return d == "." ? "raiz" : d }
    function push(base, files, kind, cnt, lc) { nq++; QB[nq] = base; QF[nq] = files; QK[nq] = kind; QC[nq] = cnt; QL[nq] = lc }
    function leaf(base, files, kind, cnt, lc, loc_key) { BC[base] += cnt; nl++; LB[nl] = base; LF[nl] = files; LK[nl] = kind; LC[nl] = cnt; LL[nl] = lc; LKEY[nl] = loc_key }
    BEGIN {
      FS = "\t"
      while ((getline line < mfile) > 0) { md = dirof(line); if (md in MAN) MAN[md] = MAN[md] SUBSEP line; else MAN[md] = line; if (md != ".") PKG[md] = 1 }
      while ((getline line < cfile) > 0) { CH[line] = 1; nch++; CHL[nch] = line }
    }
    {
      n++; P[n] = $1; L[n] = $2 + 0; IDX[$1] = n
      d = dirof($1); g = ""
      while (d != "" && d != ".") { if (d in PKG) { g = d; break } d = parentof(d) }
      if (g == "") { i = index($1, "/"); g = i ? substr($1, 1, i - 1) : "." }
      if (!(g in GF)) { ng++; GORDER[ng] = g }
      if (g in GF) GF[g] = GF[g] " " n; else GF[g] = n; GC[g]++; GL[g] += L[n]
    }
    END {
      if (n == 0) exit
      for (k = 1; k <= ng; k++) { g = GORDER[k]; push(g, GF[g], (g in PKG) ? "pkg" : "dir", GC[g], GL[g]) }
      # Subdivisao.
      for (q = 1; q <= nq; q++) {
        base = QB[q]; cnt = QC[q]; lc = QL[q]
        if (cnt <= maxf && lc <= maxl) {
          key = (QK[q] == "direct" || base == ".") ? base : parentof(base)
          leaf(base, QF[q], QK[q], cnt, lc, key); continue
        }
        m = split(QF[q], fl, " ")
        delete CF; delete CC; delete CLc; nco = 0; delete CO
        dfiles = ""; dc = 0; dl = 0
        for (j = 1; j <= m; j++) {
          f = fl[j]; p = P[f]
          r = (base == ".") ? p : substr(p, length(base) + 2)
          i = index(r, "/")
          if (i == 0 || QK[q] == "direct") { dfiles = dfiles (dc ? " " : "") f; dc++; dl += L[f]; continue }
          c = (base == ".") ? substr(r, 1, i - 1) : base "/" substr(r, 1, i - 1)
          if (!(c in CF)) { nco++; CO[nco] = c; CF[c] = f } else CF[c] = CF[c] " " f
          CC[c]++; CLc[c] += L[f]
        }
        if (dc == 0 && nco == 1) { push(CO[1], CF[CO[1]], "dir", CC[CO[1]], CLc[CO[1]]); continue }
        if (nco == 0) {
          # So arquivos diretos: fatias em ordem de caminho.
          parts = int((cnt + maxf - 1) / maxf); pl = int((lc + maxl - 1) / maxl); if (pl > parts) parts = pl
          per = int((m + parts - 1) / parts); part = 0
          for (j = 1; j <= m; j += per) {
            part++; s = ""; sc = 0; sl = 0
            for (t = j; t < j + per && t <= m; t++) { s = s (sc ? " " : "") fl[t]; sc++; sl += L[fl[t]] }
            leaf(base, s, "chunk" part, sc, sl, "chunk:" base)
          }
          continue
        }
        if (dc > 0) push(base, dfiles, "direct", dc, dl)
        for (k = 1; k <= nco; k++) { c = CO[k]; push(c, CF[c], "dir", CC[c], CLc[c]) }
      }
      # Agrupa folhas vizinhas pequenas (mesma pasta-mae), em ordem de caminho.
      for (k = 1; k <= nl; k++) ORD[k] = k
      for (a = 2; a <= nl; a++) { v = ORD[a]; b = a - 1
        while (b >= 1 && (LKEY[ORD[b]] > LKEY[v] || (LKEY[ORD[b]] == LKEY[v] && LB[ORD[b]] > LB[v]))) { ORD[b + 1] = ORD[b]; b-- }
        ORD[b + 1] = v }
      nu = 0
      for (a = 1; a <= nl; a++) {
        k = ORD[a]
        if (nu > 0 && LK[k] !~ /^chunk/ && UK[nu] == LKEY[k] && UMERGE[nu] && UC[nu] + LC[k] <= maxf && UL[nu] + LL[k] <= maxl) {
          UF[nu] = UF[nu] " " LF[k]; UC[nu] += LC[k]; UL[nu] += LL[k]; UB[nu] = UB[nu] SUBSEP LB[k]; UN[nu]++; continue
        }
        nu++; UF[nu] = LF[k]; UC[nu] = LC[k]; UL[nu] = LL[k]; UB[nu] = LB[k]; UK[nu] = LKEY[k]; UN[nu] = 1
        UMERGE[nu] = (LK[k] !~ /^chunk/); UKIND[nu] = LK[k]
      }
      # Dono de cada pasta: unidade unica ou "*" (mista).
      for (u = 1; u <= nu; u++) {
        m = split(UF[u], fl, " ")
        for (j = 1; j <= m; j++) { f = fl[j]; OWNER[f] = u; d = dirof(P[f])
          while (d != "") { if (!(d in DOWN)) DOWN[d] = u; else if (DOWN[d] != u) DOWN[d] = "*"; d = parentof(d) } }
      }
      for (u = 1; u <= nu; u++) {
        # Nome.
        nb = split(UB[u], bl, SUBSEP)
        if (UKIND[u] ~ /^chunk/) nm = slug(dname(bl[1])) "-" substr(UKIND[u], 6)
        else if (UKIND[u] == "direct") nm = slug(dname(bl[1])) "-arquivos"
        else if (nb == 1) nm = slug(dname(bl[1]))
        else {
          pk = UK[u]; nm = (pk == "." || pk == "") ? "" : slug(pk) "-"
          if (nb <= 3) { for (j = 1; j <= nb; j++) nm = nm (j > 1 ? "-" : "") slug(lastseg(bl[j])) }
          else { big = bl[1]; for (j = 2; j <= nb; j++) if (BC[bl[j]] > BC[big]) big = bl[j]; nm = nm slug(lastseg(big)) "-mais-" (nb - 1) }
        }
        if (prefix != "") nm = slug(prefix) "-" nm
        base_nm = nm; dup = 1; while (nm in USED) { dup++; nm = base_nm "-" dup } USED[nm] = 1
        # Caminhos: maior pasta so desta unidade, ou o arquivo.
        delete SEEN; np = 0; delete PL
        m = split(UF[u], fl, " ")
        for (j = 1; j <= m; j++) {
          f = fl[j]; d = dirof(P[f]); top = ""
          while (d != "" && DOWN[d] == u && (area == "" || d == area || index(d, area "/") == 1)) { top = d; d = parentof(d) }
          g = (top == "") ? P[f] : (top == "." ? "**" : top "/**")
          if (!(g in SEEN)) { SEEN[g] = 1; np++; PL[np] = g }
        }
        paths = ""; for (j = 1; j <= np; j++) paths = paths (j > 1 ? "\037" : "") PL[j]
        # Manifestos: os da pasta de pacote mais proxima de cada base.
        delete MS; mans = ""
        for (j = 1; j <= nb; j++) { d = bl[j]
          while (d != "" && !(d in MAN)) d = parentof(d)
          if (d != "" && !(d in MS)) { MS[d] = 1; gsub(SUBSEP, "\037", MAN[d]); mans = mans (mans != "" ? "\037" : "") MAN[d] } }
        UNAME[u] = nm; UPATHS[u] = paths; UMANS[u] = mans
        for (j = 1; j <= np; j++) if (PL[j] ~ /\*\*$/) { dd = PL[j]; sub(/\/?\*\*$/, "", dd); if (dd == "") dd = "."; DIRU[dd] = u }
      }
      # Alterados: arquivo da unidade ou pasta coberta por um glob dela.
      for (c = 1; c <= nch; c++) {
        p = CHL[c]
        if (p in IDX) { UCH[OWNER[IDX[p]]]++; continue }
        d = dirof(p); while (d != "" && !(d in DIRU)) d = parentof(d)
        if (d != "") UCH[DIRU[d]]++
      }
      for (u = 1; u <= nu; u++)
        printf "%s\t%s\t%s\t%d\t%d\t%s\t%d\n", repo, UNAME[u], UPATHS[u], UC[u], UL[u], UMANS[u], UCH[u] + 0
    }' "$W/loc" >>"$TMPD/units.tsv"
done

jq -Rn --arg root "$ROOT" --arg primary "$PRIMARY" --argjson maxf "$MAX_FILES" --argjson maxl "$MAX_LOC" --argjson maxa "$MAX_AGENTS" \
  --argjson par "$PARALLEL" --argjson since "$([ "${#SINCE[@]}" -gt 0 ] && echo true || echo false)" \
  --rawfile repos "$TMPD/repos.tsv" '
  def split_us: if . == "" then [] else split("\u001f") end;
  [inputs | select(length > 0) | split("\t") |
    {repo: .[0], unit: .[1], paths: (.[2] | split_us), file_count: (.[3] | tonumber), loc: (.[4] | tonumber),
     manifests: (.[5] | split_us), changed: ((.[6] | tonumber) > 0), changed_files: (.[6] | tonumber)}] as $u |
  ($u | length) as $n |
  {root: $root, primary: $primary,
   repos: [$repos | split("\n")[] | select(length > 0) | split("\t") | {repo: .[0], path: .[1], commit: .[2]}],
   limits: {unit_max_files: $maxf, unit_max_loc: $maxl, max_agents: $maxa, parallel: $par},
   units: $u,
   totals: {units: $n, files: ([$u[].file_count] | add // 0), loc: ([$u[].loc] | add // 0),
            agents: (if $n > 0 then $n + 2 + (($n + $par - 1) / $par | floor) else 0 end),
            changed: (if $since then ([$u[] | select(.changed)] | length) else null end)}}' <"$TMPD/units.tsv" | tr -d '\r'
