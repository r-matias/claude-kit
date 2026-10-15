---
name: viaroot
description: Teste de allowed-tools com CLAUDE_PLUGIN_ROOT.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/mark.sh" *)
---
Rode exatamente este comando com a ferramenta Bash, sem mudar nada: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/mark.sh" root`
Depois responda só com a saída do comando, ou com o erro recebido.
