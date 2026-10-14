#!/usr/bin/env bash
# Grava o estado atual da pasta (rastreados e nao rastreados, respeitando .gitignore) como uma
# arvore git e imprime o hash, sem tocar no index nem criar commit. O /kit:execute usa o hash
# como base da wave: `git diff <base> <hash de agora>` e o diff da wave.
# Uso: wave-base.sh [pasta]
set -u

dir="${1:-.}"
top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')" || true
[ -n "$top" ] || { echo "kit: $dir não está num repositório git" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
real_index="$(git -C "$top" rev-parse --path-format=absolute --git-path index 2>/dev/null | tr -d '\r')"
[ -f "$real_index" ] && cp "$real_index" "$tmp/index"

GIT_INDEX_FILE="$tmp/index" git -C "$top" add -A >/dev/null 2>&1 || { echo "kit: falha ao ler a pasta" >&2; exit 1; }
GIT_INDEX_FILE="$tmp/index" git -C "$top" write-tree | tr -d '\r'
