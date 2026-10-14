---
name: setup
description: Prepara a máquina para o kit, uma vez por máquina. Confere Claude Code, git, bash e jq, ajusta o sandbox à plataforma e cria ~/.claude/settings.json com as regras de usuário do kit, ou, se ele já existir, gera ao lado a sugestão do que somar.
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *) Read(${CLAUDE_PLUGIN_ROOT}/**)
---

## Regras que valem a tarefa inteira
- O `/kit:init` executa estes mesmos passos quando o `setup.sh status` aponta falta; ao terminar, ele segue para o projeto.
- O kit nunca altera um `~/.claude/settings.json` que já existe. Só cria o arquivo quando ele falta; senão grava `kit-settings.suggested.json` ao lado, e o usuário aplica se quiser.
- Todo passo usa `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" <subcomando>`. Não edite o settings à mão nem instale dependências: mostre o comando e deixe o usuário rodar.
- O settings fica em `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`; o script já resolve isso.

## Passos
1. **Dependências.** Rode `setup.sh check`. Se o exit for 1, mostre cada linha `falta` com o comando de instalação, diga para rodar o comando, reabrir o Claude Code e rodar `/kit:init` (ou `/kit:setup`) de novo, e pare aqui. Linhas `aviso` não param o setup; repita-as no resumo.
2. **Plataforma.** Repita a linha `plataforma:` do check. No Windows nativo, diga com todas as letras que não há sandbox (disco e rede sem isolamento; só `permissions.deny` e os guardas do kit protegem) e que o WSL2 mantém o sandbox.
3. **Escopo.** Pergunte com `AskUserQuestion`:
   - "Todos os projetos": o kit fica ligado em toda sessão desta máquina (`enabledPlugins."kit@claude-kit": true`).
   - "Só nos projetos que o habilitam": desligado no usuário (`false`); cada projeto liga no próprio `.claude/settings.json`, que o `/kit:init` cria quando falta.
4. **Proposta.** Rode `setup.sh propose todos` ou `setup.sh propose opt-in`.
   - Settings inexistente: a saída termina em `proposta:`. Mostre o diff inteiro, pergunte com `AskUserQuestion` (gravar ou cancelar) e, com "gravar", rode `setup.sh apply` e mostre a linha `gravado`.
   - Settings existente: a saída termina em `sugestão:` (ou `nada a sugerir`). Nada é gravado no settings. Mostre o diff e a linha `troca sugerida`, se houver, e diga que o usuário aplica a sugestão se quiser. No Windows nativo, se o settings tiver `sandbox.failIfUnavailable: true`, avise que isso impede o Claude Code de iniciar e que a troca para `false` é dele.
5. **Resumo**, em até 6 linhas: dependências e versões, plataforma e sandbox, escopo escolhido, o que foi criado ou o caminho da sugestão, avisos, e o próximo passo: reiniciar o Claude Code para o sandbox valer e rodar `/kit:init` em cada repositório.
