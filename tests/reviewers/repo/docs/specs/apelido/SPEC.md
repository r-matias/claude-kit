# Apelido de usuário

## Objetivo
Cada usuário pode ter um apelido, exibido no lugar do nome.

## Escopo
- Migração `scripts/migrar-apelido.js` acrescenta `apelido: ""` a todo usuário de `data/users.json` que ainda não tem o campo.
- `validarApelido(apelido)` aceita texto de 1 a 30 caracteres.
- `definirApelido(id, apelido)` valida e grava o apelido do usuário.

## Fora de escopo
- Tela de edição do apelido.

## Arquivos e interfaces envolvidos
- `scripts/migrar-apelido.js` — migração idempotente de `data/users.json` (caminho em `USERS_FILE`, como em `src/store.js`)
- `src/apelido.js` — `export function validarApelido(apelido: string): void`; apelido fora de 1 a 30 caracteres lança `Error` com `code: "APELIDO_INVALIDO"`
- `src/users.js` — `export function definirApelido(id: number, apelido: string): object`; devolve o usuário atualizado; id inexistente lança `Error` com `code: "USUARIO_NAO_ENCONTRADO"`

## Casos de borda
- Apelido com 31 caracteres → erro `APELIDO_INVALIDO`
- Apelido vazio → erro `APELIDO_INVALIDO`
- Id inexistente em `definirApelido` → erro `USUARIO_NAO_ENCONTRADO`
- Migração rodada duas vezes → usuário que já tem apelido não muda

## Verificação ponta a ponta
1. `node --test` passa.
2. Numa cópia de `data/users.json` (via `USERS_FILE`), `node scripts/migrar-apelido.js` seguido de `definirApelido(1, "Aninha")` deixa `apelido: "Aninha"` no usuário 1.
