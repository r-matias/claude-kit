---
name: fix
description: Corrige um bug ou issue pela causa raiz, começando por um teste que reproduz a falha. Use quando algo quebrou, deu erro, regrediu ou um teste falha.
argument-hint: "[issue-ou-descricao]"
allowed-tools: Bash(git status *) Bash(git log *)
---

## Estado atual
!`git status --short 2>/dev/null || echo "(não é repo git)"`
!`git log --oneline -5 2>/dev/null || echo "(sem commits)"`

## Regras que valem a tarefa inteira
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`): ou o valor está configurado e o comando funciona como está, ou pergunte o valor antes (`AskUserQuestion`) e grave no lugar certo (o que não é segredo na config versionada do projeto, carregada pelo script; segredo em `.env`/`.env.test` carregado pelo script, nunca lido por você).
- Nunca corrija sem antes ter um teste que falha pelo motivo certo.
- Corrija a causa, nunca silencie o erro (sem try/catch vazio, sem skip de teste, sem afrouxar asserção).
- Comandos vêm de `.claude/kit.json`; não invente comandos do stack. Chave ausente: diga qual faltou e siga com o que existe.
- Diff mínimo: não refatore nem "melhore" código fora do caminho do bug.

## Passos
1. Entenda o problema: $ARGUMENTS. Se for número de issue, use `gh issue view <n>`.
2. Delegue a localização ao subagent `kit:investigator` (ele lê o `docs/codemap.md`, se existir, e confia no código quando divergir); peça arquivos, linhas e hipótese com evidência.
3. Escreva o teste mínimo que reproduz (ou delegue ao `kit:test-writer`). Rode `test_related` e mostre a falha.
4. Corrija no menor ponto possível. Rode `test_related` e depois `test`.
5. Peça ao subagent `kit:code-reviewer` para revisar o diff contra o bug descrito. Corrija só BLOCKER/MAJOR.
6. Resuma: causa raiz, correção, evidência (saída dos testes) e risco residual.
