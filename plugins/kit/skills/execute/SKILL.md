---
name: execute
description: Executa um PLAN.md wave a wave, com behavior virando teste, done como critério de conclusão, checkpoint com revisão do diff da wave e wave final de revisão independente. Em plano com tela, captura a interface em todos os tamanhos e passa pelo revisor de interface.
argument-hint: "[caminho do PLAN.md]"
disable-model-invocation: true
allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**) Bash(git status *) Bash(git branch *) Bash(git diff *) Bash(git -C * diff *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh") Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh" *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui.sh" *)
---

## Estado atual
!`git status --short 2>/dev/null || echo "(não é repo git)"`
!`git branch --show-current 2>/dev/null || echo "(não é repo git)"`

## Regras que valem a tarefa inteira
- Siga as waves na ordem. Não adiante trabalho de waves futuras.
- Cada linha de `behavior` vira um teste da própria tarefa antes ou junto da implementação. Use `action` e o molde `arquivo:linha` indicado.
- `done` é o critério de `[x]`: só marque quando a assertiva estiver comprovada pelo `verify` (ou por comando/observação objetiva) e registre a evidência. Nunca marque `[x]` sem evidência.
- Comandos vêm de `.claude/kit.json`; não invente comandos do stack. O valor de uma chave é o comando ou um objeto `{ "run", "files" }`, cujo comando é o `run` (com `{files}`, passe os arquivos da tarefa que casam `files`). Mudança em `Interfaces` exige registro em Decisões.
- Decisão técnica pequena que surgir (nome, parâmetro, flag, pasta, biblioteca já prevista): decida pelo padrão mais simples coerente com a SPEC e o código, registre em Decisões do PLAN.md (`- <data> · kit · <decisão> — <motivo>`), atualize o doc de referência se houver um, e siga.
- Pare e pergunte só em: decisão de produto (o que o usuário vê, regra de negócio), escopo fora da SPEC, decisão cara de reverter (schema público, contrato de API, dependência nova) ou ação irreversível (deploy, push, chamada a serviço externo real, migração em banco real). Na dúvida entre técnica e produto, conta como produto. A resposta entra em Decisões com `· usuário ·`.
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`). Ou o valor está configurado e o comando funciona como está, ou pergunte o valor antes (`AskUserQuestion`) e grave no lugar certo: o que não é segredo (user-agent, host, porta) na config versionada do projeto, carregada pelo próprio script; segredo em `.env`/`.env.test` carregado pelo script (`--env-file-if-exists`, `loadEnv`), nunca lido por você, com a mensagem de falta dizendo qual arquivo e qual chave criar.
- **Skill que só o usuário chama** (`disable-model-invocation: true`, como `/kit:map`) citada num passo do plano: não a chame nem a refaça por conta própria. Conclua o resto do passo, marque `[x]` só se esse resto estiver comprovado e acrescente abaixo da evidência `  - Pendente do usuário: <comando>`. Nunca registre essa parte como feita.
- **Interface.** Se o `.claude/kit.json` tem `ui.globs`, leia [ui.md](ui.md) (`${CLAUDE_SKILL_DIR}/ui.md`) antes da primeira tarefa com arquivo que casa com eles: regras de tela, captura em todos os tamanhos e revisão pelo `kit:ui-reviewer`. Script de interface: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui.sh"`, rodado na raiz do projeto (a pasta que tem `.claude/kit.json`). Sem a chave `ui`, ou com `"ui": false`, nada de interface se aplica.
- Após duas tentativas falhas na mesma tarefa, pare, resuma o que tentou e recomende `/clear` com um prompt melhor.
- Plano no formato antigo (sem waves): cada tarefa é uma wave sequencial e a verificação final do plano faz o papel da wave final.
- **Custo.** A cada subagent que volta, anote o tipo dele e o `subagent_tokens` do bloco `<usage>` da notificação de fim (sem `<usage>`, conte o subagent e marque os tokens como desconhecidos). Conte também as rodadas de cada revisor: toda chamada a um revisor é uma rodada, e o total dele soma checkpoints e wave final.

## Passos
1. Plano: $ARGUMENTS. Sem argumento, use o PLAN.md mais recente em `docs/specs/`. Leia o PLAN.md e a SPEC.md ao lado. Retome da primeira caixa `- [ ]`.
2. **Início da wave.** Se a wave ainda não tem linha `Base:`, rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh"` e grave `Base: <hash>` logo abaixo da linha `Paralelo:`. O hash é uma árvore git do estado atual (rastreados e não rastreados); não cria commit nem mexe no index.
   - **Vários repositórios** (pasta-mãe com repositórios filhos, ou `repos` no `kit.json`): o script vale para um repositório por vez. Rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/wave-base.sh" <repo>` para cada repositório que a wave toca e grave `Base: <repo>=<hash> <repo>=<hash>`, com `<repo>` relativo à pasta da sessão.
   - **Antes da primeira wave**, grave também a base do plano inteiro, uma vez, logo abaixo do título: `Base do plano: <hash>` (ou `<repo>=<hash> ...`). A wave final compara contra ela.
3. **Paralelo.** Antes de disparar as tarefas da linha `Paralelo:`, compare os `files` delas:
   - Disjuntos: delegue todas ao mesmo tempo, uma por subagent `general-purpose`, numa única mensagem. Cada subagent recebe a SPEC e os `files`, `behavior`, `action`, `verify` e `done` da sua tarefa, implementa, roda o `verify` e devolve o resultado; ele não edita o PLAN.md. O prompt de cada subagent inclui, sem mudar uma palavra, o bloco de [subagent-rules.md](subagent-rules.md) (`${CLAUDE_SKILL_DIR}/subagent-rules.md`); se a tarefa tem arquivo de `ui.globs`, inclui também, sem mudar uma palavra, o bloco de [ui-rules.md](ui-rules.md) (`${CLAUDE_SKILL_DIR}/ui-rules.md`). Espere todos voltarem antes de qualquer outro passo da wave.
   - Com interseção: execute essas tarefas em sequência, na ordem do plano, e registre em Decisões: `- <data> · kit · Tarefas N e M em sequência — files em comum: <arquivo>`.
   - As demais tarefas da wave rodam em sequência, na ordem do plano.
4. **Cada tarefa** (feita por você ou devolvida por um subagent):
   1. Escreva os testes do `behavior` (use o `kit:test-writer` quando a tarefa for principalmente testes) e implemente seguindo `action`.
   2. Rode o `verify` da tarefa e mostre o resultado.
   3. Confira o `done`. Marque `- [x]` e acrescente abaixo `  - Evidência: <comando> → <resultado resumido>`.
5. **Checkpoint** (caixa `Checkpoint wave N`), só depois que todas as tarefas da wave, inclusive as paralelas, voltaram:
   1. Interface: se a wave alterou arquivo de `ui.globs`, rode a sondagem do checkpoint descrita em [ui.md](ui.md) e corrija todo `achado`. Vem antes dos passos abaixo para que o `verify` e a revisão vejam o código já corrigido.
   2. Re-rode os `verify` de todas as tarefas da wave juntos; falha reabre a tarefa (`- [ ]`) e volta ao passo 4.
   3. Confirme que cada `done` da wave continua valendo.
   4. Plano com uma wave só fora a final, e com a caixa F1 da wave final: pule este passo, sem chamar o `kit:code-reviewer`; a F1 revisa o mesmo diff. Nos demais casos, inclusive plano no formato antigo: rode `wave-base.sh` de novo para obter o hash de agora (por repositório, se houver vários) e chame o `kit:code-reviewer` com os caminhos da SPEC e do PLAN, o número da wave e o diff da wave: `git -C <repo> diff <base> <agora>` em cada repositório, ignorando o PLAN.md. Corrija todo BLOCKER e MAJOR, re-rode os `verify` afetados (e a sondagem do passo 1, se a correção tocou arquivo de `ui.globs`) e chame de novo, no máximo 3 rodadas. MINOR fica anotado.
      Sobrou BLOCKER ou MAJOR depois da terceira rodada: pare e pergunte com `AskUserQuestion`, citando cada achado com o id. Opções: **Continuar corrigindo (Recomendado)**, mais até 3 rodadas; **Aceitar e seguir**, registrando cada achado aceito em Decisões (`- <data> · usuário · Aceito <id> sem correção — <achado>`); **Parar a execução**, sem marcar o checkpoint. Sem `AskUserQuestion` disponível, faça a pergunta no texto com as três opções e pare. Nunca siga para a próxima wave nem para a F3 com BLOCKER ou MAJOR aberto sem essa resposta.
   5. Avalie o contexto. Acima de ~70% de uso, marque o checkpoint, pare e recomende `/compact` seguido de `/kit:execute <caminho>`: o PLAN.md guarda o estado e a execução retoma da próxima caixa.
   6. Marque o checkpoint `- [x]` e acrescente abaixo `  - Evidência: <verify da wave> → <resultado>` e `  - Revisão: kit:code-reviewer → <aprovado | N achados corrigidos | N aceitos pelo usuário>`, ou `  - Revisão: na wave final` quando o passo 4 foi pulado (e a linha `  - Interface: ...` do passo 1, se ele rodou).
6. **Wave final**, passo a passo:
   1. F1: em plano com tela (arquivo de `ui.globs` alterado desde a base do plano), comece pela captura completa de [ui.md](ui.md) e corrija todo `achado` dela; só depois tire o diff, para os revisores verem essas correções. Rode `wave-base.sh` de novo (por repositório) e chame o `kit:code-reviewer` com os caminhos da SPEC e do PLAN e o diff inteiro: `git -C <repo> diff <base do plano> <agora>` em cada repositório. Comparar árvores inclui os arquivos novos ainda não rastreados, que um `git diff` simples não mostra. Plano sem `Base do plano:`: use a `Base:` da primeira wave; sem nenhuma base, `git -C <repo> diff HEAD` mais `git -C <repo> ls-files --others --exclude-standard` em cada repositório. Chame também o `kit:security-reviewer` com a lista de todos os arquivos alterados e novos (`git -C <repo> diff --name-only <base do plano> <agora>`). Se essa lista tem arquivo de `ui.globs`, chame na mesma mensagem o `kit:ui-reviewer` com a pasta de cada captura, como em [ui.md](ui.md).
   2. F2: corrija todo BLOCKER e MAJOR e chame de novo o revisor que apontou, no máximo 3 rodadas por revisor; sobrou BLOCKER ou MAJOR, pergunte como no passo 5.4. Correção em arquivo de `ui.globs`: capture de novo antes de chamar o `kit:ui-reviewer`. MINOR fica anotado.
   3. F3: rode a verificação ponta a ponta da SPEC.
   4. F4 (se existir): rode `smoke` do `kit.json`.
   Marque cada passo com a evidência.
7. Resuma: waves e tarefas concluídas, evidências, decisões novas, achados MINOR pendentes, cada `Pendente do usuário` do plano com o comando (uma linha por comando, sem repetir), o que o security-reviewer apontou e, em plano com tela, o resultado da captura e do `kit:ui-reviewer` (com as telas que ficaram sem captura). Termine com a linha de custo: `Custo: <N> subagents (<tipo> ×<n>, ...) · revisão: <revisor> <n> rodadas, ... · <total> mil tokens nos subagents`, com `(+<k> sem usage)` quando faltou `<usage>` em algum. O total soma só os subagents, não a conversa principal. Se o PLAN.md já tinha caixa `[x]` quando você começou, ou se houve `/compact` no meio, some só o que foi anotado desde então e acrescente `(desde a retomada)`. Não commite sem pedido explícito.
