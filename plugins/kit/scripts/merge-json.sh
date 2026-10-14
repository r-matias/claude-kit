#!/usr/bin/env bash
# Merge aditivo de JSON usado pelo /kit:init. Nao e hook.
#
#   merge-json.sh <existente.json> <proposta.json>
#     Imprime no stdout o merge chave a chave: objetos recursivos, arrays por uniao sem duplicar,
#     valor existente sempre vence. Cada conflito vai para o stderr. Existente ausente: imprime a proposta.
#
#   merge-json.sh --check <antes.json> <depois.json>
#     Exit 0 se "depois" so acrescenta a "antes" (todo valor folha e todo item de array preservados).
#     Exit 1 listando no stderr o que foi removido ou alterado.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "merge-json: jq nao encontrado" >&2; exit 2; }

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

[ $# -eq 2 ] || { echo "uso: merge-json.sh <existente.json> <proposta.json>" >&2; exit 2; }
if [ ! -f "$1" ]; then
  jq . "$2" | tr -d '\r'
  exit "${PIPESTATUS[0]}"
fi

jq -n --slurpfile a "$1" --slurpfile b "$2" '
  def merge($x; $y):
    if ($x | type) == "object" and ($y | type) == "object" then
      reduce ($y | keys_unsorted[]) as $k ($x;
        .[$k] = (if ($x | has($k)) then merge($x[$k]; $y[$k]) else $y[$k] end))
    elif ($x | type) == "array" and ($y | type) == "array" then
      reduce $y[] as $e ($x; if any(.[]; . == $e) then . else . + [$e] end)
    else $x end;
  merge($a[0]; $b[0])' | tr -d '\r' || exit 2

jq -rn --slurpfile a "$1" --slurpfile b "$2" '
  def conflicts($x; $y; $p):
    if ($x | type) == "object" and ($y | type) == "object" then
      $y | keys_unsorted[] as $k | select($x | has($k)) | conflicts($x[$k]; $y[$k]; "\($p).\($k)")
    elif ($x | type) == "array" and ($y | type) == "array" then empty
    elif $x == $y then empty
    else "conflito em \($p): mantido \($x | tojson), proposto \($y | tojson)" end;
  conflicts($a[0]; $b[0]; "$")' | tr -d '\r' >&2
exit 0
