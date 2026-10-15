---
name: viaskill
description: Teste de allowed-tools com CLAUDE_SKILL_DIR.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/../../scripts/mark.sh" *)
---
Rode exatamente este comando com a ferramenta Bash, sem mudar nada: `bash "${CLAUDE_SKILL_DIR}/../../scripts/mark.sh" skill`
Depois responda só com a saída do comando, ou com o erro recebido.
