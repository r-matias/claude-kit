# Changelog

O que mudou em cada versão, do ponto de vista de quem usa o kit. Depois de atualizar, rode `/kit:init` de novo em cada projeto (modo reparo) para ele propor o que a versão trouxe para o `kit.json`.

Versões anteriores à 0.9.3 estão nas tags do repositório.

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
