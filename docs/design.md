# Desenho do claude-kit

Resumo das decisões que sustentam o kit. Instalação, uso e o comportamento exato de cada peça estão no [README](../README.md).

## Versão mínima

**Claude Code ≥ 2.1.295.** É a versão que introduz `onFailure: "block"`, usado nos guardas (`guard-bash`, `guard-files`): sem ele, um guarda cujo script falta, quebra ou estoura o tempo deixa a ação passar. O `plugin.json` não aceita campo de versão mínima do Claude Code (os campos com versão são `version`, do próprio plugin, e `dependencies`, de outros plugins), então a exigência fica neste documento, no README e no aviso que o `session-context` mostra quando `claude --version` é menor.

A tabela de recursos dependentes de versão está na seção Requisitos do README.

## Princípios

1. **Contexto é o recurso escasso.** O que não precisa estar em todo turno vira skill (carrega sob demanda) ou vai para um subagent (contexto separado).
2. **Verificação fecha o loop.** Um check que devolve passa/falha (build, teste, lint) deixa Claude iterar sozinho; o Stop hook transforma isso em portão.
3. **Explorar, planejar, implementar, commitar.** Plano para mudança multi-arquivo ou incerta; diff de uma frase dispensa plano.
4. **CLAUDE.md é conselho; hooks e permissões são garantia.** Regra que precisa valer sempre vai para hook ou permissão.
5. **Quem escreve não revisa.** Revisores rodam em contexto novo, sem permissão de escrita, e só apontam o que afeta correção ou requisito.
6. **Menos peças, mais focadas.** Cada skill, agent e hook precisa ganhar seu lugar.
7. **Após duas correções falhas, `/clear`.** Sessão nova com prompt melhor vence sessão longa com tentativas erradas.

## Três camadas

| Camada | Onde fica | Conteúdo | Muda por stack? |
| --- | --- | --- | --- |
| Usuário | `~/.claude/settings.json` | Deny de segredos e comandos destrutivos, sandbox | Não |
| Plugin `kit` | Este repositório | Skills de fluxo, subagents, hooks e scripts | Não |
| Adaptador | `.claude/kit.json`, `.claude/settings.json` e `CLAUDE.md` do projeto | Comandos do stack, caminhos protegidos, regras de domínio | Sim |

Os hooks e as skills nunca chamam um comando de stack diretamente: leem a chave do `kit.json`. Chave ausente é pulada sem erro.

## Decisões

- **Guardas falham fechado.** Sem `jq`, os guardas saem com 2; com `onFailure: "block"`, também bloqueiam se não conseguirem rodar. Hooks de qualidade e de contexto falham aberto (saem com 0), porque não protegem nada.
- **Hooks em forma shell.** Todos os hooks usam `"shell": "bash"` e `"command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh\""`, sem `args`. A forma exec resolve `command` no PATH, e no Windows sem `Git\bin` no PATH o guarda nem inicia; com `onFailure: "block"`, isso trava todo Bash/Edit/Write. A forma shell roda pelo Git Bash que o Claude Code localiza, sem depender do PATH. A suíte simula o caso chamando o `bash.exe` do Git com um PATH sem nenhum `bash`.
- **PowerShell fora por padrão.** Os guardas só cobrem `Bash` e `Edit|Write|MultiEdit`. A ferramenta PowerShell executaria comandos sem passar por eles, então o template de usuário põe `"PowerShell"` (nome puro, que remove a ferramenta do contexto) em `permissions.deny`. Quem precisar dela tira essa linha e fica sem guarda nessa ferramenta.
- **Uma mensagem por turno.** O `verify-gate` junta falhas de comandos, `key_parity` e `coupled_changes` de todos os repositórios da sessão numa única mensagem, para Claude corrigir tudo de uma vez.
- **Aviso não é bloqueio.** Acoplamentos do tipo "se mudou X, confira Y" usam `level: "warn"` e chegam como contexto na edição (JSON `additionalContext`, porque stdout puro de PostToolUse não chega ao Claude), escritos como fato e não como ordem.
- **Adoção soma, não substitui.** Em repositório com configuração própria, o `/kit:init` só acrescenta; uma peça existente só sai depois de prova de equivalência e confirmação explícita, um commit por peça.
- **Fronteira.** Nenhum exemplo, teste ou template cita projeto real: só caminhos fictícios.
