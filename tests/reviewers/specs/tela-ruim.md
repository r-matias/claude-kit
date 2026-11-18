# Tela de avisos

## Objetivo
Quem usa o painel precisa ler os avisos da operação numa tela própria, no computador e no celular.

## Escopo
- A tela `/avisos` busca os avisos de `web/dados/avisos.json` (título, data e texto) e lista do mais novo para o mais antigo, em duas colunas.
- O menu do topo do painel ganha o link "Avisos", e a tela de avisos tem o link "Painel".

## Fora de escopo
- Criar, editar ou apagar aviso.
- Marcar aviso como lido.

## Decisões
- Data exibida como `DD/MM/AAAA` — é o formato que a operação usa.

## Arquivos e interfaces envolvidos
- `web/avisos.html` — a tela
- `web/avisos.js` — `export function ordenarAvisos(lista)`, que devolve uma cópia ordenada pela data, do mais novo para o mais antigo, e a montagem da lista
- `web/index.html` — link "Avisos" no menu
- `web/dados/avisos.json` — lista de `{ "titulo", "data" (AAAA-MM-DD), "texto" }`

## Telas
- **Avisos** (`/avisos`) — ler os avisos da operação
- Padrão visual: tokens de `web/tokens.css` (cor, espaçamento, raio, fonte) e os cartões e o menu de `web/index.html` com `web/style.css`

## Casos de borda
- Aviso sem texto → mostra só o título e a data.

## Verificação ponta a ponta
1. `node --test` passa.
2. `/avisos` abre em 360x800 e em 1920x1080 e mostra os três avisos do arquivo, o de 12/03/2026 primeiro.
