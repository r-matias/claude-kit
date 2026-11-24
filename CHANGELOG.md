# Changelog

O que mudou em cada versão, do ponto de vista de quem usa o kit. Depois de atualizar, rode `/kit:init` de novo em cada projeto (modo reparo) para ele propor o que a versão trouxe para o `kit.json`.

Versões anteriores à 0.9.3 estão nas tags do repositório.

## 0.10.10

### Mudou

- **`/kit:plan` altera documentos só com Write e Edit.** PLAN.md, SPEC.md, DESIGN.md e docs não são mais editados por script no shell. No Windows, um `python -` com heredoc vazio ficava preso até o limite de tempo.

### Corrigido

- **Guarda de shell não nega mais comando em variável por causa de opção como `-Filter`.** `powershell -Command "... $p=Get-CimInstance ... -Filter ..."` era negado como `rm -rf`, porque o `r` do nome da opção contava como recursivo. `-rf`, `-r`, `-Recurse` e `--recursive` continuam negados.

## 0.10.9

### Mudou

- **O gate espera os subagents.** Com subagent da sessão em execução, o `verify-gate` não roda a cada fim de turno; roda no primeiro Stop sem nenhum, sobre tudo o que mudou desde o pedido, inclusive commits feitos no meio. Antes, cada volta de subagent disparava typecheck, testes e lint sobre uma árvore ainda em edição, disputando memória com a compilação dos outros. Shell em segundo plano (servidor de desenvolvimento) não adia. A notificação de concluído também espera e conta o tempo desde o pedido.
- **Subagent do `/kit:execute` roda só o `verify` da própria tarefa**, sem acrescentar suíte inteira, build, lint nem typecheck do projeto: o checkpoint da wave e o gate cobrem isso.
- **Hook de cada prompt mais leve.** O `session-context.sh --plan-only` cria menos da metade dos processos, que é o que encarece com a máquina ocupada.
- **Limite dos guardas e do `session-context` por prompt: 30 s** (era 10 s). Com a máquina sobrecarregada, o guarda estourava o tempo e bloqueava a chamada.

## 0.10.8

### Entrou

- **`ui.sh capture --serve <pasta>`.** Captura os `.html` de uma pasta local, servida em `127.0.0.1` só para leitura e só enquanto a captura roda, sem `ui.url` nem `ui.dev`. Mesma varredura de tamanhos, larguras, sondagem e imagens. `--routes` escolhe os arquivos; o que fica fora da pasta não é servido. Fonte de CDN que não carrega (sem rede) vira aviso, não `M9`.

### Mudou

- **`/kit:design` olha as amostras antes de mostrar.** Cada rodada é capturada com `--serve`; a sessão abre as imagens no menor e no maior tamanho e refaz uma vez a amostra com layout quebrado, controle sem nome, página em branco ou tela errada. Sem node ou navegador, segue como antes e avisa que as amostras não foram vistas renderizadas. A `/kit:design` e a `/kit:spec` passam a ter o `ui.sh` liberado, para a captura não pedir confirmação.
- **`kit:ui-reviewer` vê a amostra escolhida.** Na wave final, o `/kit:execute` captura a `amostra.html` citada pela SPEC e passa a pasta ao revisor, que compara as imagens dela com as da tela no `M11`. Os achados da captura da amostra não se corrigem: ela é referência.

## 0.10.7

### Entrou

- **Teste ao vivo da direção visual** (`tests/run-design-live-test.sh`, para quem mantém o kit). Roda `/kit:design app` e `/kit:spec redesenhar o painel` num projeto com tela e confere que as amostras saem em paralelo, em HTML autocontido, e que nenhum arquivo do projeto muda. Quando a gravação acontece, confere também a rule de direção com cabeçalho e `paths:`, o `DESIGN.md` com a amostra ao lado e a SPEC apontando a amostra. Em `claude -p`, porém, a escrita em `.claude/` é sempre negada: rule, `DESIGN.md` e SPEC saem como puladas, e as amostras são conferidas pelo conteúdo que os subagents tentaram gravar. Nesse cenário, as duas skills param sem gravar nada e dizem por quê. Na sessão interativa, o Claude Code pede aprovação para cada amostra e para a rule.

## 0.10.6

### Entrou

- **Estilo medido na captura.** Cada tela do `report.json` traz o bloco `style`, medido no maior tamanho sobre o texto visível: a família que o navegador de fato usou (a primeira da pilha que existe, não a declarada), as famílias declaradas antes dela que não carregaram, as cores de texto e de fundo mais usadas e os tamanhos de fonte, cada um com a parte do texto.
- **`conferir [M10] fonte-fora-da-direcao`.** Em projeto com rule de direção (`kit-design*.md` com o cabeçalho `kit:design`), tela em que todo o texto saiu em fonte genérica ou de sistema, nenhuma da linha `Tipografia:` da rule, aparece no resumo da captura. O detalhe diz quando a família da direção foi declarada e não carregou.

### Mudou

- **`kit:ui-reviewer` usa o bloco `style` como evidência do `M10`** para fonte e cor, em vez de só olhar a imagem.

## 0.10.5

### Entrou

- **Linha `direção:` no `ui.sh status`.** Em projeto com `ui.globs`, mostra o estado de `.claude/rules/kit-design.md`: `ok`, `ausente`, `do projeto` (sem o cabeçalho `kit:design`) ou `paths fora de sincronia` com o glob que falta ou sobra frente a `ui.globs`. Rules de área aparecem no fim da linha, cada uma com `ok` ou `do projeto`.

### Mudou

- **`/kit:init` e a direção visual.** O init nunca cria, regrava nem apaga a rule de direção, em nenhum modo: só a `/kit:design` grava. Em projeto com tela e sem direção, o relatório termina em `Pronto. Próximo: /kit:design, depois /kit:spec <ideia>`. No modo reparo, `paths:` da rule fora de sincronia com `ui.globs` vira aviso e o mesmo próximo passo.
- **Adoção com `kit-design.md` do projeto.** Arquivo com esse nome e sem o cabeçalho `kit:design` é rule do projeto: fica intocado e é registrado em `docs/claude-adoption.md`.
- **`ui.globs` proposto pelo init deixa a amostra de fora.** Glob que casaria `docs/specs/**/amostra.html`, como `**/*.html`, é trocado por um glob pela pasta das telas.

## 0.10.4

### Entrou

- **`kit:ui-reviewer` cobra a direção visual.** Com `.claude/rules/kit-design.md` no projeto, tela com família de fonte, cor ou composição fora da rule sai com `MAJOR [M10]`, e redesenho que não chega à estrutura da amostra escolhida (hierarquia, agrupamento, ação principal, tela pequena) sai com `MAJOR [M11]`. A direção é cobrada como contrato; se ela é boa, o revisor não julga. Sem rule de direção, os dois ids não se aplicam.

### Mudou

- **`M3` do `kit:ui-reviewer` em redesenho.** Também é `M3` o componente novo criado ao lado do antigo que ele substitui, com o antigo ainda em uso, e o estilo da amostra colado dentro de uma tela em vez de ir para token ou componente.
- **Desvio da direção é `M10`, não `M4`.** Com direção registrada, o desvio dela sai como `M10`; o `M4` (tela que destoa das outras) continua para o que a rule não define. Rule `kit-design*.md` sem o cabeçalho `kit:design` é do projeto e não conta como direção.

Ainda não ligado nesta versão: o `/kit:init` e o `ui.sh status` ainda não conhecem a rule de direção. O revisor lê o código da amostra; não a vê renderizada.

## 0.10.3

### Entrou

- **`/kit:plan` com direção visual.** Em projeto com `.claude/rules/kit-design.md`, toda tarefa de tela cita a rule de direção, a amostra (quando a SPEC a cita) e os componentes que consome. Direção ainda não aplicada vira a primeira tarefa da wave 1: tokens, fontes empacotadas no projeto, estilos base e a linha "Tema e tokens" da `kit-ui.md`. Componente usado por mais de uma tarefa nasce numa wave anterior, e não em duas tarefas paralelas que criariam cada uma o seu.
- **`kit:plan-reviewer` cobra a direção no `M9`.** Tarefa de tela sem a rule de direção, plano sem a fundação visual quando ela falta e o mesmo componente criado por duas tarefas saem como MAJOR.
- **`/kit:execute` passa a direção adiante.** O subagent de tarefa com tela recebe a rule de direção e a lista de componentes base do `DESIGN.md`; o `kit:ui-reviewer` recebe os caminhos da rule, do `DESIGN.md` e da amostra.

### Mudou

- **Regras de interface.** Projeto sem tema tira os tokens da direção registrada, e não mais de uma receita genérica; as fontes e a escala vêm da direção; o movimento admite o momento orquestrado que a direção prevê; em redesenho, o componente existente é alterado em vez de ganhar um irmão ao lado.
- **`.claude/rules/kit-ui.md` na versão 2**, com uma linha que aponta a rule de direção. O `ui.sh status` mostra a rule antiga como `desatualizada`; rode `/kit:init` (modo reparo) para atualizá-la.

Ainda não ligado nesta versão: o `kit:ui-reviewer` recebe os caminhos da direção, mas ainda não a cobra; o `/kit:init` e o `ui.sh status` ainda não conhecem a rule de direção.

## 0.10.2

### Entrou

- **Redesenho pela `/kit:spec`.** Pedido como `/kit:spec redesenhar a tela de faturas` segue os passos da `/kit:design` na mesma sessão: amostras, escolha, `DESIGN.md` e então a SPEC. No app todo, ela grava a direção e para com `/kit:spec docs/specs/<slug>/DESIGN.md` pronto, porque o que vem depois é um épico.
- **`/kit:spec` a partir de um `DESIGN.md`.** Com o caminho no argumento, a ideia vem dele, a SPEC vai na mesma pasta e o que ele já responde (direção, amostra, componentes base, telas afetadas) não vira pergunta.
- **Épico de redesenho do app.** A fatia 1 traz a fundação (tokens, fontes e todos os componentes base do `DESIGN.md`) com a tela de referência; as seguintes são grupos de telas, cada SPEC listando os componentes base que consome.
- **`kit:spec-reviewer` com o `M12`.** Redesenho sem `DESIGN.md` ou sem a amostra em `Padrão visual:`, e feature com tela em projeto sem padrão nem direção sem a escolha registrada em Decisões, saem como MAJOR.

### Mudou

- **Feature com tela em projeto sem padrão visual nem direção.** A pergunta de 2 ou 3 estilos por nome deu lugar a uma só: definir a direção agora, com amostras (recomendado), ou seguir sem. Projeto que já tem padrão segue o padrão, como antes.
- Em redesenho, a seção Telas diz o que muda em cada tela e cita como "sem mudança" o estado que fica igual; `Padrão visual:` aponta a rule de direção, o `DESIGN.md` e a amostra.
- Projeto criado do zero pelo `/kit:init`: a direção visual nasce depois, pela `/kit:design`, e a amostra escolhida serve de tela de referência até existir uma.

Ainda não ligado nesta versão: o `/kit:plan`, o `/kit:execute` e o `kit:ui-reviewer` ainda não consomem nem cobram a direção; o `/kit:init` e o `ui.sh status` ainda não conhecem a rule de direção.

## 0.10.1

### Entrou

- **`/kit:design` para uma página ou um componente.** Passe a rota, o arquivo ou o nome (`/kit:design /faturas`, `/kit:design Button`) e a skill redesenha só aquele alvo, dentro da direção que o projeto já tem: 2 ou 3 amostras com as fontes e a paleta atuais, variando composição e hierarquia. Fora do piloto (abaixo), a rule de direção não muda; ela grava `docs/specs/<slug>/DESIGN.md` e a amostra escolhida. Página que ainda não existe parte da descrição. No componente, a amostra mostra todos os estados e variantes, e o `DESIGN.md` lista as telas que o usam, com a rota. Pedido que exige mudar fonte ou paleta é escopo app, e a skill pergunta se sobe o escopo.
- Página num projeto ainda sem direção: a skill pergunta se ela é o piloto da direção do app (grava a direção para todos, aplicada só nessa tela agora) ou só uma recomposição com o padrão atual.

Ainda não ligado nesta versão: a `/kit:spec` ainda não lê o `DESIGN.md` como ponto de partida nem abre o redesenho sozinha; o `/kit:plan`, o `/kit:execute` e o `kit:ui-reviewer` ainda não consomem nem cobram a direção; o `/kit:init` e o `ui.sh status` ainda não conhecem a rule de direção.

## 0.10.0

### Entrou

- **`/kit:design`: direção visual com amostra antes da escolha.** Em projeto com tela, a skill lê o projeto, pergunta quem usa, o que incomoda hoje e o que é obrigatório da marca, e gera 3 amostras em HTML da mesma tela, uma por direção, em `.claude/state/ui/design/<slug>/`. Você abre no navegador e escolhe uma, pede outra rodada ou combina duas (até 3 rodadas). Com a escolha, ela grava `.claude/rules/kit-design.md` (fontes, paleta, composição, movimento, acabamento e o que evitar), que o Claude recebe sempre que mexe em arquivo de interface, `docs/specs/<slug>/DESIGN.md` (problema de hoje, decisões, componentes base a redesenhar, telas afetadas) e `docs/specs/<slug>/amostra.html`. Não muda código do projeto: tokens, fontes e telas entram depois, por SPEC e plano. Uma área de público diferente pode ter direção própria em `.claude/rules/kit-design-<area>.md`.
- A amostra carrega a fonte por CDN, com fonte de reserva; sem rede, a tipografia mostrada não é a final. No código do projeto a fonte fica empacotada.

Ainda não ligado nesta versão: a skill só trata o app inteiro ou uma área (página e componente vêm na próxima); a `/kit:spec` ainda não lê o `DESIGN.md` como ponto de partida nem abre o redesenho sozinha; o `/kit:plan`, o `/kit:execute` e o `kit:ui-reviewer` ainda não consomem nem cobram a direção; o `/kit:init` e o `ui.sh status` ainda não conhecem a rule de direção. A escrita em `.claude/` pede a confirmação do Claude Code.

## 0.9.21

### Corrigido

- **Caminho com `${VAR}` nos guardas.** `echo X=1 > "${DIR}/.env"`, `tee "${DIR}/.env"`, `cp a "${DIR}/.env"` e, com o grupo `segredos`, `cat "${DIR}/.env"` e `grep KEY ${DIR}/.env` passavam, porque as chaves separavam o nome do arquivo do comando. Agora `${VAR}` é lido como `$VAR` e o alvo é conferido pelo nome, como já acontecia com `$DIR/.env`.
- **Guarda de comando lento em heredoc.** Num heredoc longo com muitos `>` (HTML, Python com `->`), cada alvo abria processos e o guarda chegava perto do limite de 10 s do hook; com o projeto numa pasta montada pelo Git Bash (como `%TEMP%`), passava dele. O texto repetido é conferido uma vez e cada pasta é resolvida uma vez por chamada: no Windows, 120 funções Python em heredoc caíram de 9,3 s para 2,2 s e 200 linhas de HTML, de 5,5 s para 3,0 s. O tempo ainda cresce com o número de alvos diferentes.
- **`git clean` com `-e` colado.** `git clean -fd -enode_modules` era lido como dry-run por causa do `n` no valor do `-e`, e `git -c clean.requireForce=false clean -d` passava sem `-f`. Os dois são negados.
- `node -e "todos.remove(1)"` não pede mais confirmação: só `os.remove`, `os.system` e afins com `os` como palavra inteira contam.
- Suíte: `--changed` com mudança no `guard-bash.sh` ou no `guard-pwsh.sh` roda também o grupo `guardas`, que tem testes dos dois.

## 0.9.20

### Mudou

- **Texto do grupo `powershell`.** O `/kit:init`, o aviso do `/kit:setup` e as docs deixam de dizer que a ferramenta PowerShell fica fora dos guardas: o grupo nega a ferramenta inteira (cobertura total) e, sem ele, o `guard-pwsh.sh` confere só as formas destrutivas e a escrita e leitura de segredo listadas na referência. O grupo continua oferecido e marcado por padrão no Windows nativo. O "Modelo de ameaça" do README mostra a ferramenta PowerShell como coberta em parte.
- **Teste ao vivo do guarda da ferramenta PowerShell.** O `tests/run-guards-live-test.sh`, no Windows, confere sem o grupo `powershell` que um `Remove-Item -Recurse` pela ferramenta fora do projeto é negado e dentro dele passa.

## 0.9.19

### Entrou

- **Escrita e leitura de segredo pela ferramenta PowerShell.** O `guard-pwsh.sh` passa a aplicar as regras de escrita do `guard-files` (segredo, `guards.deny_write`, `protected_paths`, `guards.allow_write`) a `Set-Content`, `Add-Content`, `Clear-Content`, `Out-File`, `Tee-Object`, `New-Item`, `Copy-Item`, `Move-Item`, `Rename-Item`, `Export-Csv`, `Export-Clixml` e aos aliases deles (`sc`, `ac`, `cp`, `mv`, `ren`, `ni`...), com parâmetros por nome, por prefixo e posicionais: `Set-Content .env 'X=1'` e `Copy-Item .env.example .env` são negados como `echo > .env` e `cp .env.example .env` no Bash. Com o grupo `segredos`, `Get-Content .env`, `Select-String KEY .env`, `Import-Csv`, `Format-Hex`, `Get-Item -Stream` e a origem do `Copy-Item` também são negados, inclusive em `$HOME`, `$env:USERPROFILE` e `${env:USERPROFILE}`; `.env.example` e `node --env-file .env` continuam liberados. Caminho entre aspas com espaço (`Set-Content -Path 'C:\Program Files\x\.env' x`) também é conferido; por isso, num comando com texto entre aspas com espaço, valor posicional com nome de segredo é negado por excesso. `Add-Content .gitignore .env` passa.

## 0.9.18

### Entrou

- **Guarda na ferramenta PowerShell.** Quem desmarca o grupo `powershell` no Windows nativo deixa de ficar sem proteção nessa ferramenta: o novo hook `guard-pwsh.sh` aplica a ela as regras destrutivas do `guard-bash`, lendo aspas e crase como o PowerShell lê (``Remove`-Item`` é `Remove-Item`; barra invertida é caminho). Nega remoção recursiva fora do projeto ou de alvo não resolvível (`Remove-Item -Recurse C:\x`, `ri -r $env:TEMP\x`, `Get-ChildItem | Remove-Item -Recurse`, `ForEach-Object { Remove-Item $_ -Recurse }`), `cmd /c rd /s`, `-EncodedCommand`, `iwr | iex`, `Format-Volume` e afins, git destrutivo e `bash -c` destrutivo; pede confirmação para interpretador inline destrutivo e para git que descarta alteração. Acrescenta `Start-Process` com os argumentos conferidos como comando, `iex` de texto literal e API .NET que apaga (`[IO.Directory]::Delete`, `.Delete()`), esta com pedido de confirmação. `Remove-Item -Recurse .\dist`, `git status` e o uso comum passam. Escrita e leitura de segredo pela ferramenta PowerShell ficam para a próxima versão; o grupo `powershell` continua negando a ferramenta inteira.

## 0.9.17

### Entrou

- **Modelo de ameaça no README.** Uma seção só diz o que o kit garante e o que não garante: protege contra acidentes e contornos do próprio Claude, não contra código malicioso, script gravado e executado, leitura indireta de segredo nem ferramentas fora dos guardas (PowerShell, servidores MCP). Traz as camadas por plataforma (guardas, grupos de permissão, sandbox, revisão humana; o Windows nativo fica sem sandbox) e recomendações: permissões mínimas, credencial de produção fora da máquina de desenvolvimento e revisão humana do que tem alto impacto.

### Mudou

- O "Não cobre" do `guard-bash.sh` em `docs/reference.md` passa a citar os comandos git que descartam ou apagam e que o guarda não confere: `git push --prune`, `git tag -d`, `git branch -M`/`-C`/`-f`, `git prune`, `git gc --prune=<data>`, `git rm -f`, `git worktree remove --force`, `git update-ref -d` e `git filter-branch`.

## 0.9.16

### Entrou

- **Custo no resumo.** O resumo final do `/kit:execute` e do `/kit:map` traz uma linha de custo: quantos subagents foram chamados, de que tipo, quantas rodadas cada revisor fez (no `/kit:execute`) e quantos tokens os subagents somaram. A conversa principal não entra na soma; execução retomada depois de `/compact` ou `/clear` conta só desde a retomada.

## 0.9.15

### Mudou

- **/kit:map mais barato.** O `kit:mapper` passa a rodar em Sonnet em vez do modelo da sessão: é leitura e extração, com `arquivo:linha` em cada afirmação. O `kit:map-verifier` continua no modelo da sessão, mais forte que o mapeador que ele confere. Os outros agents não mudam.

## 0.9.14

### Mudou

- **Uma revisão só em plano de uma wave.** No `/kit:execute`, quando o plano tem uma wave só (fora a final), o checkpoint roda os `verify` e confere os `done`, mas não chama o `kit:code-reviewer`: o diff da wave é o mesmo que a wave final revisa. O checkpoint registra `Revisão: na wave final`. Plano com várias waves, ou no formato antigo sem wave final, não muda.

## 0.9.13

### Mudou

- **Revisão com teto no /kit:execute.** O `kit:code-reviewer` do checkpoint de cada wave e os revisores da wave final (F2) passam a rodar no máximo 3 rodadas, como já faziam o `plan-reviewer` e o `ui-reviewer`. Se depois da terceira ainda sobrar BLOCKER ou MAJOR, a execução para e pergunta: continuar corrigindo, aceitar o achado (registrado em Decisões do PLAN.md) ou parar. Ela nunca segue para a próxima wave com achado grave aberto sem a sua resposta. O template do PLAN.md diz o mesmo na F2.

## 0.9.12

### Entrou

- **cmd e PowerShell dentro do Bash.** O guarda de comando passa a ler o que vai em `cmd /c` e `powershell`/`pwsh -Command`: `rd /s`, `del /s` e `Remove-Item -Recurse` (e os aliases `ri`, `rm`, `rmdir`, `rd`, `del`, `erase`) fora do projeto são negados como o `rm -rf`; `git` passa pelas mesmas regras; `iwr`/`irm`/`DownloadString` com `iex` é negado como `curl | sh`; `format`, `Format-Volume`, `Clear-Disk`, `Remove-Partition` e `Initialize-Disk` são negados. `powershell -EncodedCommand` (`-enc`, `-e`, `-ec`) é negado porque o conteúdo não pode ser conferido. Como no `rm -rf` com variável, o que o guarda não consegue resolver nega: alvo com `%VAR%` ou drive de provedor (`HKCU:`), `Remove-Item -Recurse` sem alvo (itens vindos do pipeline) e alvo relativo depois de `Set-Location`, `sl`, `chdir` ou `-WorkingDirectory`.
- **Confirmação para código inline destrutivo.** `python -c`, `node -e`, `perl -e`, `ruby -e`, `php -r`, `deno eval` e `bun -e` com código que apaga arquivo ou dispara outro processo (`rmtree`, `os.remove`, `unlink`, `subprocess`, `child_process`, `rmSync`, `system`...) pedem sua confirmação; em `bypassPermissions`, são negados. Código sem essas palavras (`python -c "import json; ..."`) passa sem atrito. Script gravado e depois executado (`python limpa.py`) continua fora: é papel do sandbox.

## 0.9.11

### Entrou

- **Leitura de segredo pelo shell.** Com o grupo `segredos` marcado no `/kit:init`, o guarda de comando nega `cat .env`, `grep KEY .env`, `source .env`, `sed`/`awk` no arquivo, `cp .env` para outro lugar, `curl -d @.env`, `< .env` e afins, com os mesmos nomes que o grupo já negava no `Read` (inclusive `~/.ssh`, `~/.aws` e as outras credenciais da home). Arquivo de exemplo (`.env.example`), `grep .env .gitignore` (o nome como padrão), `node --env-file .env` e `docker compose --env-file .env` continuam liberados. Sem o grupo, nada muda.

## 0.9.10

### Entrou

- **Escrita pelo shell nos guardas.** `echo X=1 > .env`, `tee -a .env`, `sed -i` numa migração, `cat > arquivo-gerado <<EOF`, `cp a .env`, `mv` de arquivo protegido e afins passam pelas mesmas regras do `Edit`: segredos, `guards.deny_write` e `protected_paths` do `kit.json`, com as mesmas mensagens. Arquivo de exemplo (`.env.example`), `/dev/null`, `2>&1` e arquivos comuns (`> build.log`, `> /tmp/x`) continuam liberados. Texto entre aspas que cita `> .env` também é negado.

## 0.9.9

### Mudou

- **Guarda de comando mais rápido.** Comando sem nenhuma palavra que o guarda examina (`rm`, `git`, `find`, `curl`, `$`, ...) é liberado sem abrir processo além da leitura da entrada, e os que precisam de análise fazem o casamento no próprio bash. No Windows, cada chamada de Bash passou de cerca de 590 ms para 125 ms sem gatilho e 185 ms com gatilho. O que o guarda nega ou pede para confirmar não mudou.

## 0.9.8

### Mudou

- **Bloqueio sem contorno.** Toda negação dos guardas termina com a mesma instrução ao Claude: não tentar outro comando, interpretador ou ferramenta para o mesmo efeito, e sim explicar o que queria fazer e pedir que você rode manualmente se for intencional. Evita, por exemplo, um `Edit` negado em `.env` virar `echo > .env`, ou um `rm -rf` negado virar `python -c "shutil.rmtree(...)"`.

## 0.9.7

### Entrou

- **Git destrutivo local.** O guarda de comando passa a negar `git clean -f` (antes só com `-d` ou `-x`), `git stash drop` e `clear`, `git branch -D`, `git reflog expire` e `git gc --prune=now`.
- **Descartar alteração pede confirmação.** `git checkout -- <caminho>`, `git checkout .`, `git checkout -f`, `git restore` (fora o `--staged`), `git switch -f` e `git switch --discard-changes` não rodam direto: você vê o motivo e confirma. Em `claude -p`, sem ninguém para confirmar, e em `bypassPermissions` viram negação. Se o mesmo comando tiver um trecho negado, a negação ganha.

## 0.9.6

### Entrou

- **Interface.** Em projeto com tela, o kit passa a cuidar da interface do começo ao fim. A SPEC de feature com tela ganha a seção `## Telas` (ação principal, fluxo, estados de vazio, carregando, erro e sucesso, tela pequena), e o revisor reprova tela sem esses estados. O plano transforma cada estado em verdade a provar e aponta a tela existente que serve de molde.
- **Captura em todos os tamanhos.** `ui` no `kit.json` (`globs`, `dev`, `url`, `routes`, `viewports`). O `/kit:execute` sobe o app, abre cada tela num navegador headless e percorre de 320 a 1920px, inclusive um pixel antes e um depois de cada ponto de quebra do CSS da página. Mede rolagem horizontal, controle sem nome acessível, contraste, alvo de toque, imagem sem texto alternativo e erro de console; página com tema escuro tem o contraste medido também no escuro. Precisa só de `node` e de um navegador Chromium instalado.
- **Revisor de interface.** `kit:ui-reviewer` olha as imagens de cada tela em cada tamanho, a medição e o código, com regras de id fixo (B1 a B3, M1 a M9). Roda na wave final de plano com tela.
- **Regras de tela em toda sessão.** O `/kit:init` grava `.claude/rules/kit-ui.md`, que o Claude recebe ao mexer em arquivo de interface: reuso, tokens, estados, tela pequena primeiro, WCAG 2.2 AA e a documentação da versão instalada da biblioteca de componentes.
- **Tela atrás de login ou clique.** A captura aceita os passos que levam até o estado (`--steps`, em JSON: `click`, `fill`, `press`, `hover`, `wait`, `goto`, `js`) e os refaz em cada tamanho antes de medir e fotografar; `setup` faz o login uma vez. Senha fica em variável de ambiente (`${NOME}`), nunca no arquivo. Não depende de plugin de terceiro e funciona igual em Windows, macOS e Linux.
- **Captura que não engana.** Tela que não pôde ser medida por inteiro sai como `incompleta`, com código de saída próprio, em vez de "sem achados". Rota que redireciona (para o login, por exemplo) é avisada. A captura só derruba o app que ela mesma subiu: o que já estava rodando continua rodando, mesmo lento.
- **Tema escuro por classe.** Além de `prefers-color-scheme`, a captura reconhece o tema ligado por `.dark`, `[data-theme=dark]` e parecidos, e mede o contraste nele.
- `/kit:fix` reproduz bug visual pela medição quando nenhum teste consegue.

### Mudou

- `setup.sh guards` confere a forma do `ui`.
- Revisor de SPEC: M10 e M11 (tela sem estados, tela sem ação principal ou sem versão para tela pequena). Revisor de plano: estado de tela entra no B3, e M9 para tarefa de tela sem estado ou sem molde.

## 0.9.5

### Entrou

- **Projeto do zero pelo `/kit:init`.** Numa pasta vazia, `/kit:init <o que o app faz>` pergunta só o que muda o esqueleto (tipo de app e onde roda, stack como conjunto, dados, integrações obrigatórias), cria o projeto mínimo com teste e lint passando e segue com a configuração normal. Não cria nenhuma feature e não commita.

### Corrigido

- **Guarda de escrita lento no Windows.** O `guard-files` criava alguns processos por entrada de `protected_paths`, e no Git Bash cada processo custa dezenas de milissegundos. Com 16 entradas levava cerca de 6 s por edição; com a máquina ocupada passava do limite de 10 s do hook e toda edição era bloqueada. Agora a entrada e cada `kit.json` são lidos uma vez e o casamento por regra não cria processo: cerca de 0,6 s, quase sem crescer com a lista.
- Os outros hooks de cada chamada (`guard-bash`, `format`, `advise`) também criam menos processos.

## 0.9.4

### Entrou

- **Aviso de lint fora do gate.** No início da sessão, projeto com comando `lint` que não está em `verify_on_stop` recebe um aviso: nenhum passo do kit roda o lint nesse caso.

### Mudou

- O aviso de `diff_deny` com `level: "warn"` não repete quando a linha só muda de número.
- `/kit:fix`, `/kit:hunt` e o `investigator` sabem que o comando do `kit.json` pode vir na forma objeto.

### Corrigido

- macOS (bash 3.2): arquivo com apóstrofo no nome quebrava o `{files}` do gate e do `format`.
- `/kit:map` com a pasta atrás de um symlink (`/var` no macOS) não reconhecia o repositório principal.
- A suíte de testes passa no macOS.

## 0.9.3

### Entrou

- **`diff_deny`.** Padrões proibidos nas linhas adicionadas no turno: supressão de lint e de tipo, teste pulado ou focado. Código antigo não conta. `level: "block"` barra no fim do turno; `"warn"` vira aviso na edição. O `/kit:init` propõe os padrões de partida do stack.
- **Comando na forma objeto.** `{ "run": "<comando> {files}", "files": [<globs>] }`: o gate só roda o comando quando algum arquivo alterado casa `files`, e só esses vão para `{files}`. Serve para o lint de uma linguagem num repositório com mais de uma.
- **Lint no gate.** O `/kit:init` propõe `lint` no `verify_on_stop` quando o projeto tem linter, de preferência por arquivo, e o `format` com correção de lint onde a ferramenta é rápida.
- **Regra de código sem teste.** `coupled_changes` com `level: "warn"`: ao editar código de produção sem tocar em teste, o Claude recebe um lembrete.
- **Revisor de código: M5 a M8.** Código novo que duplica o que já existe, supressão nova sem justificativa, teste que não falharia sem a implementação e dependência não prevista no plano.

### Mudou

- O gate roda todos os comandos de `verify_on_stop`, mesmo depois de uma falha, e entrega as falhas numa mensagem só. Antes parava na primeira.
- A mensagem do gate cabe em 9.000 caracteres: falhas curtas saem inteiras e as longas são cortadas no meio.
- O revisor de código não roda mais build, lint nem teste; isso fica com o gate e com o checkpoint do `/kit:execute`. Projeto que tinha `lint` só em `commands` precisa do `/kit:init` em modo reparo para o lint entrar no gate.
- `setup.sh guards` confere a forma de `commands` e de `diff_deny`.

### Corrigido

- Comando do gate que lia a entrada padrão impedia os comandos seguintes de rodar.
