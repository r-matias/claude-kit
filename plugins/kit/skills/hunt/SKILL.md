---
name: hunt
description: Investiga uma falha vaga ou intermitente sem causa clara e devolve hipóteses ranqueadas com evidência, sem editar código. Use quando algo às vezes falha, está lento, se comporta estranho ou ninguém sabe onde quebrou.
argument-hint: "[sintoma]"
allowed-tools: Bash(git status *) Bash(git log *)
---

## Estado atual
!`git status --short 2>/dev/null || echo "(não é repo git)"`
!`git log --oneline -10 2>/dev/null || echo "(sem commits)"`

## Regras que valem a tarefa inteira
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`): ou o valor está configurado e o comando funciona como está, ou pergunte o valor antes (`AskUserQuestion`) e grave no lugar certo (o que não é segredo na config versionada do projeto, carregada pelo script; segredo em `.env`/`.env.test` carregado pelo script, nunca lido por você).
- Você não edita, cria nem apaga arquivos nesta skill. Só investiga.
- Toda hipótese precisa de evidência concreta (código, log, saída de comando, commit). Sem evidência, confiança baixa.
- Comandos vêm de `.claude/kit.json`; não invente comandos do stack.

## Passos
1. Colete o sintoma: $ARGUMENTS. Se faltar algo, pergunte com `AskUserQuestion` só o que muda a investigação: quando começou, frequência, mensagem de erro ou log, como reproduzir, o que mudou recentemente.
2. Reconhecimento rápido: se existir `docs/codemap.md`, leia a parte da área suspeita antes (o código vence quando divergir); logs e mensagens citadas, `git log` recente nas áreas suspeitas, tentativa de reprodução com `test_related` ou `test` se houver caminho.
3. Formule até três hipóteses distintas e falsificáveis.
4. Dispare um subagent `kit:investigator` por hipótese, em paralelo (na mesma mensagem). Peça a cada um evidência a favor e contra.
5. Devolva as hipóteses ranqueadas:

| # | Hipótese | Evidência a favor | Evidência contra | Confiança |
|---|---|---|---|---|

6. Termine com o próximo passo concreto: o experimento que separa as duas primeiras hipóteses, ou `/kit:fix <hipótese escolhida>` quando houver uma clara.
