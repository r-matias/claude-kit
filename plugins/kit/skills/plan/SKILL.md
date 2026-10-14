---
name: plan
description: Transforma uma SPEC.md em PLAN.md derivado de must_haves, com interfaces exatas, tarefas em waves (files, behavior, action, verify, done), checkpoints e wave final de revisão, já revisado por um subagent. Use depois de /kit:spec ou quando houver uma spec pronta para planejar.
argument-hint: "[caminho da SPEC.md]"
---

## Regras que valem a tarefa inteira
- Não escreva código de produção nesta skill. A saída é o PLAN.md e, quando houver, a atualização do doc de referência descrita abaixo.
- Formato do PLAN.md: [template.md](template.md). Siga as seções e os campos na ordem; não invente seções.
- Só tarefas, checkpoints e passos da wave final levam caixa `- [ ]`. Truths, artifacts, tests, behavior e decisões são bullets simples: os hooks contam as caixas para mostrar o progresso.
- Cada tarefa cabe num diff revisável (ordem de grandeza: até ~5 arquivos, uma ideia).
- Comandos de `verify` vêm de `.claude/kit.json` (`build`, `test`, `test_related`, `lint`, `typecheck`, `smoke`). Chave ausente: use as que existem e anote a lacuna em Decisões.

## Lacunas: decidir ou perguntar
O usuário não revisa planos. Lacuna técnica que a SPEC e os docs não cobrem (nome de coluna, campo interno, parâmetro, flag, estrutura de pastas, nome de módulo ou teste, uso de biblioteca já prevista no projeto) você decide sozinho:
- Escolha o padrão mais simples coerente com a SPEC, os docs e o código existente.
- Registre em Decisões: `- <data de hoje> · kit · <decisão> — <motivo em uma linha>`.
- Se existir um doc de referência para aquilo (modelo de dados, contrato interno, regra de `coupled_changes` do `kit.json`), atualize esse doc com a decisão e cite-o na linha.

Pergunte com `AskUserQuestion` (opções concretas, recomendada marcada) só nestes três casos, e não grave o PLAN.md até ter a resposta:
1. **Produto:** o que o usuário vê ou regra de negócio (limites, prazos, mensagens, quem pode o quê).
2. **Escopo:** algo fora da SPEC.
3. **Caro de reverter:** schema público, contrato de API, dependência nova.

A resposta entra em Decisões como `- <data> · usuário · <decisão> — <pergunta>`. Na dúvida entre técnica e produto, conta como produto.

## Passos
1. Leia a spec: $ARGUMENTS. Sem argumento, use a SPEC.md mais recente em `docs/specs/`.
2. Delegue ao `kit:investigator` o mapeamento do código afetado: pontos de entrada, padrões a seguir (com `arquivo:linha` do melhor molde para cada tipo de mudança), testes existentes, docs de referência, riscos.
3. Liste as lacunas e classifique cada uma pela regra acima. Pergunte as de produto, escopo ou caras de reverter; decida as técnicas.
4. **must_haves, de trás para frente.** Parta do resultado da SPEC (Objetivo, Escopo, Casos de borda, Verificação ponta a ponta):
   - **truths:** frases que precisam ser verdade quando acabar, cada uma verificável por teste ou comando. Todo item de Escopo e todo caso de borda vira ao menos uma truth.
   - **artifacts:** arquivos que precisam existir ou mudar para as truths valerem, com o que cada um provê.
   - **tests:** arquivos de teste e o que cada um cobre; toda truth é coberta por algum.
5. **Interfaces:** assinaturas, rotas, schemas e códigos de erro exatos que as tarefas implementam ou consomem. Contrato já definido pela SPEC é copiado, não reinventado.
6. **Tarefas**, derivadas dos artifacts e tests. Cada uma com:
   - `files`: só arquivos de artifacts/tests (ou doc de referência).
   - `behavior`: uma linha por comportamento, `<situação> → <resultado>`; cada linha vira um teste da própria tarefa.
   - `action`: como fazer, apontando o molde no código com `arquivo:linha` quando houver.
   - `verify`: chave do `kit.json` (prefira `test_related` com os testes da tarefa).
   - `done`: assertiva testável que fecha a tarefa.
7. **Waves:** agrupe por dependência. Uma tarefa só usa o que waves anteriores criam. Na linha `Paralelo:` da wave, liste as tarefas que não compartilham arquivo com nenhuma outra da mesma wave. Termine cada wave com a caixa de checkpoint do template.
8. **Wave final**, fixa, como no template. Remova o passo F4 se o `kit.json` não tiver `smoke`.
9. Grave `PLAN.md` ao lado da SPEC.md.
10. Chame o `kit:plan-reviewer` com os caminhos da SPEC.md e do PLAN.md. Corrija todo achado BLOCKER e MAJOR no PLAN.md e chame de novo, até "aprovado" ou só MINOR (no máximo 3 rodadas; se sobrar BLOCKER, diga qual).
11. Entregue um resumo de até 5 linhas: caminho do PLAN.md, número de waves e tarefas, decisões (quantas e a principal), resultado da revisão e o próximo passo (`/kit:execute <caminho>`).
