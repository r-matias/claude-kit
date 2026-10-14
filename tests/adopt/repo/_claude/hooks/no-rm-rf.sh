#!/usr/bin/env bash
# Bloqueia rm -rf em qualquer comando Bash.
cmd="$(jq -r '.tool_input.command // empty')"
if printf '%s' "$cmd" | grep -Eq 'rm[[:space:]]+-[a-zA-Z]*(rf|fr)'; then
  echo "Bloqueado: rm -rf nao e permitido neste projeto." >&2
  exit 2
fi
exit 0
