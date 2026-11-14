# Plano: <título>
Spec: ./SPEC.md
Revisão: <pendente | aprovado (rodada N) | reprovado após 3 rodadas — ids>

## Abordagem
- Escolhida: <abordagem em uma linha> — <motivo>
- Descartada: <abordagem em uma linha> — <por que não>

## Reuso
| # | Necessidade | Existente | Veredito |
|---|---|---|---|
| R1 | <o que a SPEC precisa> | `<caminho:linha>` `<símbolo>` | usar |
| R2 | <...> | `<caminho:linha>` `<símbolo>` | estender: <o que acrescenta> |
| R3 | <...> | buscado: `<termo>`, `<glob>` | nenhum |

## must_haves
### truths
- <frase verificável sobre o resultado, do ponto de vista de quem usa>
### artifacts
- `<caminho>` — <o que provê>
### tests
- `<caminho>` — <o que cobre: truths e casos de borda>

## Interfaces
- `<assinatura, rota, schema ou código de erro exato>` — <tarefa que implementa; quem consome>

## Wave 1 — <tema>
Paralelo: <números das tarefas com arquivos disjuntos, ou "nenhum">

- [ ] 1. <verbo + resultado>
  - files: `<caminho>`, `<caminho>`
  - behavior:
    - <situação ou entrada> → <resultado esperado>
  - action: <como fazer>; molde: `<caminho:linha>`; reuso: usar `<símbolo>` (R1), novo (R3: nenhum)
  - verify: `<chave do kit.json>`
  - done: <assertiva testável>
- [ ] Checkpoint wave 1: re-rodar os verify da wave, confirmar cada done, revisar o diff da wave, avaliar o contexto

## Wave final — revisão e verificação
- [ ] F1. Revisão independente: `kit:code-reviewer` e `kit:security-reviewer` sobre todos os arquivos alterados
- [ ] F2. Corrigir BLOCKER e MAJOR e repetir a revisão até não sobrar nenhum
- [ ] F3. Verificação ponta a ponta da SPEC: <passos>
- [ ] F4. Smoke: `smoke` do kit.json

## Decisões
- <AAAA-MM-DD> · kit · <decisão> — <motivo>
- <AAAA-MM-DD> · usuário · <decisão> — <pergunta que a originou>

## Riscos
- <risco> — <mitigação>
