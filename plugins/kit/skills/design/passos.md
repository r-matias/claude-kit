# Passos da /kit:design

A skill que mandou ler este arquivo já disse qual é o argumento e qual é a raiz do plugin, chamada aqui de `<raiz-do-plugin>`. Arquivos do kit usados nos passos:

- `<raiz-do-plugin>/skills/design/visual.md`: bloco de direção visual;
- `<raiz-do-plugin>/skills/execute/ui-rules.md`: bloco de regras de interface;
- `<raiz-do-plugin>/skills/execute/subagent-rules.md`: bloco de leitura e Bash dos subagents;
- `<raiz-do-plugin>/templates/kit-design.rule.md`: molde da rule de direção;
- `<raiz-do-plugin>/scripts/ui.sh`: captura das amostras, na conferência do passo 4.

Os três blocos vão no prompt dos subagents sem mudar uma palavra.

## Qual escopo
- Argumento vazio ou `app`: escopo app.
- Outro argumento (rota, arquivo ou nome): ache o alvo com Grep e Glob nos arquivos de `ui.globs`. Tela própria (rota, página, view): escopo página. Peça de interface usada por outras telas: escopo componente. Nada encontrado e o argumento descreve uma tela: página que ainda não existe. Nada encontrado e o argumento descreve um componente: componente novo não é tratado aqui; diga isso e pergunte se é para redesenhar uma tela que vai usá-lo. Ambíguo (mais de um alvo, ou serve como página e como componente): pergunte com `AskUserQuestion`, uma opção por alvo e escopo.
- Em qualquer escopo, sem `.claude/kit.json`, sem a chave `ui` ou com `"ui": false`: pare e recomende `/kit:init`.
- Fora do escopo app, fonte e paleta não mudam. Pedido que exige mudar uma delas (outra fonte, outra cor de marca, tema novo): diga que isso é escopo app e pergunte se é para subir o escopo. Com o sim, siga o escopo app com a página (ou, num componente, uma das telas que o usam) como tela representativa; se o alvo está numa área com direção própria, o que sobe é a direção da área. Com o não, siga no escopo atual sem mudar fonte nem paleta.
- **Rule que vale para um arquivo:** a `kit-design-<area>.md` com o cabeçalho `kit:design` cujo `paths:` casa com ele; senão, a `kit-design.md` com esse cabeçalho. Nenhuma das duas: o arquivo está sem direção, mesmo que outra área do projeto tenha a sua.

## Escopo app

1. **Leitura.** Leia o `CLAUDE.md`, o `ui` do `.claude/kit.json`, a `.claude/rules/kit-ui.md`, as `.claude/rules/kit-design*.md` que existirem, o arquivo de tokens e uma ou duas telas representativas (a tela de referência da `kit-ui.md`, ou a mais usada).
   - Sem `.claude/kit.json`, sem a chave `ui` ou com `"ui": false`: pare e recomende `/kit:init`.
   - `kit-design.md` com o cabeçalho `kit:design`: o projeto já tem direção. Pergunte se é para substituir (direções novas), ajustar (variações da atual, mantendo o que o usuário disser) ou criar a direção própria de uma área (ver "Área com direção própria").
   - Rule que seria regravada (`kit-design.md` ou `kit-design-<area>.md`) sem esse cabeçalho: o arquivo é do projeto. Não regrave; diga isso e pare.
   - **Componentes base.** Peça ao `kit:investigator` o inventário dos componentes compartilhados, com `arquivo:linha`: os da pasta que a `kit-ui.md` aponta ou, em projeto sem componentes, os trechos de marcação repetidos entre telas (botão, campo, cartão, tabela, navegação).
2. **Briefing.** Uma rodada de `AskUserQuestion`, até 4 perguntas, só sobre o que a leitura não respondeu: quem usa o app e em que situação; o que incomoda no visual de hoje; o que é obrigatório da marca (cor, logo, fonte); tema claro, escuro ou os dois. Se o projeto tem áreas de público diferente (site público e painel logado, por exemplo), e a área ainda não foi escolhida no passo 1, uma das perguntas é se a direção vale para o app inteiro ou só para uma área (ver "Área com direção própria"); nesse caso, marca e tema vão na mesma pergunta.
3. **Direções e amostras.** Defina o slug da pasta (kebab-case, curto; se `docs/specs/<slug>/` já existe com outro assunto, escolha outro). Proponha 3 direções, uma linha cada, diferentes no tom e não só na cor; em ajuste, 3 variações da direção atual, mudando só o que o usuário apontou. Gere uma amostra por direção, cada uma por um subagent `general-purpose`, todas na mesma mensagem. O prompt de cada subagent leva:
   - o briefing (respostas do passo 2 e o que é obrigatório da marca) e a direção dele, com nome e a linha que a descreve;
   - o bloco de `visual.md`, o de `ui-rules.md` e o de `subagent-rules.md`, sem mudar uma palavra, e a linha: na amostra, a aparência vem da direção, não das telas atuais; a regra de reuso e os tokens do projeto não se aplicam a ela, e do bloco de interface valem estados, tela pequena, acessibilidade e valores em variáveis CSS do próprio arquivo;
   - a estrutura da tela representativa: seções, tipos de conteúdo, ação principal e navegação. Todas as amostras mostram a mesma tela, para a comparação ser de direção e não de conteúdo;
   - o caminho de saída, `.claude/state/ui/design/<slug>/<n>-<nome>.html`, e a ordem de gravar só esse arquivo;
   - o formato: um HTML autocontido, com o CSS no próprio arquivo, sem build e sem script externo; funciona em 360 e em 1280px de largura; só dado fictício; fonte de licença aberta carregada por CDN, com fonte de reserva declarada, de modo que a página continue legível sem rede (fonte que a marca obriga é a exceção);
   - a resposta esperada: o caminho gravado, as duas famílias de fonte, a paleta por papel e uma linha sobre a composição.

   Subagent que volta sem ter gravado o arquivo: peça uma vez que refaça. Se falhar de novo, siga com as amostras que existem e diga qual faltou.
4. **Escolha.** Antes de mostrar, a conferência: na raiz do projeto, rode `bash "<raiz-do-plugin>/scripts/ui.sh" capture --serve .claude/state/ui/design/<slug> --routes <arquivos da rodada, separados por vírgula> --name design-<slug>`, com `timeout: 600000` na chamada de Bash. A captura serve a pasta só durante a rodada e grava imagens nos tamanhos de `ui.viewports`. Abra com Read as imagens do menor e do maior tamanho de cada amostra.
   - Amostra com `achado [B2]` ou `achado [B3]`, página em branco ou que não mostra a tela pedida: refaça essa amostra uma vez, pelo mesmo prompt mais o problema visto, e capture de novo. Se o problema continuar, mostre-a dizendo qual é. Os outros achados não refazem a amostra.
   - `aviso: recurso externo não carregou`: sem rede, a imagem mostra a fonte de reserva.
   - `conferir [M10]` compara a amostra com a direção já gravada no projeto: vale no escopo página e componente e no ajuste; em direções novas, ignore.
   - Captura que sai com 3 (sem node ou sem navegador), com 4 (porta local barrada, em geral pelo sandbox do Bash) ou que o usuário não autoriza: siga sem ela e diga que as amostras não foram vistas renderizadas. Saída 5: use as imagens que saíram e diga qual amostra ficou incompleta.

   Mostre o caminho completo de cada amostra, para abrir no navegador, e uma linha por direção, sobre o que as imagens mostram. Avise que a fonte vem de CDN: sem rede aparece a fonte de reserva, e a tipografia mostrada não é a final. `AskUserQuestion` com uma opção por amostra da rodada e a opção "Outra rodada"; a pergunta diz que no campo livre dá para dizer o que mudar, quais duas combinar ou escolher uma amostra de rodada anterior.
   - Outra rodada ou combinação: gere de novo só o que foi pedido, pelo mesmo prompt mais o pedido do usuário, com outro `<n>` no nome do arquivo. Na combinação, o prompt leva também os caminhos das duas amostras e o que vem de cada uma.
   - No máximo 3 rodadas, contando a primeira geração. Depois da terceira, pergunte se segue com a amostra que o usuário apontou como mais próxima (sem essa indicação, pergunte qual) ou se para; parando, nada é gravado fora da pasta de estado.
5. **Gravação**, só depois da escolha. Leia a amostra escolhida: os valores gravados saem do código dela, não da descrição.
   - `.claude/rules/kit-design.md`, a partir de `kit-design.rule.md`: `paths:` com os globs de `ui.globs`, o cabeçalho `<!-- kit:design v1 -->` e os campos Direção, Tipografia, Paleta, Composição, Movimento, Acabamento, O que evitar e Amostra. Em Tipografia, diga de onde as fontes vêm no projeto: no código do projeto elas ficam empacotadas, nunca por CDN; se ainda não estão lá, o campo diz em que pasta a fundação visual vai empacotá-las.
   - `docs/specs/<slug>/amostra.html`: cópia da amostra escolhida, sem alterar o conteúdo. Se o formatador do projeto reformatar o arquivo ao gravar, fica como ele deixou.
   - `docs/specs/<slug>/DESIGN.md`, no formato abaixo. Em Componentes base, liste os componentes do inventário que a direção redesenha, cada um com o arquivo existente a alterar, ou `novo` quando nada existente serve. Essa lista é o que impede cada tarefa de criar o seu próprio botão ou cartão.
   - A amostra versionada é documento de referência, não tela do app. Se uma regra do gate do projeto (`coupled_changes` ou `diff_deny`) casar com ela por um glob largo, como `**/*.html`, não altere a amostra para passar: diga qual regra casou e que o glob dela deve deixar `docs/specs/` de fora.
6. **Resumo**, em poucas linhas: a direção escolhida, os arquivos gravados e que nenhum código do projeto mudou. Depois a linha de custo, `Custo: <N> subagents (<tipo> ×<n>, ...) · <total> mil tokens nos subagents`, com `(+<k> sem usage)` quando faltou `<usage>` em algum, somando só os subagents. Termine com o próximo comando pronto, com o slug de verdade: `/clear` e então `/kit:spec docs/specs/<slug>/DESIGN.md`.

## Escopo página
Redesenho de uma tela dentro da direção que o projeto já tem. Fora do piloto (abaixo), nenhuma rule de direção muda. Os passos são os do escopo app, com estas diferenças:

1. **Leitura.** O arquivo da tela e os componentes que ela usa, os tokens, a `kit-ui.md` e a rule que vale para o arquivo (ver "Qual escopo"). Sem inventário do `kit:investigator`: os componentes são os que a tela importa.
   - **Projeto sem direção** (nenhuma rule de direção vale para o arquivo da página): antes do briefing, uma pergunta com `AskUserQuestion`. Piloto da direção do app (recomendado quando o visual de hoje é o que incomoda): siga o escopo app com esta página como tela representativa; a `kit-design.md` vale para o projeto todo, e o `DESIGN.md` registra em Escopo `app — piloto em <rota>`, em Telas afetadas só esta página e em Fora do redesenho as outras telas, que migram depois. Só recomposição: siga esta seção com o padrão atual (tokens e telas existentes) no lugar da direção.
   - **Página que ainda não existe:** as composições partem da descrição do argumento e da tela mais parecida do projeto, para navegação e cabeçalho.
2. **Briefing.** Até 3 perguntas: o que incomoda nesta tela (ou, se é nova, o que ela precisa resolver), qual é a tarefa principal de quem a usa e o que não pode mudar.
3. **Amostras.** 2 ou 3 composições da mesma página, cada uma por um subagent `general-purpose`, todas na mesma mensagem, com o prompt do escopo app e estas trocas:
   - no lugar da direção nova, o texto da rule de direção (ou, sem direção, o padrão atual) e os valores dos tokens e das fontes do projeto, copiados para variáveis CSS dentro do HTML;
   - a linha-ponte passa a ser: fonte, paleta e acabamento são os do projeto, copiados acima; o que muda entre as amostras é composição, hierarquia, agrupamento e posição da ação principal;
   - no formato, a família de fonte é a do projeto: por CDN só se tiver licença aberta; senão, declarada pelo nome com a fonte de reserva do projeto, sem trocar por outra;
   - a estrutura é a da própria página: seções, conteúdo, ações e estados que ela tem hoje (ou os da descrição, se é nova).
4. **Escolha.** Como no escopo app; o aviso de fonte por CDN só vale quando alguma amostra carrega fonte por CDN.
5. **Gravação.** Como no escopo app (slug, cópia da amostra e regra do gate sobre ela), mas só `docs/specs/<slug>/amostra.html` e `docs/specs/<slug>/DESIGN.md`; nenhuma `kit-design*.md` é gravada. No `DESIGN.md`: Escopo `página — <rota ou arquivo>`, com `(nova)` quando a tela não existe; Direção escolhida com a composição escolhida e a rule que ela segue, ou `Rule: nenhuma (padrão atual do projeto)` na recomposição; Componentes base com os componentes da tela que mudam; Telas afetadas com esta página.
6. **Resumo.** Como no escopo app, dizendo também que a direção do projeto não mudou.

## Escopo componente
Redesenho de uma peça usada por várias telas, dentro da direção que o projeto já tem (ou do padrão atual, sem direção). A `kit-design.md` não muda. Os passos são os do escopo página, com estas diferenças:

1. **Leitura.** Além dos tokens e da `kit-ui.md`: o arquivo do componente, as variantes e os estados que ele aceita (propriedades, classes, modificadores) e dois ou três usos reais. Peça ao `kit:investigator` as telas que usam o componente, cada uma com o arquivo e a rota. A rule que vale é a das telas que o usam (ver "Qual escopo"); se elas caem em rules diferentes (duas áreas com direção própria, ou parte com rule e parte sem), pergunte qual direção o componente segue. Nenhuma vale: o padrão atual, sem a pergunta do piloto.
2. **Briefing.** Até 3 perguntas: o que incomoda no componente, que estado ou variante falta e o que não pode mudar na interface dele (propriedades, eventos, nomes usados pelas telas).
3. **Amostras.** 2 ou 3 versões do componente, pelo prompt do escopo página, com a estrutura sendo o componente e a linha-ponte: fonte, paleta e acabamento são os do projeto; o que muda entre as amostras é forma, densidade e tratamento dos estados. Cada amostra mostra o componente em todos os estados e variantes (padrão, hover, foco, desabilitado, carregando, erro, vazio, os que se aplicam) e um trecho de uma tela real que o usa, para ver o componente no contexto.
4. **Escolha.** Como no escopo página.
5. **Gravação.** Como no escopo página. No `DESIGN.md`: Escopo `componente — <arquivo>`; Componentes base com o componente e o arquivo; Telas afetadas com todas as telas do inventário, com a rota de cada uma. A SPEC e a captura precisam dessas rotas.
6. **Resumo.** Como no escopo página, com o número de telas afetadas.

## Área com direção própria
Quando o usuário quer uma direção só para uma área (a landing page diferente do painel), os passos são os mesmos, com as telas e os globs daquela área:
- a rule é `.claude/rules/kit-design-<area>.md`, com `paths:` só dos arquivos da área e, logo abaixo da linha de abertura, `Substitui a direção geral (kit-design.md) nestes arquivos.`;
- a `kit-design.md` geral não muda. Num arquivo que casa as duas, as duas rules carregam juntas e a linha acima resolve qual vale;
- o `DESIGN.md` registra a área em Escopo e, na linha `Rule:`, aponta a rule da área.

## Formato do DESIGN.md

```markdown
# Design: <título>

## Escopo
<app | página | componente> — <o alvo: o app inteiro, a área, a rota ou o arquivo>

## Problema de hoje
- <o que incomoda no visual atual, com a tela ou o arquivo onde aparece>

## Decisões
- <data de hoje> · usuário · <o que muda> — <motivo>
- Não muda: <o que fica como está>

## Direção escolhida
<nome> — <uma frase>. Rule: `.claude/rules/kit-design.md`
- Tipografia: <título e texto>
- Paleta: <papel → valor>
- Composição, movimento e acabamento: <uma linha cada>
- Descartadas: <nome> — <por que não>

## Amostra
`docs/specs/<slug>/amostra.html` — <a tela que ela mostra>. É molde de aparência: o estilo dela vai para tokens e componentes do projeto. A fonte por CDN existe só aqui.

## Componentes base
- <componente> — `<arquivo existente a alterar>`, ou `novo` — <o que muda nele>

## Telas afetadas
- <tela> (`<rota ou arquivo>`)

## Fora do redesenho
- <o que não entra>
```
