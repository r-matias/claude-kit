#!/usr/bin/env bash
# PreToolUse/PowerShell: as regras do guard-bash.sh no modo PowerShell (aspas e crase do PowerShell,
# Start-Process, iex de texto, API .NET que apaga). O guard-bash.sh reconhece o modo por este nome.
# Compativel com bash 3.2.
KIT_PWSH_HERE="${BASH_SOURCE[0]%/*}"
[ "$KIT_PWSH_HERE" != "${BASH_SOURCE[0]}" ] || KIT_PWSH_HERE="."
. "$KIT_PWSH_HERE/guard-bash.sh" || exit 2
