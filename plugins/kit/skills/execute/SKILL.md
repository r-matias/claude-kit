---
name: execute
description: Executa um PLAN.md tarefa a tarefa, com verificação, revisão independente e evidência em cada check.
argument-hint: "[caminho do PLAN.md]"
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git branch *)
---

## Estado atual
!`git status --short 2>/dev/null || echo "(não é repo git)"`
!`git branch --show-current 2>/dev/null || echo "(não é repo git)"`

## Regras que valem a tarefa inteira
- Uma tarefa por vez, na ordem do plano. Não adiante trabalho de tarefas futuras.
- Depois de cada edição relevante, rode a verificação da tarefa. Nunca marque `[x]` sem evidência.
- Comandos vêm de `.claude/kit.json`; não invente comandos do stack.
- Se a tarefa exigir mudar o escopo da SPEC (requisito novo, interface diferente, arquivo fora do previsto com impacto), pare e pergunte antes.
- Após duas tentativas falhas na mesma tarefa, pare, resuma o que tentou e recomende `/clear` com um prompt melhor.

## Passos
1. Plano: $ARGUMENTS. Sem argumento, use o PLAN.md mais recente em `docs/specs/`. Leia o PLAN.md e a SPEC.md ao lado.
2. Para cada tarefa `- [ ]`:
   1. Implemente (use o `kit:test-writer` quando a tarefa for principalmente testes).
   2. Rode a verificação da tarefa e mostre o resultado.
   3. Chame o `kit:code-reviewer` com: caminho da SPEC/PLAN, número da tarefa e arquivos alterados.
   4. Corrija só achados BLOCKER e MAJOR; MINOR fica anotado.
   5. Marque a tarefa no PLAN.md como `- [x]` e acrescente abaixo `  - Evidência: <comando> → <resultado resumido>`.
3. Ao final, rode a verificação final do plano e chame o `kit:security-reviewer` com a lista de todos os arquivos alterados (`git diff --name-only`).
4. Resuma: tarefas concluídas, evidências, achados MINOR pendentes e o que o security-reviewer apontou. Não commite sem pedido explícito.
