# Plano: Utilitários de número e texto
Spec: ./SPEC.md

## must_haves
### truths
- `soma(2, 3)` devolve 5.
- `maiusculas("abc")` devolve "ABC".
- `dobro(4)` devolve 8.
- `media([1, 2, 3])` devolve 2 e `media([])` devolve 0.
### artifacts
- `src/numeros.js` — `soma`, `dobro`, `media`
- `src/texto.js` — `maiusculas`
### tests
- `test/numeros.test.js` — soma, dobro, media e lista vazia
- `test/texto.test.js` — maiusculas

## Interfaces
- `export function soma(a: number, b: number): number` — tarefa 1
- `export function maiusculas(s: string): string` — tarefa 2
- `export function dobro(n: number): number` — tarefa 3, usa `soma`
- `export function media(lista: number[]): number` — tarefa 4, 0 para lista vazia

## Wave 1 — funções base
Paralelo: 1, 2

- [ ] 1. Criar `soma`
  - files: `src/numeros.js`, `test/numeros.test.js`
  - behavior:
    - `soma(2, 3)` → 5
    - `soma(-1, 1)` → 0
  - action: módulo ES com `export function soma`; testes com `node:test` e `node:assert/strict`
  - verify: `test_related` com `test/numeros.test.js`
  - done: `node --test test/numeros.test.js` passa com os dois casos
- [ ] 2. Criar `maiusculas`
  - files: `src/texto.js`, `test/texto.test.js`
  - behavior:
    - `maiusculas("abc")` → "ABC"
    - `maiusculas("")` → ""
  - action: módulo ES com `export function maiusculas`; testes com `node:test` e `node:assert/strict`
  - verify: `test_related` com `test/texto.test.js`
  - done: `node --test test/texto.test.js` passa com os dois casos
- [ ] Checkpoint wave 1: re-rodar os verify da wave, confirmar cada done, revisar o diff da wave, avaliar o contexto

## Wave 2 — funções derivadas
Paralelo: 3, 4

- [ ] 3. Criar `dobro` usando `soma`
  - files: `src/numeros.js`, `test/numeros.test.js`
  - behavior:
    - `dobro(4)` → 8
  - action: em `src/numeros.js`, `dobro(n)` chama `soma(n, n)`
  - verify: `test_related` com `test/numeros.test.js`
  - done: `node --test test/numeros.test.js` passa com o caso de `dobro`
- [ ] 4. Criar `media`
  - files: `src/numeros.js`, `test/numeros.test.js`
  - behavior:
    - `media([1, 2, 3])` → 2
    - `media([])` → 0
  - action: em `src/numeros.js`, soma os itens e divide pelo tamanho; lista vazia devolve 0
  - verify: `test_related` com `test/numeros.test.js`
  - done: `node --test test/numeros.test.js` passa com os dois casos de `media`
- [ ] Checkpoint wave 2: re-rodar os verify da wave, confirmar cada done, revisar o diff da wave, avaliar o contexto

## Wave final — revisão e verificação
- [ ] F1. Revisão independente: `kit:code-reviewer` e `kit:security-reviewer` sobre todos os arquivos alterados
- [ ] F2. Corrigir BLOCKER e MAJOR e repetir a revisão até não sobrar nenhum
- [ ] F3. Verificação ponta a ponta da SPEC: `node --test` passa

## Decisões

## Riscos
- Nenhum.
