# Changelog

O que mudou em cada versão, do ponto de vista de quem usa o kit. Depois de atualizar, rode `/kit:init` de novo em cada projeto (modo reparo) para ele propor o que a versão trouxe para o `kit.json`.

Versões anteriores à 0.9.3 estão nas tags do repositório.

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
