---
name: setup
description: Prepara a máquina para o kit, uma vez por máquina. Confere Claude Code, git, bash e jq, ajusta o sandbox à plataforma e cria ou completa o ~/.claude/settings.json com as regras de usuário do kit (merge só aditivo, com backup e confirmação).
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *) Read(${CLAUDE_PLUGIN_ROOT}/**)
---

## Regras que valem a tarefa inteira
- O `/kit:init` executa os passos 1 a 3 quando o `setup.sh status` aponta falta e junta a proposta à confirmação única dele; ao terminar, ele segue para o projeto.
- O `~/.claude/settings.json` existente só recebe merge aditivo: o kit acrescenta itens em arrays e chaves ausentes, nunca remove, nunca troca valor existente e nunca mexe em `hooks`. Antes de gravar, `setup.sh apply` faz backup em `settings.json.bak-kit-<data>`. Única troca: `enabledPlugins."kit@claude-kit"`, pela resposta de escopo. Conflito fica com o valor do usuário e vira uma linha no resumo.
- Todo passo usa `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" <subcomando>`. Não edite o settings à mão.
- O settings fica em `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`; o script já resolve isso.

## Passos
1. **Dependências.** Rode `setup.sh check`. Cada linha `falta` traz o comando de instalação: ele entra na confirmação (passo 4) e roda se aprovado. Linhas `aviso` não param o setup; repita-as no resumo.
2. **Plataforma.** Guarde a linha `plataforma:` do check. No Windows nativo, o resumo diz em uma linha que não há sandbox (disco e rede sem isolamento; valem `permissions.deny` e os guardas do kit) e que o WSL2 mantém o sandbox.
3. **Proposta.** Rode `setup.sh propose todos`. A saída é o arquivo novo, o diff do merge aditivo ou `sem mudança`, mais as linhas `conflito:` e `troca:`.
4. **Confirmação.** Mostre os comandos de instalação e o diff e faça **uma** chamada de `AskUserQuestion` com duas perguntas:
   - "Gravar?": Gravar (recomendado) / Cancelar.
   - Escopo: "Todos os projetos" (o kit fica ligado em toda sessão desta máquina) ou "Só nos projetos que o habilitam" (desligado no usuário; cada projeto liga no próprio `.claude/settings.json`, que o `/kit:init` cria ou completa).
5. **Gravar.** Rode os comandos de instalação aprovados e `setup.sh check` de novo; dependência que continuar faltando para aqui com um aviso de uma linha. Com escopo "Só nos projetos que o habilitam", rode `setup.sh propose opt-in`. Depois `setup.sh apply` e mostre a linha `criado:` ou `gravado: ... (backup em ...)`.
6. **Resumo**, em até 6 linhas: dependências e versões, plataforma e sandbox, escopo escolhido, o que foi gravado (com o backup), conflitos mantidos e avisos. Última linha: `Pronto. Próximo: /kit:init no repositório.`
