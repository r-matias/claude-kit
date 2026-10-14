---
name: epic
description: Quebra um épico em fatias que entregam valor sozinhas e grava docs/specs/<epico>/EPIC.md com dependências, critério de pronto e status.
argument-hint: "[descrição do épico]"
disable-model-invocation: true
---

## Regras que valem a tarefa inteira
- Não escreva código nesta skill.
- Cada fatia entrega valor observável sozinha e pode ir para produção isoladamente. Fatia "só backend" ou "só modelo de dados" sem efeito visível não conta, a menos que seja pré-requisito explícito.
- Prefira fatias verticais finas; a primeira fatia é o caminho mais simples ponta a ponta.

## Passos
1. Épico: $ARGUMENTS. Leia o CLAUDE.md e explore a área (delegue ao `kit:investigator` se for grande).
2. Entreviste com `AskUserQuestion` sobre objetivo de negócio, usuários, restrições, prazo e o que é inegociável. Sem perguntas óbvias.
3. Proponha as fatias e confirme com o usuário antes de gravar.
4. Grave `docs/specs/<epico>/EPIC.md`:

```markdown
# Épico: <título>

## Objetivo
<resultado de negócio>

## Fatias
| # | Fatia | Valor entregue | Depende de | Critério de pronto | Status |
|---|---|---|---|---|---|
| 1 | <nome> | <o que o usuário ganha> | — | <condição verificável> | pendente |

## Fora do épico
- ...

## Riscos
- ...
```

5. Para cada fatia, grave `docs/specs/<epico>/<n>-<fatia>/SPEC.md` no formato da skill `/kit:spec` (objetivo, escopo, fora de escopo, decisões, arquivos e interfaces, casos de borda, verificação ponta a ponta).
6. Recomende: cada fatia numa sessão própria (`/rename <epico>-fatia-<n>`), seguindo `/kit:plan` → `/kit:execute`, em worktree se quiser paralelizar. Ao concluir uma fatia, atualize o status no EPIC.md.
