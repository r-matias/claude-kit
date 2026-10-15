#!/usr/bin/env bash
# Merge aditivo de JSON usado pelo /kit:init e pelo /kit:setup nos settings. Nao e hook.
# Aditivo: objetos recursivos, arrays por uniao sem duplicar, chave ausente entra, valor existente
# sempre vence. A chave "hooks" da proposta e ignorada: hooks do settings nunca sao tocados.
#
#   merge-json.sh <existente.json> <proposta.json>
#     Imprime no stdout o merge. Cada conflito vai para o stderr. Existente ausente: imprime a proposta.
#
#   merge-json.sh --preview [--prefer <caminho>] <existente.json> <proposta.json>
#     Imprime o diff do arquivo como ficaria, uma linha "conflito:" por valor mantido e uma linha
#     "troca:" por caminho de --prefer. Nada e gravado. Sem diferenca: "sem mudança: <arquivo>".
#
#   merge-json.sh --apply [--prefer <caminho>] <existente.json> <proposta.json>
#     Grava o merge no arquivo. Existente ausente: cria com a proposta. Existente: backup antes em
#     <arquivo>.bak-kit-<AAAA-MM-DD> (ja existindo, com a hora no nome) e recusa se o resultado
#     perder ou trocar algo fora de --prefer. settings.local.json e recusado sempre.
#
#   --prefer <caminho>: caminho jq em JSON (ex.: '["enabledPlugins","kit@claude-kit"]') em que a
#     proposta vence. So para a chave do proprio kit, quando o usuario escolheu o valor.
#
#   merge-json.sh --check <antes.json> <depois.json>
#     Exit 0 se "depois" so acrescenta a "antes" (todo valor folha e todo item de array preservados).
#     Exit 1 listando no stderr o que foi removido ou alterado.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "merge-json: jq nao encontrado" >&2; exit 2; }

MERGE_DEF='
  def merge($x; $y):
    if ($x | type) == "object" and ($y | type) == "object" then
      reduce ($y | keys_unsorted[]) as $k ($x;
        .[$k] = (if ($x | has($k)) then merge($x[$k]; $y[$k]) else $y[$k] end))
    elif ($x | type) == "array" and ($y | type) == "array" then
      reduce $y[] as $e ($x; if any(.[]; . == $e) then . else . + [$e] end)
    else $x end;
  def conflicts($x; $y; $p):
    if ($x | type) == "object" and ($y | type) == "object" then
      $y | keys_unsorted[] as $k | select($x | has($k)) | conflicts($x[$k]; $y[$k]; $p + [$k])
    elif ($x | type) == "array" and ($y | type) == "array" then empty
    elif $x == $y then empty
    else {path: $p, kept: $x, proposed: $y} end;
  def dotted($p): $p | map(if test("^[A-Za-z_][A-Za-z0-9_]*$") then "." + . else ".\"" + . + "\"" end) | join("");'

if [ "${1:-}" = "--check" ]; then
  [ $# -eq 3 ] || { echo "uso: merge-json.sh --check <antes.json> <depois.json>" >&2; exit 2; }
  [ -f "$2" ] || exit 0
  [ -f "$3" ] || { echo "removido: arquivo inteiro" >&2; exit 1; }
  lost="$(jq -rn --slurpfile a "$2" --slurpfile b "$3" '
    def lost($x; $y; $p):
      if ($x | type) == "object" then
        if ($y | type) != "object" then "\($p): tipo mudou"
        else $x | keys_unsorted[] as $k |
          if ($y | has($k)) then lost($x[$k]; $y[$k]; "\($p).\($k)") else "\($p).\($k): removido" end
        end
      elif ($x | type) == "array" then
        if ($y | type) != "array" then "\($p): tipo mudou"
        else $x[] as $e | select(any($y[]; . == $e) | not) | "\($p)[]: item removido \($e | tojson)"
        end
      elif $x != $y then "\($p): \($x | tojson) -> \($y | tojson)"
      else empty end;
    lost($a[0]; $b[0]; "$")' 2>&1 | tr -d '\r')" || { echo "merge-json: JSON invalido: $lost" >&2; exit 2; }
  if [ -n "$lost" ]; then
    printf '%s\n' "$lost" >&2
    exit 1
  fi
  exit 0
fi

MODE=merge
PREFER='[]'
case "${1:-}" in
  --preview | --apply) MODE="${1#--}"; shift ;;
esac
while [ "${1:-}" = "--prefer" ]; do
  [ $# -ge 2 ] || { echo "merge-json: --prefer sem caminho" >&2; exit 2; }
  PREFER="$(jq -cn --argjson acc "$PREFER" --argjson p "$2" '$acc + [$p]' 2>/dev/null)" ||
    { echo "merge-json: --prefer espera um caminho jq em JSON, ex.: '[\"a\",\"b\"]'" >&2; exit 2; }
  shift 2
done
[ $# -eq 2 ] || { echo "uso: merge-json.sh [--preview|--apply] [--prefer <caminho>] <existente.json> <proposta.json>" >&2; exit 2; }
EXIST="$1"
PROP="$2"
jq empty "$PROP" >/dev/null 2>&1 || { echo "merge-json: proposta invalida: $PROP" >&2; exit 2; }
if [ -f "$EXIST" ] && ! jq empty "$EXIST" >/dev/null 2>&1; then
  echo "merge-json: $EXIST nao e JSON valido; nada foi gravado" >&2
  exit 2
fi

# Proposta sem "hooks" (o kit nunca mexe em hooks do settings).
proposal() { jq 'if type == "object" then del(.hooks) else . end' "$PROP" | tr -d '\r'; }

# Merge com as trocas de --prefer aplicadas, no stdout.
merged() {
  jq -n --slurpfile a "$EXIST" --argjson b "$(proposal)" --argjson pf "$PREFER" "$MERGE_DEF"'
    reduce $pf[] as $p (merge($a[0]; $b);
      if ($b | getpath($p)) != null then setpath($p; $b | getpath($p)) else . end)' | tr -d '\r'
}

# Linhas "conflito:" (valor mantido) e "troca:" (caminho de --prefer com valor diferente).
notes() {
  jq -rn --slurpfile a "$EXIST" --argjson b "$(proposal)" --argjson pf "$PREFER" "$MERGE_DEF"'
    conflicts($a[0]; $b; []) as $c |
    if any($pf[]; . == $c.path) then "troca: \(dotted($c.path)) \($c.kept | tojson) -> \($c.proposed | tojson)"
    else "conflito: \(dotted($c.path)) mantido \($c.kept | tojson) (o kit propunha \($c.proposed | tojson))" end' | tr -d '\r'
}

if [ "$MODE" = "merge" ]; then
  if [ ! -f "$EXIST" ]; then proposal; exit 0; fi
  merged || exit 2
  notes >&2
  exit 0
fi

case "$(basename "$EXIST")" in
  settings.local.json) echo "merge-json: $EXIST é configuração pessoal; o kit não altera" >&2; exit 2 ;;
esac

if [ "$MODE" = "preview" ]; then
  if [ ! -f "$EXIST" ]; then
    diff -u --label "$EXIST (novo)" --label "$EXIST" /dev/null <(proposal | jq .)
    exit 0
  fi
  out="$(merged)" || exit 2
  if jq -e --slurpfile a "$EXIST" '. == $a[0]' <<<"$out" >/dev/null 2>&1; then
    echo "sem mudança: $EXIST"
    exit 0
  fi
  diff -u --label "$EXIST" --label "$EXIST (com o kit)" <(jq . "$EXIST" | tr -d '\r') <(printf '%s\n' "$out")
  notes
  exit 0
fi

# apply
if [ ! -f "$EXIST" ]; then
  mkdir -p "$(dirname "$EXIST")"
  proposal | jq . >"$EXIST" || exit 2
  echo "criado: $EXIST"
  exit 0
fi
TMPM="$(mktemp)"
trap 'rm -f "$TMPM" "$TMPM.a" "$TMPM.b"' EXIT
merged >"$TMPM" || exit 2
jq empty "$TMPM" >/dev/null 2>&1 || { echo "merge-json: falha ao montar o merge; nada foi gravado" >&2; exit 2; }
if jq -e --slurpfile a "$EXIST" '. == $a[0]' "$TMPM" >/dev/null 2>&1; then
  echo "sem mudança: $EXIST"
  exit 0
fi
# Fora de --prefer, o resultado so pode acrescentar.
jq --argjson pf "$PREFER" 'reduce $pf[] as $p (.; delpaths([$p]))' "$EXIST" | tr -d '\r' >"$TMPM.a"
jq --argjson pf "$PREFER" 'reduce $pf[] as $p (.; delpaths([$p]))' "$TMPM" | tr -d '\r' >"$TMPM.b"
if ! bash "$(dirname "${BASH_SOURCE[0]}")/merge-json.sh" --check "$TMPM.a" "$TMPM.b"; then
  echo "merge-json: o resultado perderia algo de $EXIST; nada foi gravado" >&2
  exit 1
fi
NOTES="$(notes)"
BAK="$EXIST.bak-kit-$(date +%Y-%m-%d)"
[ -e "$BAK" ] && BAK="$EXIST.bak-kit-$(date +%Y-%m-%d-%H%M%S)"
cp -p "$EXIST" "$BAK" || { echo "merge-json: falha ao gravar o backup $BAK; nada foi gravado" >&2; exit 2; }
cat "$TMPM" >"$EXIST" || { cp -p "$BAK" "$EXIST"; echo "merge-json: falha ao gravar $EXIST; restaurado do backup" >&2; exit 2; }
echo "gravado: $EXIST (backup em $BAK)"
[ -n "$NOTES" ] && printf '%s\n' "$NOTES"
exit 0
