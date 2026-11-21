---
name: spec
description: Entrevista você sobre uma feature e grava docs/specs/<slug>/SPEC.md com objetivo, escopo, fora de escopo e verificação ponta a ponta. Use ao começar uma feature, ideia ou mudança que ainda não tem especificação.
argument-hint: "[ideia em uma frase]"
allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui.sh" *)
---

## Regras que valem a tarefa inteira
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`): ou o valor está configurado e o comando funciona como está, ou pergunte o valor antes (`AskUserQuestion`) e grave no lugar certo (o que não é segredo na config versionada do projeto, carregada pelo script; segredo em `.env`/`.env.test` carregado pelo script, nunca lido por você).
- Não escreva código de produção nesta skill. A saída é a SPEC.md; em redesenho visual, também as amostras em `.claude/state/ui/design/`, o `DESIGN.md` e a amostra escolhida em `docs/specs/<slug>/` e, quando a direção do app nasce aqui, a rule de direção em `.claude/rules/`.
- Leia o CLAUDE.md e explore o código relevante antes de perguntar; não pergunte o que o código responde.
- Perguntas só sobre decisões reais: implementação, UX, casos de borda, trade-offs. Nada óbvio, nada genérico.
- **Feature com tela.** A feature tem tela quando a pessoa vê ou opera o resultado numa interface, ou quando os arquivos afetados casam `ui.globs` do `.claude/kit.json`. Nesse caso a entrevista fecha, para cada tela: a ação principal, o que aparece em vazio, carregando, erro e sucesso, e o que muda na tela pequena. Cor, fonte e espaçamento não viram pergunta quando há direção gravada para os arquivos da feature (a rule de direção que vale para eles, conforme "Qual escopo" em `${CLAUDE_PLUGIN_ROOT}/skills/design/passos.md`) ou padrão visual (tema ou tokens na linha "Tema e tokens" da `.claude/rules/kit-ui.md`, biblioteca de componentes): a SPEC manda segui-lo e cita o caminho. Projeto com padrão e sem direção gravada segue o padrão: o kit não decide que ele é ruim, quem abre um redesenho é o usuário. Projeto sem padrão e sem direção: uma pergunta com `AskUserQuestion`, registrada em Decisões. **Definir a direção agora (Recomendado):** siga o **Redesenho visual** abaixo no escopo app, com a tela da feature como tela representativa (ou a descrição dela, se ainda não existe), e continue até a SPEC desta feature. **Seguir sem direção:** a SPEC segue as regras de interface do kit, e `Padrão visual:` diz `sem direção (ver Decisões)`.
- **Redesenho visual.** Pedido que muda a aparência do app, de uma tela ou de um componente que já existe (redesenhar, novo visual, identidade visual). Com o caminho de um `DESIGN.md` no argumento, veja o passo 1. Sem ele, leia `${CLAUDE_PLUGIN_ROOT}/skills/design/passos.md` e siga os passos na mesma sessão, sem rodar outro comando. Para esses passos, `<raiz-do-plugin>` é `${CLAUDE_PLUGIN_ROOT}` e o argumento é o alvo tirado do pedido (`app`, a rota, o arquivo ou o nome); valem também as regras da seção "Regras que valem a tarefa inteira" de `${CLAUDE_PLUGIN_ROOT}/skills/design/SKILL.md`, menos a que proíbe gravar SPEC e as linhas de argumento e de raiz do plugin, que são as daqui.
  - Página ou componente (inclusive o piloto da direção numa página e o alvo que subiu para o escopo app porque o pedido muda fonte ou paleta): no lugar do passo 6 (Resumo) dos passos, volte para cá e siga do passo 1 com o `DESIGN.md` gravado, como se ele viesse no argumento.
  - Direção definida para uma feature com tela: no lugar do passo 6 dos passos, volte para a entrevista da feature de onde ela parou. A SPEC vai na pasta do `DESIGN.md`, e `Padrão visual:` aponta a rule gravada, o `DESIGN.md` e a amostra.
  - Redesenho do app todo pedido pelo usuário: faça o passo 6 dos passos e pare. Não grave SPEC nesta sessão: o que vem depois é a `/kit:spec` do `DESIGN.md`, que vira épico se passar dos limites do passo 4.
  - Passos que param antes da gravação (sem `ui` no `kit.json`, rule de direção do projeto sem o cabeçalho, ou parada depois da 3ª rodada): na feature com tela, siga como **Seguir sem direção** e registre o motivo em Decisões; no pedido de redesenho, pare sem gravar SPEC e diga por quê.

## Passos
1. Ideia: $ARGUMENTS. Se vazia, peça a ideia em uma frase. Se é o caminho de um `DESIGN.md`, a ideia vem dele (Escopo, Problema de hoje, Decisões, Telas afetadas), o slug é o da pasta dele, e o que ele já responde (direção, amostra, componentes base, telas afetadas, fora do redesenho) não vira pergunta: a entrevista fica com fluxo, estados e tela pequena de cada tela afetada, bordas e verificação. Pedido de redesenho visual sem `DESIGN.md`: siga a regra **Redesenho visual** antes do passo 2.
2. Explore o código afetado (delegue ao `kit:investigator` se a área for grande) para saber o que já existe.
3. Entreviste com `AskUserQuestion`, em rodadas de até 4 perguntas, oferecendo opções concretas e marcando a recomendada. Pare quando escopo, bordas e verificação estiverem claros.
4. **Tamanho**, antes de gravar. Conte os itens de Escopo, os arquivos e áreas afetados (peça a contagem ao `kit:investigator`, com a lista) e os repositórios tocados. Limites: `spec.max_scope_items` (padrão 8) e `spec.max_files` (padrão 25) do `.claude/kit.json`, e no máximo 2 repositórios. Se passar de qualquer um, não grave uma SPEC única: faça uma pergunta, uma vez só, com `AskUserQuestion` (decisão de escopo é do usuário), citando os números e o limite:
   - **Quebrar em fatias agora (Recomendado):** a descrição diz que esta sessão grava `EPIC.md` e uma SPEC por fatia, sem precisar rodar outro comando, e lista as fatias já sugeridas (nome e itens de Escopo de cada uma), seguindo as regras de fatia do `/kit:epic`.
   - **Manter numa spec só:** grava a SPEC.md inteira, com a linha `- <data de hoje> · usuário · tamanho: manter numa spec só (<N> itens de Escopo, ~<M> arquivos, <R> repositórios) — acima do limite` em Decisões.
   - **Reduzir escopo:** descreva o corte proposto (o que fica, normalmente a primeira fatia, e o que vai para Fora de escopo); grava a SPEC.md reduzida.

   Na quebra, leia `${CLAUDE_PLUGIN_ROOT}/skills/epic/SKILL.md` e siga os passos 4 a 6 dele com o slug como épico e as fatias propostas, sem nova entrevista e sem nova confirmação: grave `docs/specs/<slug>/EPIC.md` e uma `SPEC.md` por fatia, cada uma dentro dos limites, e não grave `docs/specs/<slug>/SPEC.md`. Sem `AskUserQuestion` disponível, faça a pergunta no texto com as três opções e pare sem gravar nada.
5. Defina o slug (kebab-case, curto; vindo de um `DESIGN.md`, o da pasta dele) e grave `docs/specs/<slug>/SPEC.md`:

```markdown
# <Título>

## Objetivo
<problema e resultado esperado, para quem>

## Escopo
- <comportamento que entra>

## Fora de escopo
- <o que explicitamente não entra>

## Decisões
- <decisão> — <motivo / alternativa descartada>

## Arquivos e interfaces envolvidos
- `caminho` — <o que muda>
- <contratos: endpoints, eventos, schemas, assinaturas>

## Telas
- **<tela>** (`<rota, ou como se chega nela>`) — <para que serve>; ação principal: <uma só>
  - Fluxo: <passos da pessoa até o resultado>
  - Estados: vazio → <o que aparece>; carregando → <...>; erro → <...>; sucesso → <...>
  - Tela pequena: <o que empilha, some ou vira menu, e abaixo de que largura>
- Padrão visual: <a rule de direção que vale para as telas, `.claude/rules/kit-design*.md`, quando existe; tema, tokens, componentes e tela existente a seguir, com caminho; em redesenho, também `docs/specs/<slug>/DESIGN.md` e `docs/specs/<slug>/amostra.html` como molde de aparência>

## Casos de borda
- <caso> → <comportamento esperado>

## Verificação ponta a ponta
1. <passo executável que prova que a feature funciona, com comando do kit.json ou roteiro manual>
```

   A seção `## Telas` só existe em feature com tela; sem tela, tire a seção inteira. Em redesenho, cada tela afetada diz o que muda nela, e o estado que não muda é citado como "sem mudança". Com tela, a Verificação ponta a ponta inclui abrir cada tela no menor e no maior tamanho de `ui.viewports` do `kit.json` (padrão `360x800` e `1920x1080`).

6. **Revisão.** Chame o `kit:spec-reviewer` com o caminho da SPEC.md (na quebra, o passo 5 do `/kit:epic` já revisa cada fatia). Cada achado vem com o id da regra e a severidade fixa dele. Corrija na SPEC.md todo BLOCKER e MAJOR. Se a correção é decisão de produto ou de escopo (o revisor marca `(decisão de produto)`), junte essas numa rodada de `AskUserQuestion` antes de corrigir e registre a resposta em Decisões. Chame de novo até a última linha ser `aprovado` (no máximo 3 rodadas; se sobrar BLOCKER, diga qual, com o id).
7. Mostre o caminho do arquivo, o resultado da revisão e recomende: `/clear` e então `/kit:plan docs/specs/<slug>/SPEC.md`. Na quebra, mostre o `EPIC.md` e recomende o `/kit:plan` da SPEC da fatia 1. Quando a sessão gerou amostras, mostre também o `DESIGN.md` e a amostra gravados e a linha de custo do passo 6 dos passos da `/kit:design`.
