---
paths:
  - "web/**/*.html"
  - "web/**/*.css"
  - "web/**/*.js"
---
<!-- kit:design v1 -->
# Direção visual deste projeto

Gravada pela `/kit:design`, a partir da amostra que o usuário escolheu. Vale junto com as regras de interface do projeto: reuso, tokens, estados, tela pequena e acessibilidade continuam valendo.

- Direção: Boletim — painel de operação lido como um jornal interno: títulos com serifa, texto sóbrio, nada que dispute com a informação
- Tipografia: título `Georgia` (`--familia-titulo`), texto `Verdana` (`--familia-texto`) — fontes do sistema operacional, nada a empacotar; todo título (`h1` a `h3`) usa a família de título
- Paleta: fundo → `--cor-fundo` (#ffffff); texto → `--cor-texto` (#1f2933); texto secundário → `--cor-suave` (#52606d); acento → `--cor-acao` (#0b5cad), só na ação principal e no link ativo; borda → `--cor-borda` (#cbd2d9); erro → `--cor-erro` (#b42318)
- Composição: coluna única até 700px, duas colunas a partir daí; cartões alinhados à esquerda, com o título no topo e a data logo abaixo
- Movimento: nenhum além do foco visível
- Acabamento: borda de 1px, raio `--raio`, sem sombra e sem textura
- O que evitar: título na família do texto; sombra; uma segunda cor de acento
- Amostra: nenhuma versionada; a direção foi registrada antes desta tela
