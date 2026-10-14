---
name: spec
description: Entrevista você sobre uma feature e grava docs/specs/<slug>/SPEC.md com objetivo, escopo, fora de escopo e verificação ponta a ponta. Use ao começar uma feature, ideia ou mudança que ainda não tem especificação.
argument-hint: "[ideia em uma frase]"
---

## Regras que valem a tarefa inteira
- Não escreva código de produção nesta skill. A saída é só a SPEC.md.
- Leia o CLAUDE.md e explore o código relevante antes de perguntar; não pergunte o que o código responde.
- Perguntas só sobre decisões reais: implementação, UX, casos de borda, trade-offs. Nada óbvio, nada genérico.

## Passos
1. Ideia: $ARGUMENTS. Se vazia, peça a ideia em uma frase.
2. Explore o código afetado (delegue ao `kit:investigator` se a área for grande) para saber o que já existe.
3. Entreviste com `AskUserQuestion`, em rodadas de até 4 perguntas, oferecendo opções concretas e marcando a recomendada. Pare quando escopo, bordas e verificação estiverem claros.
4. Defina o slug (kebab-case, curto) e grave `docs/specs/<slug>/SPEC.md`:

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

## Casos de borda
- <caso> → <comportamento esperado>

## Verificação ponta a ponta
1. <passo executável que prova que a feature funciona, com comando do kit.json ou roteiro manual>
```

5. Mostre o caminho do arquivo e recomende: `/clear` e então `/kit:plan docs/specs/<slug>/SPEC.md`.
