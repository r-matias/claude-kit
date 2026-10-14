#!/usr/bin/env bash
# Bloqueia edicao dos textos gerados.
file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
case "$file" in
  *strings/generated/*)
    echo "Arquivo gerado. Edite strings/pt.json e rode o gerador de textos." >&2
    exit 2
    ;;
esac
exit 0
