---
name: spec
description: Entrevista você sobre uma feature e grava docs/specs/<slug>/SPEC.md com objetivo, escopo, fora de escopo e verificação ponta a ponta. Use ao começar uma feature, ideia ou mudança que ainda não tem especificação.
argument-hint: "[ideia em uma frase]"
allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**)
---

## Regras que valem a tarefa inteira
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`): ou o valor está configurado e o comando funciona como está, ou pergunte o valor antes (`AskUserQuestion`) e grave no lugar certo (o que não é segredo na config versionada do projeto, carregada pelo script; segredo em `.env`/`.env.test` carregado pelo script, nunca lido por você).
- Não escreva código de produção nesta skill. A saída é só a SPEC.md.
- Leia o CLAUDE.md e explore o código relevante antes de perguntar; não pergunte o que o código responde.
- Perguntas só sobre decisões reais: implementação, UX, casos de borda, trade-offs. Nada óbvio, nada genérico.

## Passos
1. Ideia: $ARGUMENTS. Se vazia, peça a ideia em uma frase.
2. Explore o código afetado (delegue ao `kit:investigator` se a área for grande) para saber o que já existe. Monte o inventário de reuso das necessidades da ideia, descritas pelo que fazem (o investigator devolve a tabela quando pedido; sem ele, use o mesmo método). O que ele marca `usar` ou `estender` entra na SPEC como linha `Reuso:` e não vira pergunta nem item a construir.
3. Entreviste com `AskUserQuestion`, em rodadas de até 4 perguntas, oferecendo opções concretas e marcando a recomendada. Pare quando escopo, bordas e verificação estiverem claros.
4. **Tamanho**, antes de gravar. Conte os itens de Escopo, os arquivos e áreas afetados (peça a contagem ao `kit:investigator`, com a lista) e os repositórios tocados. Limites: `spec.max_scope_items` (padrão 8) e `spec.max_files` (padrão 25) do `.claude/kit.json`, e no máximo 2 repositórios. Se passar de qualquer um, não grave uma SPEC única: faça uma pergunta, uma vez só, com `AskUserQuestion` (decisão de escopo é do usuário), citando os números e o limite:
   - **Quebrar em fatias agora (Recomendado):** a descrição diz que esta sessão grava `EPIC.md` e uma SPEC por fatia, sem precisar rodar outro comando, e lista as fatias já sugeridas (nome e itens de Escopo de cada uma), seguindo as regras de fatia do `/kit:epic`.
   - **Manter numa spec só:** grava a SPEC.md inteira, com a linha `- <data de hoje> · usuário · tamanho: manter numa spec só (<N> itens de Escopo, ~<M> arquivos, <R> repositórios) — acima do limite` em Decisões.
   - **Reduzir escopo:** descreva o corte proposto (o que fica, normalmente a primeira fatia, e o que vai para Fora de escopo); grava a SPEC.md reduzida.

   Na quebra, leia `${CLAUDE_PLUGIN_ROOT}/skills/epic/SKILL.md` e siga os passos 4 a 6 dele com o slug como épico e as fatias propostas, sem nova entrevista e sem nova confirmação: grave `docs/specs/<slug>/EPIC.md` e uma `SPEC.md` por fatia, cada uma dentro dos limites, e não grave `docs/specs/<slug>/SPEC.md`. Sem `AskUserQuestion` disponível, faça a pergunta no texto com as três opções e pare sem gravar nada.
5. Defina o slug (kebab-case, curto) e grave `docs/specs/<slug>/SPEC.md`:

```markdown
# <Título>
Revisão: pendente

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
- Reuso: `caminho` `símbolo` — <necessidade que cobre, como está ou estendido com o quê>
- <contratos: endpoints, eventos, schemas, assinaturas>

## Casos de borda
- <caso> → <comportamento esperado>

## Verificação ponta a ponta
1. <passo executável que prova que a feature funciona, com comando do kit.json ou roteiro manual>
```

6. **Revisão.** Chame o `kit:spec-reviewer` com o caminho da SPEC.md (na quebra, o passo 5 do `/kit:epic` já revisa cada fatia). Cada achado vem com o id da regra e a severidade fixa dele. Corrija na SPEC.md todo BLOCKER e MAJOR. Se a correção é decisão de produto ou de escopo (o revisor marca `(decisão de produto)`), junte essas numa rodada de `AskUserQuestion` antes de corrigir e registre a resposta em Decisões. Chame de novo até a última linha ser `aprovado` (no máximo 3 rodadas; se sobrar BLOCKER, diga qual, com o id). No fim, troque `Revisão: pendente` por `Revisão: aprovado (rodada N)` ou `Revisão: reprovado após 3 rodadas — <ids>`; enquanto espera resposta do usuário, ela fica `pendente`.
7. Mostre o caminho do arquivo, o resultado da revisão e recomende: `/clear` e então `/kit:plan docs/specs/<slug>/SPEC.md`. Na quebra, mostre o `EPIC.md` e recomende o `/kit:plan` da SPEC da fatia 1.
