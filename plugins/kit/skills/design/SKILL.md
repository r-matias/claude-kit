---
name: design
description: Define a direção visual do projeto com amostras em HTML que você abre no navegador antes de escolher, e grava a rule de direção (.claude/rules/kit-design.md), docs/specs/<slug>/DESIGN.md e a amostra escolhida. Use quando o pedido é dar identidade visual a um projeto com tela ou redesenhar o app; não escreve código de produção nem SPEC.
argument-hint: "[app | rota ou arquivo da página | componente]"
allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**)
---

## Regras que valem a tarefa inteira
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`): ou o valor está configurado e o comando funciona como está, ou pergunte o valor antes (`AskUserQuestion`) e grave no lugar certo (o que não é segredo na config versionada do projeto, carregada pelo script; segredo em `.env`/`.env.test` carregado pelo script, nunca lido por você).
- Não escreva código de produção nesta skill. Ela grava só as amostras em `.claude/state/ui/design/`, a rule de direção em `.claude/rules/` e o `DESIGN.md` com a amostra escolhida em `docs/specs/<slug>/`. Tokens, fontes e telas do projeto mudam depois, por SPEC, plano, `verify` e revisores.
- Não grave SPEC nem plano aqui: a skill termina com o comando da `/kit:spec` pronto.
- A direção é escolha do usuário, feita com a amostra aberta no navegador. Nunca grave a rule de direção sem essa escolha.
- Uma direção por projeto. Fonte e paleta só mudam no escopo app, ou numa área com direção própria.
- Amostra só tem dado fictício: nunca dado real, credencial ou segredo. A escolhida vai para o git.
- Você não vê a amostra renderizada. Descreva cada uma pela direção e pelo que o subagent devolveu, sem afirmar como ficou na tela.
- Sem `AskUserQuestion` disponível: faça as perguntas no texto, com as opções, e pare sem gravar nada.
- Argumento: $ARGUMENTS
- Raiz do plugin, chamada de `<raiz-do-plugin>` em [passos.md](passos.md): `${CLAUDE_PLUGIN_ROOT}`
- **Custo.** A cada subagent que volta, anote o tipo dele e o `subagent_tokens` do bloco `<usage>` da notificação de fim (sem `<usage>`, conte o subagent e marque os tokens como desconhecidos). Amostra refeita conta como chamada nova.

## Passos
Leia [passos.md](passos.md) (`${CLAUDE_SKILL_DIR}/passos.md`) agora e siga-o do começo ao fim.
