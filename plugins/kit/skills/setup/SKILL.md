---
name: setup
description: Confere se a máquina está pronta para o kit. Verifica Claude Code mínimo, git, bash, jq, bwrap e socat no Linux/WSL2, a plataforma e o sandbox. Só verifica: não grava nada e nunca toca no ~/.claude/settings.json.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" check) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" status)
---

## Regras que valem a tarefa inteira
- Só verificação. O kit nunca escreve no settings do usuário (`~/.claude/settings.json` ou `CLAUDE_CONFIG_DIR`): permissão é por projeto, e o `/kit:init` pergunta quais grupos entram no `.claude/settings.json` do projeto.
- Todo passo usa `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" <subcomando>`.
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`). Os comandos de instalação vêm prontos do script.

## Passos
1. Rode `setup.sh status`: dependências, plataforma e marketplace `claude-kit`.
2. **Resumo**, em até 6 linhas:
   - Cada linha `ok` em uma linha só (versões).
   - Plataforma e sandbox: no Windows nativo, uma linha dizendo que não há sandbox (disco e rede sem isolamento; valem as permissões do projeto e os guardas do kit) e que o WSL2 tem sandbox.
   - Cada linha `falta` como está, com o comando de instalação que ela traz.
   - Cada linha `aviso` como está.
   - Última linha: `Pronto. Próximo: /kit:init no repositório.` (com algo em `falta`: `Faltam dependências; o /kit:init instala com a sua confirmação.`).
