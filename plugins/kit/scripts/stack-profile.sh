#!/usr/bin/env bash
# Apoio do /kit:init. Nao e hook e nao usa LLM: perfil do stack lido dos manifestos, com contagem de uso.
#
#   stack-profile.sh [--root <pasta>]
#     Repositorios como o map-partition.sh ("repos" do kit.json da raiz, o proprio ou os filhos) e,
#     em cada um, os manifestos dos arquivos que o /kit:map ve. Imprime JSON {root, primary,
#     repos[{repo, commit, packages[{path, manifest, manager}], base[{kind, name, version, source}],
#     deps[{name, ecosystem, version, declared_in[], files_src, files_test}],
#     version_conflicts[{name, versions{<pacote>: <versao>}}]}]}. Repositorio sem manifesto fica de fora.
#     Versao: a declarada, reduzida a major.minor (framework na base: major). files_src e files_test:
#     arquivos de source_globs que citam a dependencia pela forma de import do stack (git grep), teste
#     separado de producao; null no stack sem forma de import conhecida (Maven, Gradle, Gemfile, Composer).
#
#   stack-profile.sh [--root <pasta>] --write
#     Grava docs/stack.md no repositorio principal (map.primary, o da raiz ou o primeiro), com o
#     cabecalho "<!-- kit:init <commit> -->" ou, com varios repositorios, "<!-- kit:init <repo>=<commit> ... -->".
#     Nao sobrescreve docs/stack.md sem esse cabecalho (exit 3). Imprime "gravado: <caminho>".
#
#   stack-profile.sh [--root <pasta>] --status
#     "atualizado", "desatualizado: <manifestos alterados>" ou "ausente", comparando os manifestos de
#     git diff <commit do cabecalho> HEAD em cada repositorio. Exit 1 se desatualizado ou ausente.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "stack-profile: jq não encontrado" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "stack-profile: git não encontrado" >&2; exit 2; }

ROOT="."
MODE="json"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --status) MODE="status"; shift ;;
    --write) MODE="write"; shift ;;
    *) echo "uso: stack-profile.sh [--root <pasta>] [--status | --write]" >&2; exit 2 ;;
  esac
done
ROOT="$(cd "$ROOT" 2>/dev/null && { pwd -W 2>/dev/null || pwd; })" || { echo "stack-profile: pasta inexistente" >&2; exit 2; }
ROOT="$(kit_norm_path "$ROOT")"

REPOS=()
while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done < <(kit_repos "$ROOT" "")
[ "${#REPOS[@]}" -gt 0 ] || { echo "stack-profile: nenhum repositório git em $ROOT" >&2; exit 1; }
PRIMARY="$(kit_primary "$ROOT" ${REPOS[@]+"${REPOS[@]}"})"

if [ "$MODE" = "status" ]; then
  st="$(kit_stack_state "$ROOT" ${REPOS[@]+"${REPOS[@]}"})"
  case "$st" in
    atualizado) echo "atualizado"; exit 0 ;;
    ausente) echo "ausente"; exit 1 ;;
    *) printf 'desatualizado: %s\n' "${st#*$'\t'}"; exit 1 ;;
  esac
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Arquivo de teste: *.test.*, *.spec.*, tests/, test/, __tests__/, *Tests/, *_test.go, test_*.py.
TEST_RE='(^|/)(tests|test|__tests__)/|\.(test|spec)\.[^/]*$|(^|/)[^/]*Tests/|_test\.go$|(^|/)test_[^/]*\.py$'

# Gerenciador pelo lockfile mais proximo, da pasta do pacote ate a raiz do repositorio.
# Uso: lock_manager <pasta-do-pacote> <padrao> (padrao: "arquivo=gerenciador ...")
lock_manager() {
  local d="$1" pair f
  while :; do
    for pair in $2; do
      if [ "$d" = "." ]; then f="${pair%%=*}"; else f="$d/${pair%%=*}"; fi
      grep -qxF "$f" "$W/tracked" && { printf '%s' "${pair#*=}"; return 0; }
    done
    [ "$d" = "." ] && return 0
    case "$d" in */*) d="${d%/*}" ;; *) d="." ;; esac
  done
}

# Registros dos parsers (TSV): P pacote manifesto gerenciador | D eco nome versao pacote manifesto |
# B tipo nome versao fonte | V eco nome versao (versao central) | W eco nome versao (workspace).
parse_manifest() {
  local repo="$1" mf="$2" pkg base file mgr
  pkg="${mf%/*}"
  [ "$pkg" = "$mf" ] && pkg="."
  base="${mf##*/}"
  file="$repo/$mf"
  case "$base" in
    package.json)
      mgr="$(lock_manager "$pkg" "pnpm-lock.yaml=pnpm yarn.lock=yarn bun.lockb=bun bun.lock=bun package-lock.json=npm")"
      jq -r --arg pkg "$pkg" --arg mf "$mf" --arg mgr "${mgr:-npm}" '
        def s: if type == "string" then . else "" end;
        ["P", $pkg, $mf, ((.packageManager | s | sub("@.*"; "")) as $pm | if $pm != "" then $pm else $mgr end)],
        (((.dependencies // {}), (.devDependencies // {}), (.optionalDependencies // {}), (.peerDependencies // {}))
          | objects | to_entries[] | ["D", "npm", .key, (.value | s), $pkg, $mf]),
        (if (.engines.node | s) != "" then ["B", "runtime", "node", .engines.node, $mf] else empty end),
        ["B", "lang", "javascript", "", $mf]
        | join("\t")' "$file" 2>/dev/null | tr -d '\r' ;;
    composer.json)
      jq -r --arg pkg "$pkg" --arg mf "$mf" '
        def s: if type == "string" then . else "" end;
        ["P", $pkg, $mf, "composer"],
        (((.require // {}), (."require-dev" // {})) | objects | to_entries[]
          | select(.key | test("^(php$|ext-|lib-|composer-)") | not) | ["D", "composer", .key, (.value | s), $pkg, $mf]),
        ["B", "lang", "php", (.require.php | s), $mf]
        | join("\t")' "$file" 2>/dev/null | tr -d '\r' ;;
    *.csproj | *.fsproj | *.vbproj)
      local lang=csharp
      case "$base" in *.fsproj) lang=fsharp ;; *.vbproj) lang=vb ;; esac
      tr -d '\r' <"$file" | awk -v pkg="$pkg" -v mf="$mf" -v lang="$lang" '
        function attr(tag, a) { if (match(tag, "[ \t]" a "=\"[^\"]*\"")) return substr(tag, RSTART + length(a) + 3, RLENGTH - length(a) - 4); return "" }
        function elem(t, e) { if (match(t, "<" e ">[^<]*</" e ">")) return substr(t, RSTART + length(e) + 2, RLENGTH - 2 * length(e) - 5); return "" }
        { t = t " " $0 }
        END {
          print "P\t" pkg "\t" mf "\tnuget"
          s = t
          while (match(s, /<PackageReference[^>]*>/)) {
            tag = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
            name = attr(tag, "Include"); if (name == "") name = attr(tag, "Update")
            v = attr(tag, "Version"); if (v == "") v = attr(tag, "VersionOverride")
            if (v == "" && tag !~ /\/>$/) { e = index(s, "</PackageReference>"); if (e) v = elem(substr(s, 1, e + 18), "Version") }
            if (name != "") print "D\tnuget\t" name "\t" v "\t" pkg "\t" mf
          }
          tf = elem(t, "TargetFramework"); if (tf == "") { tf = elem(t, "TargetFrameworks"); sub(/;.*/, "", tf) }
          gsub(/[ \t]/, "", tf); fw = ""; v = ""
          if (tf ~ /^net[0-9]+\.[0-9]/ || tf ~ /^netcoreapp/) { v = tf; sub(/^net(coreapp)?/, "", v); fw = "dotnet" }
          else if (tf ~ /^netstandard/) { v = tf; sub(/^netstandard/, "", v); fw = "netstandard" }
          else if (tf ~ /^net[0-9][0-9]+$/) { v = substr(tf, 4, 1) "." substr(tf, 5); fw = "dotnet-framework" }
          if (fw != "") print "B\tframework\t" fw "\t" v "\t" mf
          if (t ~ /Sdk="Microsoft\.NET\.Sdk\.Web"/) print "B\tframework\taspnetcore\t" v "\t" mf
          print "B\tlang\t" lang "\t" elem(t, "LangVersion") "\t" mf
        }' ;;
    Directory.Packages.props)
      tr -d '\r' <"$file" | awk '
        function attr(tag, a) { if (match(tag, "[ \t]" a "=\"[^\"]*\"")) return substr(tag, RSTART + length(a) + 3, RLENGTH - length(a) - 4); return "" }
        { t = t " " $0 }
        END { s = t
          while (match(s, /<PackageVersion[^>]*>/)) { tag = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
            if (attr(tag, "Include") != "") print "V\tnuget\t" attr(tag, "Include") "\t" attr(tag, "Version") } }' ;;
    pyproject.toml | requirements*.txt)
      mgr="$(lock_manager "$pkg" "uv.lock=uv poetry.lock=poetry Pipfile.lock=pipenv pdm.lock=pdm")"
      tr -d '\r' <"$file" | awk -v pkg="$pkg" -v mf="$mf" -v mgr="${mgr:-pip}" -v req="$([ "$base" = pyproject.toml ] && echo 0 || echo 1)" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function unq(s) { s = trim(s); if (s ~ /^["\047].*["\047]$/) s = substr(s, 2, length(s) - 2); return s }
        function dep(s,   n, i) {
          sub(/;.*/, "", s); i = index(s, " @"); if (i) s = substr(s, 1, i - 1)
          if (!match(s, /^[ \t]*[A-Za-z0-9][A-Za-z0-9._-]*/)) return
          n = trim(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH)
          if (substr(s, 1, 1) == "[") { i = index(s, "]"); s = i ? substr(s, i + 1) : "" }
          print "D\tpypi\t" n "\t" s "\t" pkg "\t" mf
        }
        function strings(line,   m) {
          while (match(line, /"[^"]*"|\047[^\047]*\047/)) { m = substr(line, RSTART + 1, RLENGTH - 2); line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH); dep(m) }
          return line
        }
        req == 1 { sub(/#.*/, ""); if ($0 ~ /^[ \t]*(-|$)/) next; dep($0); next }
        inarr { line = $0; if (line ~ /include-group/) gsub(/"[^"]*"/, "", line); if (strings(line) ~ /\]/) inarr = 0; next }
        /^[ \t]*\[/ { sec = trim($0); gsub(/^\[+|\]+$/, "", sec); sec = trim(sec)
          if (sec ~ /^tool\.poetry/) hint = "poetry"; else if (sec ~ /^tool\.uv/) hint = "uv"; else if (sec ~ /^tool\.pdm/) hint = "pdm"
          next }
        {
          i = index($0, "="); if (!i) next
          key = unq(substr($0, 1, i - 1)); val = trim(substr($0, i + 1))
          if (sec == "project" && key == "requires-python") { py = unq(val); next }
          if ((sec == "project" && key == "dependencies") || sec == "project.optional-dependencies" || sec == "dependency-groups") {
            if (substr(val, 1, 1) == "[") { if (strings(substr(val, 2)) !~ /\]/) inarr = 1 }
            next
          }
          if (sec ~ /^tool\.poetry\.(dependencies|dev-dependencies|group\.[^.]+\.dependencies)$/) {
            if (substr(val, 1, 1) == "{") { v = ""; if (match(val, /version[ \t]*=[ \t]*"[^"]*"/)) { v = substr(val, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/"$/, "", v) } }
            else v = unq(val)
            if (key == "python") py = v; else print "D\tpypi\t" key "\t" v "\t" pkg "\t" mf
          }
        }
        END {
          print "P\t" pkg "\t" mf "\t" (hint != "" && mgr == "pip" ? hint : mgr)
          print "B\tlang\tpython\t" py "\t" mf
        }' ;;
    go.mod)
      tr -d '\r' <"$file" | awk -v pkg="$pkg" -v mf="$mf" '
        /^go[ \t]+[0-9]/ { gv = $2; next }
        /^require[ \t]*\(/ { inreq = 1; next }
        inreq && /^[ \t]*\)/ { inreq = 0; next }
        /^require[ \t]+[^( \t]/ { if ($0 !~ /\/\/ *indirect/) print "D\tgo\t" $2 "\t" $3 "\t" pkg "\t" mf; next }
        inreq && NF >= 2 && $1 !~ /^\/\// { if ($0 !~ /\/\/ *indirect/) print "D\tgo\t" $1 "\t" $2 "\t" pkg "\t" mf }
        END { print "P\t" pkg "\t" mf "\tgo"; print "B\tlang\tgo\t" gv "\t" mf; print "B\ttest\tgo test\t\t" mf }' ;;
    Cargo.toml)
      tr -d '\r' <"$file" | awk -v pkg="$pkg" -v mf="$mf" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function unq(s) { s = trim(s); if (s ~ /^["\047].*["\047]$/) s = substr(s, 2, length(s) - 2); return s }
        function field(val, k,   m) { if (match(val, k "[ \t]*=[ \t]*(\"[^\"]*\"|true)")) { m = substr(val, RSTART, RLENGTH); sub(/^[^=]*=[ \t]*/, "", m); return unq(m) } return "" }
        function emit(name, ver, ws, local) {
          if (name == "") return
          if (wsdeps) { print "W\tcargo\t" name "\t" ver; return }
          if (ws) ver = "@ws"; else if (local && ver == "") return
          nd++; print "D\tcargo\t" name "\t" ver "\t" pkg "\t" mf
        }
        function flush() { if (tname != "") emit(tname, tver, tws, tlocal); tname = ""; tver = ""; tws = 0; tlocal = 0 }
        /^[ \t]*\[/ { flush(); sec = trim($0); gsub(/^\[+|\]+$/, "", sec); sec = trim(sec)
          wsdeps = (sec == "workspace.dependencies")
          dsec = wsdeps || sec ~ /^(target\..*\.)?(dev-|build-)?dependencies$/
          if (sec ~ /^(target\..*\.)?(dev-|build-)?dependencies\.[^.]+$/) { tname = sec; sub(/.*\./, "", tname); tname = unq(tname) }
          if (sec == "package") haspkg = 1
          next }
        {
          i = index($0, "="); if (!i) next
          key = unq(substr($0, 1, i - 1)); val = trim(substr($0, i + 1))
          if ((sec == "package" || sec == "workspace.package") && key == "rust-version") { rv = unq(val); next }
          if (tname != "") {
            if (key == "version") tver = unq(val); else if (key == "workspace") tws = (val ~ /^true/); else if (key == "path") tlocal = 1
            next
          }
          if (!dsec) next
          if (key ~ /\.workspace$/) { sub(/\.workspace$/, "", key); emit(key, "", 1, 0); next }
          if (substr(val, 1, 1) == "{") emit(key, field(val, "version"), field(val, "workspace") == "true", val ~ /(^|[{ ,])path[ \t]*=/)
          else emit(key, unq(val), 0, 0)
        }
        END {
          flush()
          if (haspkg || nd) { print "P\t" pkg "\t" mf "\tcargo"; print "B\tlang\trust\t" rv "\t" mf; print "B\ttest\tcargo test\t\t" mf }
          else if (rv != "") print "B\tlang\trust\t" rv "\t" mf
        }' ;;
    pom.xml)
      tr -d '\r' <"$file" | awk -v pkg="$pkg" -v mf="$mf" '
        function elem(t, e) { if (match(t, "<" e ">[^<]*</" e ">")) return substr(t, RSTART + length(e) + 2, RLENGTH - 2 * length(e) - 5); return "" }
        function cut(t, a, b,   i, j) { i = index(t, a); j = index(t, b); if (i && j > i) return substr(t, 1, i - 1) substr(t, j + length(b)); return t }
        function prop(v,   p) { if (v ~ /^\$\{.*\}$/) { p = substr(v, 3, length(v) - 3); return elem(all, p) } return v }
        { all = all " " $0 }
        END {
          print "P\t" pkg "\t" mf "\tmaven"
          i = index(all, "<parent>"); j = index(all, "</parent>")
          if (i && j > i) { par = substr(all, i, j - i)
            if (elem(par, "artifactId") == "spring-boot-starter-parent") print "B\tframework\tspring-boot\t" elem(par, "version") "\t" mf }
          s = cut(cut(cut(all, "<build>", "</build>"), "<dependencyManagement>", "</dependencyManagement>"), "<parent>", "</parent>")
          while ((i = index(s, "<dependency>")) > 0) {
            s = substr(s, i + 12); j = index(s, "</dependency>"); if (!j) break
            body = substr(s, 1, j - 1); s = substr(s, j + 13)
            g = elem(body, "groupId"); a = elem(body, "artifactId")
            if (g != "" && a != "") print "D\tmaven\t" g ":" a "\t" prop(elem(body, "version")) "\t" pkg "\t" mf
          }
          jv = elem(all, "java.version"); if (jv == "") jv = elem(all, "maven.compiler.release"); if (jv == "") jv = elem(all, "maven.compiler.source")
          print "B\tlang\tjava\t" jv "\t" mf
        }' ;;
    build.gradle | build.gradle.kts)
      tr -d '\r' <"$file" | awk -v pkg="$pkg" -v mf="$mf" '
        function q(line,   m) { m = ""; while (match(line, /["\047][^"\047]+["\047]/)) { m = substr(line, RSTART + 1, RLENGTH - 2); line = substr(line, RSTART + RLENGTH) } return m }
        /^[ \t]*(implementation|api|compileOnly|runtimeOnly|testImplementation|testRuntimeOnly|testCompileOnly|annotationProcessor|kapt|ksp|developmentOnly)[ \t(]/ {
          if (match($0, /["\047][^"\047:]+:[^"\047:]+(:[^"\047]+)?["\047]/)) {
            c = substr($0, RSTART + 1, RLENGTH - 2); n = split(c, p, ":")
            print "D\tgradle\t" p[1] ":" p[2] "\t" (n > 2 ? p[3] : "") "\t" pkg "\t" mf
          }
          next
        }
        /org\.springframework\.boot["\047]/ && /version/ { sb = q($0) }
        /kotlin\(["\047]jvm["\047]\)/ && /version/ { kv = q($0); kt = 1 }
        /org\.jetbrains\.kotlin\.jvm/ && /version/ { kv = q($0); kt = 1 }
        /JavaLanguageVersion\.of\(|VERSION_[0-9]|sourceCompatibility/ { if (match($0, /[0-9]+(_[0-9]+)?/)) { jv = substr($0, RSTART, RLENGTH); gsub(/_/, ".", jv) } }
        END {
          print "P\t" pkg "\t" mf "\tgradle"
          if (sb != "") print "B\tframework\tspring-boot\t" sb "\t" mf
          if (kt) print "B\tlang\tkotlin\t" kv "\t" mf; else print "B\tlang\tjava\t" jv "\t" mf
        }' ;;
    Gemfile)
      tr -d '\r' <"$file" | awk -v pkg="$pkg" -v mf="$mf" '
        /^[ \t]*gem[ \t]+["\047]/ { s = $0; sub(/^[ \t]*gem[ \t]+/, "", s); n = split(s, p, /["\047][ \t]*,[ \t]*["\047]?/)
          name = p[1]; gsub(/["\047]/, "", name); v = (n > 1 ? p[2] : ""); sub(/["\047].*/, "", v)
          print "D\tgem\t" name "\t" v "\t" pkg "\t" mf; next }
        /^[ \t]*ruby[ \t]+["\047]/ { rv = $2; gsub(/["\047,]/, "", rv) }
        END { print "P\t" pkg "\t" mf "\tbundler"; print "B\tlang\truby\t" rv "\t" mf }' ;;
  esac
}

# Citacoes de import no codigo do repositorio: "eco<TAB>arquivo<TAB>trecho", uma por ocorrencia.
grep_imports() {
  local repo="$1" eco="$2" re
  shift 2
  case "$eco" in
    npm) re="[\"'](@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+[\"'/]" ;;
    cargo) re='[A-Za-z_][A-Za-z0-9_]*::' ;;
    nuget) re='using[[:space:]]+(static[[:space:]]+)?[A-Za-z_][A-Za-z0-9_.]*' ;;
    pypi) re='^[[:space:]]*(import|from)[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*' ;;
    go) re='^[[:space:]]*(import[[:space:]]+)?([A-Za-z_.][A-Za-z0-9_]*[[:space:]]+)?"[A-Za-z0-9._~/-]+"' ;;
  esac
  git -C "$repo" -c core.quotepath=off grep -I -o -E --no-color -e "$re" -- "$@" 2>/dev/null | tr -d '\r' |
    awk -v eco="$eco" '{ i = index($0, ":"); if (!i) next; m = substr($0, i + 1); gsub(/\t/, " ", m); print eco "\t" substr($0, 1, i - 1) "\t" m }'
}

: >"$TMPD/repos.jsonl"
NREPOS="${#REPOS[@]}"
idx=0
for repo in ${REPOS[@]+"${REPOS[@]}"}; do
  idx=$((idx + 1))
  rel="$(kit_rel_to "$ROOT" "$repo")"
  W="$TMPD/r$idx"
  mkdir -p "$W"
  kit_repo_files "$ROOT" "$repo" "$rel" "$W"
  git -C "$repo" -c core.quotepath=off ls-files 2>/dev/null | tr -d '\r' >"$W/tracked"
  KIT_DEP_MANIFEST_RE="$KIT_DEP_MANIFEST_RE" awk -F/ '$NF ~ ENVIRON["KIT_DEP_MANIFEST_RE"] { print }' "$W/kept" >"$W/depmf"
  [ -s "$W/depmf" ] || continue

  : >"$W/recs"
  while IFS= read -r mf; do parse_manifest "$repo" "$mf" >>"$W/recs"; done <"$W/depmf"
  grep -q '^P' "$W/recs" || continue

  : >"$W/hits"
  ecos="$(awk -F'\t' '$1 == "D" { print $2 }' "$W/recs" | sort -u)"
  for eco in $ecos; do
    case "$eco" in
      npm) grep_imports "$repo" npm '*.js' '*.jsx' '*.ts' '*.tsx' '*.mjs' '*.cjs' '*.mts' '*.cts' '*.vue' '*.svelte' '*.astro' >>"$W/hits" ;;
      cargo) grep_imports "$repo" cargo '*.rs' >>"$W/hits" ;;
      nuget) grep_imports "$repo" nuget '*.cs' '*.razor' '*.cshtml' >>"$W/hits" ;;
      pypi) grep_imports "$repo" pypi '*.py' '*.pyi' >>"$W/hits" ;;
      go) grep_imports "$repo" go '*.go' >>"$W/hits" ;;
    esac
  done

  KIT_TEST_RE="$TEST_RE" awk -F'\t' -v ffile="$W/files" -v hfile="$W/hits" '
    function ver(v) {
      if (v ~ /^(file:|link:|git|https?:|github:|portal:|\*|latest)/ || v ~ /^workspace:\*/) return ""
      if (match(v, /[0-9]+(\.[0-9]+)?/)) return substr(v, RSTART, RLENGTH)
      return ""
    }
    function major(v) { sub(/\..*/, "", v); return v }
    function key(eco, n) {
      if (eco == "cargo") gsub(/-/, "_", n)
      else if (eco == "nuget") n = tolower(n)
      else if (eco == "pypi") { n = tolower(n); gsub(/[-.]/, "_", n) }
      return n
    }
    function addbase(kind, name, v, src,   k) {
      k = kind SUBSEP name
      if (!(k in BV)) { nb++; BO[nb] = k; BK[k] = kind; BN[k] = name; BV[k] = v; BS[k] = src }
      else if (BV[k] == "" && v != "") { BV[k] = v; BS[k] = src }
    }
    function hit(eco, k, path,   id) {
      if (!((eco SUBSEP k) in KEY)) return
      id = KEY[eco SUBSEP k]
      if ((path SUBSEP id) in SEEN) return
      SEEN[path SUBSEP id] = 1
      if (path ~ ENVIRON["KIT_TEST_RE"]) T[id]++; else S[id]++
    }
    BEGIN {
      split("npm|typescript|lang|typescript|mm npm|react|framework|react|M npm|next|framework|next|M npm|@angular/core|framework|angular|M npm|vue|framework|vue|M npm|nuxt|framework|nuxt|M npm|svelte|framework|svelte|M npm|@sveltejs/kit|framework|sveltekit|M npm|astro|framework|astro|M npm|solid-js|framework|solid|M npm|preact|framework|preact|M npm|lit|framework|lit|M npm|express|framework|express|M npm|fastify|framework|fastify|M npm|koa|framework|koa|M npm|hono|framework|hono|M npm|@nestjs/core|framework|nestjs|M npm|electron|framework|electron|M npm|@tauri-apps/api|framework|tauri|M npm|react-native|framework|react-native|M npm|expo|framework|expo|M npm|@remix-run/react|framework|remix|M npm|vitest|test|vitest|mm npm|jest|test|jest|mm npm|mocha|test|mocha|mm npm|@playwright/test|test|playwright|mm npm|cypress|test|cypress|mm npm|jasmine-core|test|jasmine|mm npm|karma|test|karma|mm npm|ava|test|ava|mm cargo|tauri|framework|tauri|M cargo|axum|framework|axum|M cargo|actix-web|framework|actix-web|M cargo|rocket|framework|rocket|M cargo|warp|framework|warp|M cargo|bevy|framework|bevy|M cargo|leptos|framework|leptos|M cargo|yew|framework|yew|M cargo|tokio|runtime|tokio|mm nuget|xunit|test|xunit|mm nuget|nunit|test|nunit|mm nuget|mstest.testframework|test|mstest|mm pypi|django|framework|django|M pypi|flask|framework|flask|M pypi|fastapi|framework|fastapi|M pypi|tornado|framework|tornado|M pypi|pytest|test|pytest|mm go|github.com/gin-gonic/gin|framework|gin|M go|github.com/labstack/echo|framework|echo|M go|github.com/gofiber/fiber|framework|fiber|M go|github.com/go-chi/chi|framework|chi|M go|github.com/stretchr/testify|test|testify|mm gem|rails|framework|rails|M gem|sinatra|framework|sinatra|M gem|hanami|framework|hanami|M gem|rspec|test|rspec|mm gem|rspec-rails|test|rspec|mm gem|minitest|test|minitest|mm composer|laravel/framework|framework|laravel|M composer|symfony/framework-bundle|framework|symfony|M composer|slim/slim|framework|slim|M composer|phpunit/phpunit|test|phpunit|mm composer|pestphp/pest|test|pest|mm", L, " ")
      for (i in L) { split(L[i], p, "|"); BT[p[1] SUBSEP key(p[1], p[2])] = p[3] "|" p[4] "|" p[5] }
      while ((getline line < ffile) > 0) SRC[line] = 1
    }
    $1 == "P" { if (!($2 in PK)) { PK[$2] = 1; np++; print "PKG\t" $2 "\t" $3 "\t" $4 } next }
    $1 == "V" { CV[$2 SUBSEP key($2, $3)] = $4; next }
    $1 == "W" { WV[$2 SUBSEP key($2, $3)] = $4; next }
    $1 == "B" { nbr++; BR[nbr] = $0; next }
    $1 == "D" {
      id = $2 SUBSEP $3
      if ((id SUBSEP $5) in DP) next
      raw = $4
      if (raw == "@ws") raw = WV[$2 SUBSEP key($2, $3)]
      else if (raw == "" && $2 == "nuget") raw = CV[$2 SUBSEP key($2, $3)]
      v = ver(raw); DP[id SUBSEP $5] = v
      if (!(id in DE)) { nd++; DO[nd] = id; DE[id] = $2; DN[id] = $3; DECL[id] = $5; KEY[$2 SUBSEP key($2, $3)] = id }
      else DECL[id] = DECL[id] "\037" $5
      if (v != "" && !((id SUBSEP "v" SUBSEP v) in DV)) { DV[id SUBSEP "v" SUBSEP v] = 1; NV[id]++; VL[id] = VL[id] (VL[id] == "" ? "" : ", ") v }
      DSRC[id] = DSRC[id] == "" ? $6 : DSRC[id]
      next
    }
    END {
      while ((getline line < hfile) > 0) {
        split(line, h, "\t"); eco = h[1]; path = h[2]; m = h[3]
        if (!(path in SRC)) continue
        if (eco == "npm") { m = substr(m, 2, length(m) - 2); hit(eco, m, path) }
        else if (eco == "cargo") { sub(/::$/, "", m); hit(eco, m, path) }
        else if (eco == "nuget" || eco == "pypi") {
          sub(/^[ \t]*(using|import|from)[ \t]+/, "", m); if (eco == "nuget") sub(/^static[ \t]+/, "", m)
          if (eco == "pypi") { sub(/\..*/, "", m); hit(eco, key(eco, m), path) }
          else { m = tolower(m); while (m != "") { hit(eco, m, path); if (!sub(/\.[^.]*$/, "", m)) m = "" } }
        }
        else if (eco == "go") { sub(/^[^"]*"/, "", m); sub(/".*/, "", m); while (m != "") { hit(eco, m, path); if (!sub(/\/[^\/]*$/, "", m)) m = "" } }
      }
      for (i = 1; i <= nbr; i++) { split(BR[i], b, "\t"); addbase(b[2], b[3], b[2] == "framework" ? major(ver(b[4])) : ver(b[4]), b[5]) }
      for (i = 1; i <= nd; i++) {
        id = DO[i]; eco = DE[id]; n = DN[id]; k = key(eco, n)
        if (eco == "go") sub(/\/v[0-9]+$/, "", k)
        bt = ""
        if ((eco SUBSEP k) in BT) bt = BT[eco SUBSEP k]
        else if ((eco == "maven" || eco == "gradle") && n ~ /^org\.springframework\.boot:/) bt = "framework|spring-boot|M"
        else if ((eco == "maven" || eco == "gradle") && (n ~ /^org\.junit/ || n == "junit:junit")) bt = "test|junit|mm"
        else if ((eco == "maven" || eco == "gradle") && n == "org.testng:testng") bt = "test|testng|mm"
        else if (eco == "nuget" && k ~ /^xunit\.v3($|\.)/ && k !~ /runner/) bt = "test|xunit|mm"
        else if (eco == "nuget" && k == "mstest") bt = "test|mstest|mm"
        if (bt != "") { split(bt, p, "|"); split(VL[id], vv, ", "); v = vv[1]; if (p[3] == "M") v = major(v); addbase(p[1], p[2], v, DSRC[id]) }
        cnt = (eco == "npm" || eco == "cargo" || eco == "nuget" || eco == "pypi" || eco == "go")
        printf "DEP\t%s\t%s\t%s\t%s\t%s\t%s\n", eco, n, VL[id], DECL[id], cnt ? S[id] + 0 : "-", cnt ? T[id] + 0 : "-"
        if (NV[id] > 1) { m = split(DECL[id], dl, "\037"); for (j = 1; j <= m; j++) printf "CONF\t%s\t%s\t%s\n", n, dl[j], DP[id SUBSEP dl[j]] }
      }
      ts = (("lang" SUBSEP "typescript") in BV)
      for (i = 1; i <= nb; i++) { k = BO[i]; if (ts && k == ("lang" SUBSEP "javascript")) continue; printf "BASE\t%s\t%s\t%s\t%s\n", BK[k], BN[k], BV[k], BS[k] }
    }' "$W/recs" >"$W/agg"

  commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null | tr -d '\r')"
  jq -Rn --arg repo "$rel" --arg commit "$commit" '
    def us: if . == "" then [] else split("\u001f") end;
    def num: if . == "-" then null else tonumber end;
    [inputs | select(length > 0) | split("\t")] as $r |
    {repo: $repo, commit: $commit,
     packages: [$r[] | select(.[0] == "PKG") | {path: .[1], manifest: .[2], manager: .[3]}],
     base: ([$r[] | select(.[0] == "BASE") | {kind: .[1], name: .[2], version: .[3], source: .[4]}]
       | sort_by({lang: 0, runtime: 1, framework: 2, test: 3}[.kind] // 9)),
     deps: ([$r[] | select(.[0] == "DEP") | {name: .[2], ecosystem: .[1], version: .[3], declared_in: (.[4] | us),
       files_src: (.[5] | num), files_test: (.[6] | num)}]
       | sort_by([-(.files_src // -1), -(.files_test // -1), .name])),
     version_conflicts: ([$r[] | select(.[0] == "CONF")] | group_by(.[1])
       | map({name: .[0][1], versions: (map({key: .[2], value: .[3]}) | from_entries)}))}' <"$W/agg" | tr -d '\r' >>"$TMPD/repos.jsonl"
done

PROFILE="$(jq -s --arg root "$ROOT" --arg primary "$PRIMARY" '{root: $root, primary: $primary, repos: .}' "$TMPD/repos.jsonl" | tr -d '\r')"

if [ "$MODE" = "json" ]; then
  printf '%s\n' "$PROFILE"
  exit 0
fi

# --write: docs/stack.md no repositorio principal.
if [ "$(jq '.repos | length' <<<"$PROFILE")" = "0" ]; then
  echo "sem manifesto: perfil não gravado"
  exit 0
fi
if [ "$PRIMARY" = "." ]; then DEST="$ROOT"; else DEST="$ROOT/$PRIMARY"; fi
TARGET="$DEST/docs/stack.md"
if [ -f "$TARGET" ] && ! head -n 5 "$TARGET" | grep -qF '<!-- kit:init '; then
  echo "stack-profile: $(kit_rel_to "$ROOT" "$TARGET") existe sem o cabeçalho kit:init; não sobrescrito" >&2
  exit 3
fi
if [ "$NREPOS" -eq 1 ]; then
  HEADER="<!-- kit:init $(jq -r '.repos[0].commit' <<<"$PROFILE" | tr -d '\r') -->"
else
  HEADER="<!-- kit:init $(jq -r '[.repos[] | select(.commit != "") | .repo + "=" + .commit] | join(" ")' <<<"$PROFILE" | tr -d '\r') -->"
fi
mkdir -p "$DEST/docs"
{
  printf '%s\n' "$HEADER"
  jq -r --argjson multi "$([ "$NREPOS" -gt 1 ] && echo true || echo false)" '
    def h($n): (if $multi then "#" else "" end) + ("#" * $n) + " ";
    def code: "`" + . + "`";
    def cell: if . == null then "—" else tostring end;
    {lang: "Linguagem", runtime: "Runtime", framework: "Framework", test: "Teste"} as $kinds |
    "# Perfil do stack",
    "",
    "Gerado pelo /kit:init com `stack-profile.sh`, a partir dos manifestos; o reparo do /kit:init refaz este arquivo. Contagem = arquivos de código que citam a dependência pela forma de import do stack, produção e teste separados. 0 quer dizer \"sem import encontrado\", não \"não usado\". Qual biblioteca é a oficial numa área é decisão do projeto, não deste arquivo.",
    (.repos[] |
      (if $multi then "", "## " + .repo else empty end),
      "",
      h(2) + "Base",
      "",
      (.base[] | "- " + $kinds[.kind] + ": " + .name + (if .version != "" then " " + .version else "" end) + " (" + (.source | code) + ")"),
      ([.packages[].manager] | unique | "- Gerenciador: " + join(", ")),
      (if (.packages | length) > 1 then "- Pacotes: " + ([.packages[] | (.path | code) + " (" + (.manifest | split("/") | last) + ")"] | join(", ")) else empty end),
      ([.deps[] | select((.files_src // 0) + (.files_test // 0) > 0)] as $used |
        if ($used | length) > 0 then
          "", h(2) + "Dependências em uso", "",
          "| Dependência | Versão | Arquivos (produção) | Arquivos (teste) | Declarada em |",
          "| --- | --- | --- | --- | --- |",
          ($used[] | "| " + .name + " | " + (if .version == "" then "—" else .version end) + " | " + (.files_src | cell) + " | " + (.files_test | cell) + " | " + (.declared_in | join(", ")) + " |")
        else empty end),
      ([.deps[] | select(.files_src == 0 and .files_test == 0) | .name] as $none |
        if ($none | length) > 0 then "", h(2) + "Sem import encontrado", "", ($none | sort | join(", ")) else empty end),
      ([.deps[] | select(.files_src == null) | .name + (if .version != "" then " " + .version else "" end)] as $nc |
        if ($nc | length) > 0 then "", h(2) + "Declaradas, sem contagem para este stack", "", ($nc | sort | join(", ")) else empty end),
      (if (.version_conflicts | length) > 0 then
        "", h(2) + "Versões divergentes", "",
        (.version_conflicts[] | "- " + .name + ": " + ([.versions | to_entries[] | (.key | code) + " " + .value] | join(", ")))
      else empty end))' <<<"$PROFILE" | tr -d '\r'
} >"$TARGET"
echo "gravado: $(kit_rel_to "$ROOT" "$TARGET")"
