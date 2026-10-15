---
name: viarootread
description: Teste de Read com CLAUDE_PLUGIN_ROOT em allowed-tools.
disable-model-invocation: true
allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**)
---
Leia com a ferramenta Read o arquivo `${CLAUDE_PLUGIN_ROOT}/scripts/mark.sh` e responda só com a primeira linha dele, ou com o erro recebido.
