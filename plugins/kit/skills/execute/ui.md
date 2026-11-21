# Interface no /kit:execute

Vale quando o `.claude/kit.json` tem `ui.globs` e a tarefa, a wave ou o plano toca arquivo que casa com eles. Sem a chave `ui`, ou com `"ui": false`, nada deste arquivo se aplica.

O script de interface é o `ui.sh` indicado no SKILL.md. Rode-o na raiz do projeto, a pasta que tem `.claude/kit.json` (em outra pasta, passe `--kit <caminho do kit.json>`).

## Ao implementar
- Siga o bloco de [ui-rules.md](ui-rules.md). Subagent que recebe tarefa com arquivo de `ui.globs` recebe esse bloco no prompt, sem mudar uma palavra, junto com o de subagent-rules.md.
- Se o projeto tem `.claude/rules/kit-ui.md`, ele diz onde ficam tema, tokens, componentes compartilhados e a tela que serve de molde.
- Direção registrada: a rule `kit-design` que vale para os arquivos da tarefa (a `.claude/rules/kit-design-<area>.md` cujo `paths:` casa, senão a `.claude/rules/kit-design.md`). Subagent de tarefa com tela recebe também o conteúdo dessa rule, sem o frontmatter, e, quando a SPEC cita um `DESIGN.md`, a lista de Componentes base dele.
- Linha de `behavior` sobre estado de tela (vazio, carregando, erro, sucesso) vira teste quando o projeto testa componente. Sem teste de componente, a evidência do `done` é a captura da tela naquele estado.

## Captura
`ui.sh capture --name <nome> --routes <rota,rota>` sobe o app com `ui.dev` se `ui.url` não responde e o derruba no fim. Abre cada rota num navegador headless e percorre de 320 a 1920px: as larguras padrão, os tamanhos de `ui.viewports` e os pontos de quebra do CSS da própria página. Em cada largura mede rolagem horizontal e alvo de toque; em cada tamanho de `ui.viewports`, também nome acessível, contraste, texto alternativo e erro de console e de requisição. Página com tema escuro tem o contraste medido também no escuro. Grava as imagens e o `report.json` em `.claude/state/ui/<nome>/` e imprime o resumo. Passe `timeout: 600000` na chamada de Bash.

- Rotas: as da seção Telas da SPEC. Sem ela, omita `--routes` e valem as de `ui.routes`.
- `--probe-only`: só a sondagem, sem imagens.
- Cada linha do resumo é `achado [id]` (certo: corrija) ou `conferir [id]` (heurística: quem decide é o revisor). O id é o da regra do `kit:ui-reviewer`.
- `achado` que não vale para o caso (a página rola para o lado de propósito; a requisição que falha é a do estado de erro que a SPEC pede): não mude o código só para calar a medição. Registre o motivo na linha `Interface:` e deixe o `kit:ui-reviewer` decidir.
- Saída 0: sem achado. 1: há `achado`. 2: `ui` do `kit.json` incompleto ou inválido, ou opção errada. 3: sem meio de captura. 4: o app não respondeu; a mensagem traz o fim do log, e a correção é no app ou em `ui.dev` e `ui.url`. 5: captura incompleta.
- Tela com a linha `incompleta:` no resumo não foi sondada por inteiro (tempo esgotado, sondagem ou passo que falhou, erro no meio): ela não está limpa. Rode de novo só com as rotas incompletas. Se repetir, registre a tela e o motivo na linha `Interface:` e ela segue para a revisão pelo código.
- `aviso:` de rota redirecionada (tela atrás de login, por exemplo): o que foi medido é a página de destino. A tela pedida precisa dos passos da seção abaixo.
- App que já roda em `ui.url` é usado como está e continua rodando no fim. A captura só derruba o app que ela mesma subiu.
- Sandbox bloqueando porta local: rode de novo fora do sandbox (o Claude Code pede a confirmação dele).

### Tela atrás de login, clique ou dado digitado
A captura por rota só vê o que abre por URL. Estado que depende de interação (pessoa logada, modal aberto, erro de formulário, segundo passo) é capturado com os passos que levam até ele:

`ui.sh capture --name <estado> --routes <rota> --steps '<JSON>'` (ou `--steps <arquivo.json>`)

A captura refaz os passos depois de cada carga da rota, em cada tamanho, e mede e fotografa o estado em que eles terminam.
- Um objeto por passo: `{"click": "<seletor>"}`, `{"fill": "<seletor>", "value": "<texto>"}`, `{"press": "Enter"}`, `{"hover": "<seletor>"}`, `{"wait": "<seletor>"}` (ou um tempo em milissegundos), `{"goto": "<rota>"}`, `{"js": "<código rodado na página>"}`. O passo espera o elemento aparecer por até 10s; `"timeout": <ms>` muda esse tempo.
- Seletor: CSS, ou `text=<texto visível>` (o texto do botão, do link ou do rótulo do campo). Tire o seletor do código da tela; não adivinhe.
- Login ou dado de teste que vale para a captura inteira: `{"setup": [<passos, uma vez, antes da primeira rota>], "steps": [<passos de cada carga>]}`. O `setup` começa por um `goto`.
- Credencial de desenvolvimento que já está no repositório (seed, README) pode ir no JSON. Segredo não: escreva `${NOME}` em `value` e a captura lê a variável de ambiente `NOME`, que o usuário define; ela só é digitada em página de `ui.url`. Sem credencial conhecida, pergunte ao usuário.
- Passo que falha deixa a tela `incompleta`, com o número do passo e a imagem `<tela>-falha-<tamanho>-1.png` de onde parou: corrija o passo e rode de novo.
- Página já aberta num navegador com porta de depuração (`--remote-debugging-port`), dirigido por outra ferramenta: `ui.sh capture --attach http://127.0.0.1:<porta> --match <trecho da URL> --name <estado>` faz a mesma varredura nela, sem recarregar.
- Estado que os passos não alcançam: fica para a revisão pelo código. Diga qual no resumo final.

### Sem meio de captura (saída 3)
A revisão de interface segue só pelo código e a Evidência registra `sem captura`.

## No checkpoint da wave
Primeiro passo do checkpoint, antes do `verify` e da revisão, se a wave alterou arquivo de `ui.globs`:
1. Rode `ui.sh capture --probe-only --name wave-<N>` nas rotas das telas tocadas. Estado atrás de interação que a wave implementou: uma chamada com `--steps` e o `--name` do estado.
2. Corrija todo `achado` e rode de novo, até a saída 0 ou até sobrar só o que não vale para o caso. Saída 3: siga sem a sondagem. Saída 5 que se repete: siga e diga no checkpoint qual tela ficou incompleta.
3. Correção pedida depois pelo `kit:code-reviewer` em arquivo de `ui.globs`: rode a sondagem de novo.
4. Acrescente ao checkpoint `  - Interface: sondagem em <L> larguras → <sem achado | N achados corrigidos | sem captura | incompleta em <tela>: <motivo>>`.

## Na wave final (F1)
Se o diff do plano tem arquivo de `ui.globs`, antes de tirar o diff e de chamar os revisores da F1:
1. Rode a captura completa, `ui.sh capture --name final`, nas rotas da SPEC. Capture também cada estado da seção Telas que fica atrás de interação, com `--steps` e um `--name` por estado.
2. Corrija todo `achado` e capture de novo.
3. Chame o `kit:ui-reviewer` na mesma mensagem dos outros revisores da F1, com os caminhos da SPEC e do PLAN, a lista dos arquivos de interface alterados e a pasta de cada captura. Sem captura, diga `sem captura`. Quando existem, passe também os caminhos da rule de direção (`.claude/rules/kit-design*.md` que vale para as telas), do `DESIGN.md` e da amostra citados pela SPEC.
4. A F2 vale para ele: corrija BLOCKER e MAJOR, capture de novo e chame de novo, até `aprovado` (no máximo 3 rodadas; se sobrar BLOCKER ou MAJOR, pergunte como no passo 5.4 da [SKILL.md](SKILL.md)).
5. Na Evidência da F1: `  - Interface: <captura de T telas em L larguras | sem captura> · kit:ui-reviewer → <aprovado | N achados corrigidos | N aceitos pelo usuário>`.
