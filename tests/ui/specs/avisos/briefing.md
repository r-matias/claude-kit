Briefing: tela de avisos do painel

O pessoal da operação pediu uma tela para ler os avisos (inventário, mudança de transportadora, sistema fora do ar). Hoje isso vai por mensagem e se perde. Precisa funcionar no computador do escritório e no celular de quem está no galpão.

O que entra:
- Uma tela nova em /avisos que lista os avisos guardados em web/dados/avisos.json. Cada aviso tem título, data (no arquivo vem como AAAA-MM-DD) e texto. O mais novo aparece primeiro.
- A data aparece como DD/MM/AAAA, que é o formato que a operação usa.
- O menu do topo do painel ganha o link "Avisos", e a tela de avisos tem o link "Painel" para voltar.
- Para conferir a tela sem mexer no arquivo de dados, a URL aceita ?dados=vazio e ?dados=erro, que abrem a tela nesses estados.

O que não entra: criar, editar ou apagar aviso, e marcar aviso como lido.

Como a tela se comporta:
- A pessoa abre pelo link "Avisos" do menu, lê a lista e volta pelo link "Painel". A tela é só de leitura; o único botão é o "Tentar de novo", que aparece quando dá erro.
- Enquanto busca os avisos, mostra o texto "Carregando avisos…".
- Se não há aviso nenhum, mostra "Nenhum aviso por enquanto." e nenhuma lista.
- Se o arquivo de dados não pôde ser lido, mostra "Não foi possível carregar os avisos." e o botão "Tentar de novo", que busca outra vez.
- Aviso sem texto mostra só o título e a data.
- No celular, um aviso por linha ocupando a largura toda. A partir de 700px de largura, duas colunas.
- O visual é o do painel: os tokens de web/tokens.css (cor, espaçamento, raio, fonte) e os cartões e o menu que já existem em web/index.html e web/style.css. Nada de cor ou espaçamento novo.

Arquivos: web/avisos.html (a tela), web/avisos.js (a função ordenarAvisos(lista), que devolve uma cópia ordenada do mais novo para o mais antigo, e a montagem da lista), web/index.html (o link no menu) e web/dados/avisos.json (os dados).

Como saber que está pronto: node --test passa, e /avisos, /avisos?dados=vazio e /avisos?dados=erro abrem no celular (360x800) e no monitor (1920x1080) sem rolagem horizontal, cada uma no estado certo.
