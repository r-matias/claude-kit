# Apelido de usuário

## Objetivo
Cada usuário pode ter um apelido, exibido no lugar do nome.

## Escopo
- `validarApelido(apelido)` aceita texto de 1 a 30 caracteres.
- `definirApelido(id, apelido)` valida e grava o apelido do usuário em `data/users.json`.
- Novo módulo `src/arquivo-usuarios.js` com `lerArquivoUsuarios()`, que lê e faz o parse de `data/users.json`, usado por `definirApelido`.
- Cache em memória da lista de usuários em `src/arquivo-usuarios.js`, para `definirApelido` não ler o arquivo a cada chamada.

## Fora de escopo
- Tela de edição do apelido.
- Gravar o apelido em `data/users.json`: nesta entrega o apelido só é validado.

## Arquivos e interfaces envolvidos
- `src/apelido.js` — `export function validarApelido(apelido: string): void`; apelido fora de 1 a 30 caracteres lança `Error` com `code: "APELIDO_INVALIDO"`
- `src/arquivo-usuarios.js` — novo; `export function lerArquivoUsuarios(): object[]`, com cache em memória
- `src/users.js` — `export function definirApelido(id: number, apelido: string): object`; devolve o usuário atualizado; id inexistente lança `Error` com `code: "USUARIO_NAO_ENCONTRADO"`

## Casos de borda
- Apelido com 31 caracteres → erro `APELIDO_INVALIDO`
- Apelido vazio → erro `APELIDO_INVALIDO`
- Id inexistente em `definirApelido` → erro `USUARIO_NAO_ENCONTRADO`

## Verificação ponta a ponta
1. `node --test` passa.
2. Numa cópia de `data/users.json` (via `USERS_FILE`), `definirApelido(1, "Aninha")` deixa `apelido: "Aninha"` no usuário 1.
