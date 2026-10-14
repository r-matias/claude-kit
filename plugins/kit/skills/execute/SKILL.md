---
name: execute
description: Executa um PLAN.md wave a wave, com behavior virando teste, done como critério de conclusão, checkpoint entre waves e wave final de revisão independente.
argument-hint: "[caminho do PLAN.md]"
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git branch *)
---

## Estado atual
!`git status --short 2>/dev/null || echo "(não é repo git)"`
!`git branch --show-current 2>/dev/null || echo "(não é repo git)"`

## Regras que valem a tarefa inteira
- Siga as waves na ordem. Dentro da wave, tarefas listadas em `Paralelo:` podem ser delegadas ao mesmo tempo, uma por subagent (`general-purpose`), cada um recebendo files, behavior, action, verify e done da sua tarefa e a SPEC; as demais rodam em sequência, na ordem do plano. Não adiante trabalho de waves futuras.
- Cada linha de `behavior` vira um teste da própria tarefa antes ou junto da implementação. Use `action` e o molde `arquivo:linha` indicado.
- `done` é o critério de `[x]`: só marque quando a assertiva estiver comprovada pelo `verify` (ou por comando/observação objetiva) e registre a evidência. Nunca marque `[x]` sem evidência.
- Comandos vêm de `.claude/kit.json`; não invente comandos do stack. Mudança em `Interfaces` exige registro em Decisões.
- Decisão técnica pequena que surgir (nome, parâmetro, flag, pasta, biblioteca já prevista): decida pelo padrão mais simples coerente com a SPEC e o código, registre em Decisões do PLAN.md (`- <data> · kit · <decisão> — <motivo>`), atualize o doc de referência se houver um, e siga.
- Pare e pergunte só em: decisão de produto (o que o usuário vê, regra de negócio), escopo fora da SPEC, decisão cara de reverter (schema público, contrato de API, dependência nova) ou ação irreversível (deploy, push, chamada a serviço externo real, migração em banco real). Na dúvida entre técnica e produto, conta como produto. A resposta entra em Decisões com `· usuário ·`.
- Após duas tentativas falhas na mesma tarefa, pare, resuma o que tentou e recomende `/clear` com um prompt melhor.
- Plano no formato antigo (sem waves): cada tarefa é uma wave sequencial e a verificação final do plano faz o papel da wave final.

## Passos
1. Plano: $ARGUMENTS. Sem argumento, use o PLAN.md mais recente em `docs/specs/`. Leia o PLAN.md e a SPEC.md ao lado. Retome da primeira caixa `- [ ]`.
2. Para cada tarefa `- [ ]` da wave:
   1. Escreva os testes do `behavior` (use o `kit:test-writer` quando a tarefa for principalmente testes) e implemente seguindo `action`.
   2. Rode o `verify` da tarefa e mostre o resultado.
   3. Confira o `done`. Marque `- [x]` e acrescente abaixo `  - Evidência: <comando> → <resultado resumido>`.
3. **Checkpoint** (caixa `Checkpoint wave N`):
   1. Re-rode os `verify` de todas as tarefas da wave juntos; falha reabre a tarefa (`- [ ]`) e volta ao passo 2.
   2. Confirme que cada `done` da wave continua valendo.
   3. Avalie o contexto. Acima de ~70% de uso, marque o checkpoint, pare e recomende `/compact` seguido de `/kit:execute <caminho>`: o PLAN.md guarda o estado e a execução retoma da próxima caixa.
   4. Marque o checkpoint `- [x]` com a evidência.
4. **Wave final**, passo a passo:
   1. F1: chame o `kit:code-reviewer` (caminhos da SPEC e do PLAN, lista de `git diff --name-only`) e o `kit:security-reviewer` (mesma lista).
   2. F2: corrija todo BLOCKER e MAJOR e chame de novo o revisor que apontou, até não sobrar nenhum. MINOR fica anotado.
   3. F3: rode a verificação ponta a ponta da SPEC.
   4. F4 (se existir): rode `smoke` do `kit.json`.
   Marque cada passo com a evidência.
5. Resuma: waves e tarefas concluídas, evidências, decisões novas, achados MINOR pendentes e o que o security-reviewer apontou. Não commite sem pedido explícito.
