# Plano: Apelido de usuário
Spec: ./SPEC.md

## must_haves
### truths
- `node scripts/migrar-apelido.js` deixa todo usuário do arquivo com o campo `apelido` (`""` para quem não tinha).
- Rodar a migração duas vezes não altera usuário que já tem apelido.
- A migração grava `<arquivo>.bak` antes de alterar o arquivo, e `node scripts/migrar-apelido.js --rollback` restaura essa cópia.
- `validarApelido` aceita apelido de 1 e de 30 caracteres.
- `validarApelido` com 31 caracteres ou vazio lança erro com `code: "APELIDO_INVALIDO"`.
- `definirApelido(1, "Aninha")` grava e devolve o usuário 1 com `apelido: "Aninha"`.
- `definirApelido` com id inexistente lança erro com `code: "USUARIO_NAO_ENCONTRADO"`.
- `node --test` passa e, numa cópia de `data/users.json`, a migração seguida de `definirApelido(1, "Aninha")` deixa `apelido: "Aninha"` no usuário 1.
### artifacts
- `scripts/migrar-apelido.js` — migração idempotente com backup e rollback
- `src/apelido.js` — `validarApelido`
- `src/users.js` — `definirApelido`
### tests
- `test/migrar-apelido.test.js` — campo acrescentado, segunda execução sem mudança, backup e rollback
- `test/apelido.test.js` — 1 e 30 caracteres aceitos; 31 caracteres e vazio recusados
- `test/users.test.js` — `definirApelido` grava e devolve, id inexistente, apelido inválido sem gravar, migração seguida de `definirApelido`

## Interfaces
- `export function validarApelido(apelido: string): void` — apelido fora de 1 a 30 caracteres lança `Error` com `code: "APELIDO_INVALIDO"`; tarefa 2; consumida pela tarefa 3
- `export function definirApelido(id: number, apelido: string): object` — devolve o usuário atualizado; id inexistente lança `Error` com `code: "USUARIO_NAO_ENCONTRADO"`; tarefa 3
- `node scripts/migrar-apelido.js [--rollback]` — arquivo em `USERS_FILE` (padrão `data/users.json`); tarefa 1

## Wave 1 — migração e validação
Paralelo: 1, 2

- [ ] 1. Criar a migração do campo `apelido` com backup e rollback
  - files: `scripts/migrar-apelido.js`, `test/migrar-apelido.test.js`
  - behavior:
    - usuário sem `apelido` → ganha `apelido: ""`
    - usuário com `apelido: "Bi"` → continua com `"Bi"`, também numa segunda execução
    - execução normal → `<arquivo>.bak` igual ao arquivo antes da migração
    - `--rollback` → o arquivo volta ao conteúdo do `.bak`
  - action: lê com `lerUsuarios` e grava com `gravarUsuarios` de `src/store.js`; antes de gravar, copia o arquivo de `USERS_FILE` para `<arquivo>.bak`; se a gravação falhar, restaura a cópia; `--rollback` restaura o `.bak`; os testes rodam sobre cópia temporária apontada por `USERS_FILE`; molde: `src/store.js:5`
  - verify: `test_related` com `test/migrar-apelido.test.js`
  - done: `node --test test/migrar-apelido.test.js` passa com os quatro casos
- [ ] 2. Criar `validarApelido`
  - files: `src/apelido.js`, `test/apelido.test.js`
  - behavior:
    - `validarApelido("A")` → não lança
    - apelido com 30 caracteres → não lança
    - apelido com 31 caracteres → lança erro com `code: "APELIDO_INVALIDO"`
    - `validarApelido("")` → lança erro com `code: "APELIDO_INVALIDO"`
  - action: módulo ES com `export function validarApelido`; testes com `node:test` e `node:assert/strict`; molde: `test/users.test.js:1`
  - verify: `test_related` com `test/apelido.test.js`
  - done: `node --test test/apelido.test.js` passa com os quatro casos
- [ ] Checkpoint wave 1: re-rodar os verify da wave, confirmar cada done, revisar o diff da wave, avaliar o contexto

## Wave 2 — gravação do apelido
Paralelo: nenhum

- [ ] 3. Criar `definirApelido`
  - files: `src/users.js`, `test/users.test.js`
  - behavior:
    - `definirApelido(1, "Aninha")` → devolve o usuário 1 com `apelido: "Aninha"` e grava no arquivo
    - `definirApelido(99, "X")` → lança erro com `code: "USUARIO_NAO_ENCONTRADO"`
    - apelido com 31 caracteres → lança `APELIDO_INVALIDO` e o arquivo não muda
    - migração seguida de `definirApelido(1, "Aninha")` → usuário 1 com `apelido: "Aninha"` no arquivo
  - action: chama `validarApelido` (tarefa 2), busca o usuário como em `buscarUsuario` e grava com `gravarUsuarios`; os testes rodam sobre cópia temporária apontada por `USERS_FILE`; molde: `src/users.js:3`
  - verify: `test_related` com `test/users.test.js`
  - done: `node --test test/users.test.js` passa com os quatro casos e com os testes que já existiam
- [ ] Checkpoint wave 2: re-rodar os verify da wave, confirmar cada done, revisar o diff da wave, avaliar o contexto

## Wave final — revisão e verificação
- [ ] F1. Revisão independente: `kit:code-reviewer` e `kit:security-reviewer` sobre todos os arquivos alterados
- [ ] F2. Corrigir BLOCKER e MAJOR e repetir a revisão até não sobrar nenhum
- [ ] F3. Verificação ponta a ponta da SPEC: `node --test` passa; numa cópia de `data/users.json` via `USERS_FILE`, `node scripts/migrar-apelido.js` seguido de `definirApelido(1, "Aninha")` deixa `apelido: "Aninha"` no usuário 1

## Decisões
- 2026-10-01 · kit · backup da migração em `<arquivo>.bak`, ao lado do original — rollback por cópia, sem dependência nova

## Riscos
- Migração corromper `data/users.json` — backup antes de gravar e `--rollback` na tarefa 1
