# Utilitários de número e texto

## Objetivo
Funções pequenas usadas pelo resto do projeto.

## Escopo
- `soma(a, b)` devolve a soma de dois números.
- `maiusculas(s)` devolve o texto em maiúsculas.
- `dobro(n)` devolve o dobro de um número, usando `soma`.
- `media(lista)` devolve a média de uma lista de números; lista vazia devolve 0.

## Fora de escopo
- Validação de tipos.

## Arquivos e interfaces envolvidos
- `src/numeros.js` — `soma`, `dobro`, `media`
- `src/texto.js` — `maiusculas`

## Casos de borda
- `media([])` → 0

## Verificação ponta a ponta
1. `node --test` passa.
