# Painel administrativo de usuários

## Objetivo
O time de suporte precisa de 20 operações administrativas sobre `data/users.json`, hoje feitas à mão no arquivo.

## Escopo
- `contarUsuarios()` devolve o total de usuários.
- `listarEmails()` devolve os e-mails em ordem alfabética.
- `buscarPorEmail(email)` devolve o usuário ou `null`, sem diferenciar maiúsculas.
- `renomearUsuario(id, nome)` troca o `name`; nome vazio lança `NOME_INVALIDO`.
- `trocarEmail(id, email)` troca o `email`; e-mail sem `@` lança `EMAIL_INVALIDO`; e-mail já usado lança `EMAIL_EM_USO`.
- `removerUsuario(id)` remove o usuário; id inexistente lança `USUARIO_NAO_ENCONTRADO`.
- `criarUsuario(email, nome, senha)` acrescenta com o próximo id e `passwordHash` de `hashPassword`.
- `redefinirSenha(id, senha)` troca o `passwordHash`; senha com menos de 8 caracteres lança `SENHA_FRACA`.
- `exportarCsv()` devolve `id,email,name` com cabeçalho, uma linha por usuário.
- `importarCsv(texto)` acrescenta os usuários do CSV `email,name`, sem senha (`passwordHash: null`).
- `dominiosDeEmail()` devolve `{ dominio: quantidade }`.
- `usuariosSemSenha()` devolve os usuários com `passwordHash: null`.
- `desativarUsuario(id)` grava `active: false`; `login` recusa usuário desativado com "conta desativada".
- `reativarUsuario(id)` grava `active: true`.
- `listarDesativados()` devolve os usuários com `active: false`.
- `anonimizarUsuario(id)` troca `email` por `anon-<id>@anon.test` e `name` por `Anônimo`.
- `duplicadosPorNome()` devolve os nomes que aparecem mais de uma vez.
- `validarArquivo()` devolve a lista de problemas (id repetido, e-mail repetido, campo obrigatório ausente).
- `backupUsuarios()` copia `data/users.json` para `data/users.<AAAA-MM-DD>.json` e devolve o caminho.
- `restaurarBackup(caminho)` substitui `data/users.json` pela cópia, depois de passar em `validarArquivo`.

## Fora de escopo
- Interface web ou CLI para as operações.

## Decisões
- Cada operação fica no seu módulo, `src/admin/<operacao>.js`, com teste próprio em `test/admin/<operacao>.test.js` — o suporte quer poder revisar e liberar uma por vez.
- Mensagens e códigos de erro como estão no Escopo — combinado com o suporte.
- Operações que gravam fazem backup antes, com `backupUsuarios()` — combinado com o suporte.

## Arquivos e interfaces envolvidos
- `src/admin/*.js` — uma operação por arquivo, exportada com o nome do Escopo
- `src/store.js` — `loadUsers`/`saveUsers`
- `src/auth.js` — `login` e `hashPassword`
- `docs/data-model.md` — campo novo `active`

## Casos de borda
- Arquivo vazio (`[]`) → `contarUsuarios()` devolve 0 e `exportarCsv()` devolve só o cabeçalho.
- `criarUsuario` com e-mail já usado → lança `EMAIL_EM_USO`.
- `restaurarBackup` com arquivo inválido → lança `BACKUP_INVALIDO` e não altera `data/users.json`.

## Verificação ponta a ponta
1. `node --test` passa com um teste por operação e pelos casos de borda.
