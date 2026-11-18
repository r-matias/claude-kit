# Tela de avisos

## Objetivo
Quem usa o painel precisa ler os avisos da operação numa tela própria, no computador e no celular.

## Escopo
- A tela `/avisos` lista os avisos de `web/dados/avisos.json` (título, data e texto), do mais novo para o mais antigo.
- O menu do topo do painel ganha o link "Avisos", e a tela de avisos tem o link "Painel".
- A URL aceita `?dados=vazio` e `?dados=erro` para abrir a tela nesses estados sem depender do arquivo de dados.

## Fora de escopo
- Criar, editar ou apagar aviso.
- Marcar aviso como lido.

## Decisões
- Estados abertos por parâmetro de URL — a tela precisa ser conferida em cada estado sem mexer nos dados.
- Data exibida como `DD/MM/AAAA` — é o formato que a operação usa.

## Arquivos e interfaces envolvidos
- `web/avisos.html` — a tela
- `web/avisos.js` — `export function ordenarAvisos(lista)`, que devolve uma cópia ordenada pela data, do mais novo para o mais antigo, e a montagem da lista
- `web/index.html` — link "Avisos" no menu
- `web/dados/avisos.json` — lista de `{ "titulo", "data" (AAAA-MM-DD), "texto" }`

## Telas
- **Avisos** (`/avisos`) — ler os avisos da operação; ação principal: ler a lista; no estado de erro, o botão "Tentar de novo"
  - Fluxo: abre pelo link "Avisos" do menu → lê a lista, mais novo primeiro → volta pelo link "Painel"
  - Estados: vazio → o texto "Nenhum aviso por enquanto."; carregando → o texto "Carregando avisos…"; erro → o texto "Não foi possível carregar os avisos." e o botão "Tentar de novo"; sucesso → a lista de avisos
  - Tela pequena: um aviso por linha, na largura toda, abaixo de 700px; a partir de 700px, duas colunas
- Padrão visual: tokens de `web/tokens.css` (cor, espaçamento, raio, fonte) e os cartões e o menu de `web/index.html` com `web/style.css`

## Casos de borda
- Lista vazia → estado vazio, sem lista.
- Arquivo de dados inacessível → estado de erro; "Tentar de novo" busca outra vez.
- Aviso sem texto → mostra só o título e a data.

## Verificação ponta a ponta
1. `node --test` passa.
2. `/avisos`, `/avisos?dados=vazio` e `/avisos?dados=erro` abrem em 360x800 e em 1920x1080 sem rolagem horizontal, cada uma no estado certo.
