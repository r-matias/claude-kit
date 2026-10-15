---
name: execute
description: Executa um PLAN.md wave a wave, com behavior virando teste, done como critério de conclusão, checkpoint com revisão do diff da wave e wave final de revisão independente.
argument-hint: "[caminho do PLAN.md]"
disable-model-invocation: true
allowed-tools: Bash(git status *) Bash(git branch *) Bash(git diff *) Bash(git -C * diff *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh") Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh" *)
---

## Estado atual
!`git status --short 2>/dev/null || echo "(não é repo git)"`
!`git branch --show-current 2>/dev/null || echo "(não é repo git)"`

## Regras que valem a tarefa inteira
- Siga as waves na ordem. Não adiante trabalho de waves futuras.
- Cada linha de `behavior` vira um teste da própria tarefa antes ou junto da implementação. Use `action` e o molde `arquivo:linha` indicado.
- `done` é o critério de `[x]`: só marque quando a assertiva estiver comprovada pelo `verify` (ou por comando/observação objetiva) e registre a evidência. Nunca marque `[x]` sem evidência.
- Comandos vêm de `.claude/kit.json`; não invente comandos do stack. Mudança em `Interfaces` exige registro em Decisões.
- Decisão técnica pequena que surgir (nome, parâmetro, flag, pasta, biblioteca já prevista): decida pelo padrão mais simples coerente com a SPEC e o código, registre em Decisões do PLAN.md (`- <data> · kit · <decisão> — <motivo>`), atualize o doc de referência se houver um, e siga.
- Pare e pergunte só em: decisão de produto (o que o usuário vê, regra de negócio), escopo fora da SPEC, decisão cara de reverter (schema público, contrato de API, dependência nova) ou ação irreversível (deploy, push, chamada a serviço externo real, migração em banco real). Na dúvida entre técnica e produto, conta como produto. A resposta entra em Decisões com `· usuário ·`.
- Após duas tentativas falhas na mesma tarefa, pare, resuma o que tentou e recomende `/clear` com um prompt melhor.
- Plano no formato antigo (sem waves): cada tarefa é uma wave sequencial e a verificação final do plano faz o papel da wave final.

## Passos
1. Plano: $ARGUMENTS. Sem argumento, use o PLAN.md mais recente em `docs/specs/`. Leia o PLAN.md e a SPEC.md ao lado. Retome da primeira caixa `- [ ]`.
2. **Início da wave.** Se a wave ainda não tem linha `Base:`, rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh"` e grave `Base: <hash>` logo abaixo da linha `Paralelo:`. O hash é uma árvore git do estado atual (rastreados e não rastreados); não cria commit nem mexe no index.
   - **Vários repositórios** (pasta-mãe com repositórios filhos, ou `repos` no `kit.json`): o script vale para um repositório por vez. Rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh" <repo>` para cada repositório que a wave toca e grave `Base: <repo>=<hash> <repo>=<hash>`, com `<repo>` relativo à pasta da sessão.
   - **Antes da primeira wave**, grave também a base do plano inteiro, uma vez, logo abaixo do título: `Base do plano: <hash>` (ou `<repo>=<hash> ...`). A wave final compara contra ela.
3. **Paralelo.** Antes de disparar as tarefas da linha `Paralelo:`, compare os `files` delas:
   - Disjuntos: delegue todas ao mesmo tempo, uma por subagent `general-purpose`, numa única mensagem. Cada subagent recebe a SPEC e os `files`, `behavior`, `action`, `verify` e `done` da sua tarefa, implementa, roda o `verify` e devolve o resultado; ele não edita o PLAN.md. Espere todos voltarem antes de qualquer outro passo da wave.
   - Com interseção: execute essas tarefas em sequência, na ordem do plano, e registre em Decisões: `- <data> · kit · Tarefas N e M em sequência — files em comum: <arquivo>`.
   - As demais tarefas da wave rodam em sequência, na ordem do plano.
4. **Cada tarefa** (feita por você ou devolvida por um subagent):
   1. Escreva os testes do `behavior` (use o `kit:test-writer` quando a tarefa for principalmente testes) e implemente seguindo `action`.
   2. Rode o `verify` da tarefa e mostre o resultado.
   3. Confira o `done`. Marque `- [x]` e acrescente abaixo `  - Evidência: <comando> → <resultado resumido>`.
5. **Checkpoint** (caixa `Checkpoint wave N`), só depois que todas as tarefas da wave, inclusive as paralelas, voltaram:
   1. Re-rode os `verify` de todas as tarefas da wave juntos; falha reabre a tarefa (`- [ ]`) e volta ao passo 4.
   2. Confirme que cada `done` da wave continua valendo.
   3. Rode `wave-base.sh` de novo para obter o hash de agora (por repositório, se houver vários) e chame o `kit:code-reviewer` com os caminhos da SPEC e do PLAN, o número da wave e o diff da wave: `git -C <repo> diff <base> <agora>` em cada repositório, ignorando o PLAN.md. Corrija todo BLOCKER e MAJOR, re-rode os `verify` afetados e chame de novo, até não sobrar nenhum. MINOR fica anotado.
   4. Avalie o contexto. Acima de ~70% de uso, marque o checkpoint, pare e recomende `/compact` seguido de `/kit:execute <caminho>`: o PLAN.md guarda o estado e a execução retoma da próxima caixa.
   5. Marque o checkpoint `- [x]` e acrescente abaixo `  - Evidência: <verify da wave> → <resultado>` e `  - Revisão: kit:code-reviewer → <aprovado | N achados corrigidos>`.
6. **Wave final**, passo a passo:
   1. F1: rode `wave-base.sh` de novo (por repositório) e chame o `kit:code-reviewer` com os caminhos da SPEC e do PLAN e o diff inteiro: `git -C <repo> diff <base do plano> <agora>` em cada repositório. Comparar árvores inclui os arquivos novos ainda não rastreados, que um `git diff` simples não mostra. Plano sem `Base do plano:`: use a `Base:` da primeira wave; sem nenhuma base, `git -C <repo> diff HEAD` mais `git -C <repo> ls-files --others --exclude-standard` em cada repositório. Chame também o `kit:security-reviewer` com a lista de todos os arquivos alterados e novos (`git -C <repo> diff --name-only <base do plano> <agora>`).
   2. F2: corrija todo BLOCKER e MAJOR e chame de novo o revisor que apontou, até não sobrar nenhum. MINOR fica anotado.
   3. F3: rode a verificação ponta a ponta da SPEC.
   4. F4 (se existir): rode `smoke` do `kit.json`.
   Marque cada passo com a evidência.
7. Resuma: waves e tarefas concluídas, evidências, decisões novas, achados MINOR pendentes e o que o security-reviewer apontou. Não commite sem pedido explícito.
