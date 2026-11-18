# Plano: Tela de avisos
Spec: ./SPEC.md

## must_haves
### truths
- `ordenarAvisos` devolve os avisos do mais novo para o mais antigo, sem alterar a lista recebida.
- `/avisos` mostra os avisos de `web/dados/avisos.json` com título, data em `DD/MM/AAAA` e texto, do mais novo para o mais antigo.
- Aviso sem texto aparece só com título e data.
- `/avisos?dados=vazio` mostra "Nenhum aviso por enquanto." e nenhuma lista.
- `/avisos?dados=erro` mostra "Não foi possível carregar os avisos." e o botão "Tentar de novo", que busca outra vez.
- Enquanto busca, a tela mostra "Carregando avisos…".
- Abaixo de 700px os avisos ficam um por linha; a partir de 700px, em duas colunas; não há rolagem horizontal de 320 a 1920px.
- O menu do painel tem o link "Avisos" e a tela de avisos tem o link "Painel".
- `node --test` passa.
### artifacts
- `web/avisos.js` — `ordenarAvisos`, `formatarData` e a montagem da tela com os quatro estados
- `web/avisos.html` — a tela de avisos
- `web/index.html` — link "Avisos" no menu
### tests
- `test/avisos.test.js` — ordem, lista não alterada, lista vazia, data formatada

## Interfaces
- `export function ordenarAvisos(lista: {titulo, data, texto}[]): {titulo, data, texto}[]` — cópia ordenada pela data, mais novo primeiro; tarefa 1; usada pela tarefa 2
- `export function formatarData(data: string): string` — `AAAA-MM-DD` vira `DD/MM/AAAA`; tarefa 1; usada pela tarefa 2
- `GET /avisos[?dados=vazio|erro]` — a tela; tarefa 2

## Wave 1 — ordenação e data
Paralelo: nenhum

- [ ] 1. Criar `ordenarAvisos` e `formatarData`
  - files: `web/avisos.js`, `test/avisos.test.js`
  - behavior:
    - três avisos fora de ordem → devolvidos do mais novo para o mais antigo
    - lista recebida → continua na ordem original depois da chamada
    - lista vazia → lista vazia
    - `formatarData("2026-03-07")` → `"07/03/2026"`
  - action: módulo ES em `web/avisos.js` com as duas funções exportadas, sem tocar no `document` ao ser importado pelo teste; testes com `node:test` e `node:assert/strict`; molde: `web/painel.js:1` e `test/painel.test.js:1`
  - verify: `test_related` com `test/avisos.test.js`
  - done: `node --test test/avisos.test.js` passa com os quatro casos
- [ ] Checkpoint wave 1: re-rodar os verify da wave, confirmar cada done, revisar o diff da wave, avaliar o contexto

## Wave 2 — a tela
Paralelo: nenhum

- [ ] 2. Criar a tela de avisos com os quatro estados e ligar no menu
  - files: `web/avisos.html`, `web/avisos.js`, `web/index.html`
  - behavior:
    - `/avisos` → lista os avisos com título, data `DD/MM/AAAA` e texto, mais novo primeiro
    - aviso sem texto → só título e data
    - enquanto busca → "Carregando avisos…"
    - `/avisos?dados=vazio` → "Nenhum aviso por enquanto.", sem lista
    - `/avisos?dados=erro` → "Não foi possível carregar os avisos." e o botão "Tentar de novo", que busca outra vez
    - largura abaixo de 700px → um aviso por linha; a partir de 700px → duas colunas
    - menu do painel → link "Avisos"; tela de avisos → link "Painel"
  - action: página no molde de `web/index.html:1` (mesmo cabeçalho `.topo`, `main.conteudo` e `h1`), lista com `ul.cartoes` e `li.cartao` de `web/style.css:10`, botão com a classe `.botao` de `web/style.css:14`; só tokens de `web/tokens.css:1` para cor, espaçamento e fonte; a montagem fica em `web/avisos.js`, executada só no navegador; busca `/dados/avisos.json` com `fetch`, e `?dados=vazio` e `?dados=erro` forçam o estado
  - verify: `test`
  - done: `node --test` passa e a captura de `/avisos`, `/avisos?dados=vazio` e `/avisos?dados=erro` sai sem achado
- [ ] Checkpoint wave 2: re-rodar os verify da wave, confirmar cada done, revisar o diff da wave, avaliar o contexto

## Wave final — revisão e verificação
- [ ] F1. Revisão independente: `kit:code-reviewer` e `kit:security-reviewer` sobre todos os arquivos alterados; e `kit:ui-reviewer` sobre as telas capturadas em todos os tamanhos
- [ ] F2. Corrigir BLOCKER e MAJOR e repetir a revisão até não sobrar nenhum
- [ ] F3. Verificação ponta a ponta da SPEC: `node --test` passa; `/avisos`, `/avisos?dados=vazio` e `/avisos?dados=erro` abrem em 360x800 e em 1920x1080 sem rolagem horizontal, cada uma no estado certo

## Decisões

## Riscos
- Nenhum.
