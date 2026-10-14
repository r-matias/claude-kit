---
name: plan
description: Transforma uma SPEC.md em PLAN.md com tarefas pequenas, cada uma com arquivos, critério verificável e comando de verificação. Use depois de /kit:spec ou quando houver uma spec pronta para planejar.
argument-hint: "[caminho da SPEC.md]"
---

## Regras que valem a tarefa inteira
- Não escreva código de produção nesta skill. A saída é só o PLAN.md.
- Cada tarefa cabe num diff revisável (ordem de grandeza: até ~5 arquivos, uma ideia).
- Todo critério é verificável por comando ou observação objetiva. "Funciona" não é critério.
- Comandos de verificação vêm de `.claude/kit.json` (`build`, `test`, `test_related`, `lint`, `typecheck`). Chave ausente: use as que existem e anote a lacuna.

## Passos
1. Leia a spec: $ARGUMENTS. Sem argumento, use a SPEC.md mais recente em `docs/specs/`.
2. Delegue ao `kit:investigator` o mapeamento do código afetado: pontos de entrada, padrões a seguir, testes existentes, riscos.
3. Ordene por dependência; testes entram junto da tarefa que os exige, não numa tarefa final.
4. Grave `PLAN.md` ao lado da SPEC.md:

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

## Riscos e perguntas abertas
- ...
```

5. Mostre o plano e diga que ele pode ser editado (`Ctrl+G`) antes de rodar `/kit:execute`.
