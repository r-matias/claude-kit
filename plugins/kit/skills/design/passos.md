# Passos da /kit:design

A skill que mandou ler este arquivo já disse qual é o argumento e qual é a raiz do plugin, chamada aqui de `<raiz-do-plugin>`. Arquivos do kit usados nos passos:

- `<raiz-do-plugin>/skills/design/visual.md`: bloco de direção visual;
- `<raiz-do-plugin>/skills/execute/ui-rules.md`: bloco de regras de interface;
- `<raiz-do-plugin>/skills/execute/subagent-rules.md`: bloco de leitura e Bash dos subagents;
- `<raiz-do-plugin>/templates/kit-design.rule.md`: molde da rule de direção.

Os três blocos vão no prompt dos subagents sem mudar uma palavra.

## Qual escopo
- Argumento vazio ou `app`: escopo app, os passos abaixo.
- Outro argumento (rota, arquivo ou nome de página ou de componente): esta versão só trata o escopo app. Diga isso em uma linha e pergunte se é para definir a direção do app.

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
4. **Escolha.** Mostre o caminho completo de cada amostra, para abrir no navegador, e uma linha por direção. Avise que a fonte vem de CDN: sem rede aparece a fonte de reserva, e a tipografia mostrada não é a final. `AskUserQuestion` com uma opção por amostra da rodada e a opção "Outra rodada"; a pergunta diz que no campo livre dá para dizer o que mudar, quais duas combinar ou escolher uma amostra de rodada anterior.
   - Outra rodada ou combinação: gere de novo só o que foi pedido, pelo mesmo prompt mais o pedido do usuário, com outro `<n>` no nome do arquivo. Na combinação, o prompt leva também os caminhos das duas amostras e o que vem de cada uma.
   - No máximo 3 rodadas, contando a primeira geração. Depois da terceira, pergunte se segue com a amostra que o usuário apontou como mais próxima (sem essa indicação, pergunte qual) ou se para; parando, nada é gravado fora da pasta de estado.
5. **Gravação**, só depois da escolha. Leia a amostra escolhida: os valores gravados saem do código dela, não da descrição.
   - `.claude/rules/kit-design.md`, a partir de `kit-design.rule.md`: `paths:` com os globs de `ui.globs`, o cabeçalho `<!-- kit:design v1 -->` e os campos Direção, Tipografia, Paleta, Composição, Movimento, Acabamento, O que evitar e Amostra. Em Tipografia, diga de onde as fontes vêm no projeto: no código do projeto elas ficam empacotadas, nunca por CDN; se ainda não estão lá, o campo diz em que pasta a fundação visual vai empacotá-las.
   - `docs/specs/<slug>/amostra.html`: cópia da amostra escolhida, sem alterar o conteúdo. Se o formatador do projeto reformatar o arquivo ao gravar, fica como ele deixou.
   - `docs/specs/<slug>/DESIGN.md`, no formato abaixo. Em Componentes base, liste os componentes do inventário que a direção redesenha, cada um com o arquivo existente a alterar, ou `novo` quando nada existente serve. Essa lista é o que impede cada tarefa de criar o seu próprio botão ou cartão.
   - A amostra versionada é documento de referência, não tela do app. Se uma regra do gate do projeto (`coupled_changes` ou `diff_deny`) casar com ela por um glob largo, como `**/*.html`, não altere a amostra para passar: diga qual regra casou e que o glob dela deve deixar `docs/specs/` de fora.
6. **Resumo**, em poucas linhas: a direção escolhida, os arquivos gravados e que nenhum código do projeto mudou. Depois a linha de custo, `Custo: <N> subagents (<tipo> ×<n>, ...) · <total> mil tokens nos subagents`, com `(+<k> sem usage)` quando faltou `<usage>` em algum, somando só os subagents. Termine com o próximo comando pronto, com o slug de verdade: `/clear` e então `/kit:spec docs/specs/<slug>/DESIGN.md`.

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
