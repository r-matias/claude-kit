#!/usr/bin/env bash
# Avisa quando uma tela muda sem o manual mudar junto.
file="$(jq -r '.tool_input.file_path // empty' | tr '\\' '/')"
case "$file" in
  */src/views/*)
    if ! git status --porcelain -- manual | grep -q .; then
      echo "Tela alterada ($file) sem atualizar manual." >&2
      exit 2
    fi
    ;;
esac
exit 0
