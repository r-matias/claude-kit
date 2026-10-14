---
name: plan
description: Transforma uma SPEC.md em PLAN.md com tarefas pequenas, cada uma com arquivos, critério verificável e comando de verificação, já revisado por um subagent. Use depois de /kit:spec ou quando houver uma spec pronta para planejar.
argument-hint: "[caminho da SPEC.md]"
---

## Regras que valem a tarefa inteira
- Não escreva código de produção nesta skill. A saída é o PLAN.md e, quando houver, a atualização do doc de referência descrita abaixo.
- Cada tarefa cabe num diff revisável (ordem de grandeza: até ~5 arquivos, uma ideia).
- Todo critério é verificável por comando ou observação objetiva. "Funciona" não é critério.
- Comandos de verificação vêm de `.claude/kit.json` (`build`, `test`, `test_related`, `lint`, `typecheck`). Chave ausente: use as que existem e anote a lacuna.

## Lacunas: decidir ou perguntar
O usuário não revisa planos. Lacuna técnica que a SPEC e os docs não cobrem (nome de coluna, campo interno, parâmetro, flag, estrutura de pastas, nome de módulo ou teste, uso de biblioteca já prevista no projeto) você decide sozinho:
- Escolha o padrão mais simples coerente com a SPEC, os docs e o código existente.
- Registre em "Decisões assumidas" do PLAN.md: `- <decisão> — <motivo em uma linha>`.
- Se existir um doc de referência para aquilo (modelo de dados, contrato interno, regra de `coupled_changes` do `kit.json`), atualize esse doc com a decisão e cite-o na linha.

Pergunte com `AskUserQuestion` (opções concretas, recomendada marcada) só nestes três casos, e não grave o PLAN.md até ter a resposta:
1. **Produto:** o que o usuário vê ou regra de negócio (limites, prazos, mensagens, quem pode o quê).
2. **Escopo:** algo fora da SPEC.
3. **Caro de reverter:** schema público, contrato de API, dependência nova.

Na dúvida entre técnica e produto, conta como produto.

## Passos
1. Leia a spec: $ARGUMENTS. Sem argumento, use a SPEC.md mais recente em `docs/specs/`.
2. Delegue ao `kit:investigator` o mapeamento do código afetado: pontos de entrada, padrões a seguir, testes existentes, docs de referência, riscos.
3. Liste as lacunas e classifique cada uma pela regra acima. Pergunte as de produto, escopo ou caras de reverter; decida as técnicas.
4. Ordene por dependência; testes entram junto da tarefa que os exige, não numa tarefa final.
5. Grave `PLAN.md` ao lado da SPEC.md:

```markdown
# Plano: <título>
Spec: ./SPEC.md

## Tarefas
- [ ] 1. <verbo + resultado>
  - Arquivos: `caminho`, `caminho`
  - Critério: <condição objetiva>
  - Verificação: `<chave do kit.json>` (+ teste específico se houver)
- [ ] 2. ...

## Verificação final
- [ ] <passo de verificação ponta a ponta da SPEC>

## Decisões assumidas
- <decisão> — <motivo>

## Riscos
- ...
```

6. Chame o `kit:plan-reviewer` com os caminhos da SPEC.md e do PLAN.md. Corrija todo achado BLOCKER e MAJOR no PLAN.md e chame de novo, até "aprovado" ou só MINOR (no máximo 3 rodadas; se sobrar BLOCKER, diga qual).
7. Entregue um resumo de até 5 linhas: caminho do PLAN.md, número de tarefas, decisões assumidas (quantas e a principal), resultado da revisão e o próximo passo (`/kit:execute <caminho>`).
