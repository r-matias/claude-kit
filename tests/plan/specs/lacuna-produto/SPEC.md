# Bloqueio por tentativas de login

## Objetivo
Dificultar ataques de força bruta bloqueando a conta depois de muitas tentativas de login com senha errada.

## Escopo
- Tentativas com senha errada são contadas por usuário.
- Passado o limite, a conta fica bloqueada e o login é recusado mesmo com a senha certa.
- A conta volta a aceitar login depois de um tempo.

## Fora de escopo
- Desbloqueio manual por administrador.

## Arquivos e interfaces envolvidos
- `src/auth.js` — login

## Casos de borda
- Senha certa antes do limite zera a contagem.

## Verificação ponta a ponta
1. `node --test test/` passa com testes do bloqueio e do desbloqueio.
