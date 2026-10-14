---
name: setup
description: Prepara a máquina para o kit, uma vez por máquina. Confere Claude Code, git, bash e jq, ajusta o sandbox à plataforma e mescla as regras de usuário do kit em ~/.claude/settings.json.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *) Read(${CLAUDE_PLUGIN_ROOT}/**)
---

## Regras que valem a tarefa inteira
- Nada é gravado em `~/.claude/settings.json` antes da confirmação explícita do usuário.
- Todo passo usa `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" <subcomando>`. Não edite o settings à mão nem instale dependências: mostre o comando e deixe o usuário rodar.
- O settings fica em `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`; o script já resolve isso.

## Passos
1. **Dependências.** Rode `setup.sh check`. Se o exit for 1, mostre cada linha `falta` com o comando de instalação, diga para rodar o comando, reabrir o Claude Code e rodar `/kit:setup` de novo, e pare aqui. Linhas `aviso` não param o setup; repita-as no resumo.
2. **Plataforma.** Repita a linha `plataforma:` do check. No Windows nativo, diga com todas as letras que não há sandbox (disco e rede sem isolamento; só `permissions.deny` e os guardas do kit protegem) e que o WSL2 mantém o sandbox.
3. **Escopo.** Pergunte com `AskUserQuestion`:
   - "Todos os projetos" — o kit fica ligado em toda sessão desta máquina (`enabledPlugins."kit@claude-kit": true`).
   - "Só nos projetos que o habilitam" — desligado no usuário (`false`); cada projeto liga no próprio `.claude/settings.json`, que o `/kit:init` propõe.
4. **Proposta.** Rode `setup.sh propose todos` ou `setup.sh propose opt-in`. Mostre o diff inteiro e, se houver, os conflitos (`conflito em ...: mantido X, proposto Y`): o valor existente vence. No Windows nativo, um conflito em `sandbox.failIfUnavailable` mantido `true` impede o Claude Code de iniciar; avise e sugira trocar à mão para `false`.
5. **Confirmar.** Pergunte com `AskUserQuestion`: gravar ou cancelar.
6. **Gravar.** Só com "gravar", rode `setup.sh apply`. Exit 0: mostre a linha `gravado`. Exit 1: mostre o que a conferência apontou e diga que o settings original foi restaurado.
7. **Resumo**, em até 6 linhas: dependências e versões, plataforma e sandbox, escopo escolhido, avisos e conflitos, e o próximo passo: reiniciar o Claude Code para o sandbox valer e rodar `/kit:init` em cada repositório.
