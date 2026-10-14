# Último login no perfil

## Objetivo
Suporte precisa saber quando cada usuário entrou pela última vez.

## Escopo
- Cada login bem-sucedido grava a data e hora do login no registro do usuário.
- `GET /users/:id` passa a devolver o campo `lastLoginAt`, em ISO 8601 UTC, ou `null` se o usuário nunca entrou.

## Fora de escopo
- Histórico de logins.
- Login com falha não altera nada.

## Decisões
- O campo da resposta é `lastLoginAt` — combinado com o time de suporte.

## Arquivos e interfaces envolvidos
- `src/auth.js` — login
- `src/routes.js` — resposta de `GET /users/:id`

## Casos de borda
- Usuário que nunca entrou → `lastLoginAt: null`.
- Login com senha errada → data não muda.

## Verificação ponta a ponta
1. `node --test` passa, com testes cobrindo os dois casos de borda.
