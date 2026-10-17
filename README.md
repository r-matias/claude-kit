# claude-kit

[![testes](https://github.com/r-matias/claude-kit/actions/workflows/tests.yml/badge.svg)](https://github.com/r-matias/claude-kit/actions/workflows/tests.yml)

Plugin do Claude Code que serve para qualquer stack (.NET, Node, Python, Go ou outro). Traz comandos de fluxo (spec, plano, execução, correção de bug), revisores independentes e guardas automáticos.
Cada projeto só declara os comandos do seu stack em `.claude/kit.json`; o resto é igual em todos.

O que você ganha:

- **Menos estrago.** Comandos destrutivos (`rm -rf` fora do projeto, `git push --force`, `DROP TABLE`) e escrita em segredos (`.env`, chaves) são barrados antes de rodar.
- **Turno só termina verde.** Quando o Claude mexe em código, build e testes rodam antes de ele dizer que acabou.
- **Feature com plano conferível.** SPEC → PLAN com tarefas testáveis → execução em etapas, com revisão de código e de segurança no fim.
- **Bug pela causa raiz.** Primeiro um teste que reproduz, depois a correção.

## Começar

Requisitos mínimos: Claude Code 2.1.295 ou mais novo, `git`, `bash` e `jq` (no Windows, o Git for Windows traz `git` e `bash`). Detalhes em [Requisitos e plataformas](#requisitos-e-plataformas).

O fluxo inteiro é: **instalar o plugin → `/kit:init` → `/kit:spec`** (e depois `/kit:plan` → `/kit:execute`). Nenhum passo manual entre eles.

1. Instale o plugin, uma vez por máquina, no Claude Code:

   ```text
   /plugin marketplace add r-matias/claude-kit
   /plugin install kit@claude-kit
   ```

   Pelo terminal: `claude plugin marketplace add r-matias/claude-kit` e `claude plugin install kit@claude-kit`. Se o `/kit:init` não aparecer logo depois, reinicie a sessão.
2. Abra o Claude Code na raiz do repositório e rode `/kit:init`. Ele mostra tudo o que vai fazer e pede **uma** confirmação; depois faz tudo e termina em `Pronto. Próximo: /kit:spec <ideia>`. É o único comando de configuração que você precisa conhecer.
3. Para cada feature: `/kit:spec` → `/clear` → `/kit:plan` → `/kit:execute` (ver [Fluxo do dia a dia](#fluxo-do-dia-a-dia)).

## O que o `/kit:init` faz

Se o kit consegue fazer, ele faz. Primeiro junta tudo o que vai propor, mostra os arquivos novos e os diffs e pede uma confirmação só (com as poucas decisões que são suas, como os grupos de permissão ou a URL do smoke). Com o "sim":

1. **Confere a máquina**: Claude Code, `git`, `bash` e `jq` (e `bwrap`/`socat` no Linux e no WSL2), e instala o que faltar.
2. **Configura o projeto** (o adaptador), descrito abaixo.
3. **Liga o LSP da linguagem**: acrescenta o plugin LSP oficial (`typescript-lsp`, `pyright-lsp`, `csharp-lsp`, `gopls-lsp`, ...) ao `.claude/settings.json` do projeto e instala o language server se faltar.
4. **Verifica**: roda uma vez cada comando de `verify_on_stop` e mostra `ok` ou `falhou`.
5. **Pergunta sobre notificações** (desligadas por padrão), avisando se você já tem alertas que seriam duplicados (ver [Notificações](#notificações)).
6. **Mapeia o código**, se o projeto tiver mais de 300 arquivos de código ou mais de um repositório: roda o `/kit:map` ao final, sem perguntar (só pergunta se passar de 30 agents).
7. **Relatório curto** (até ~10 linhas): o que foi feito (com o caminho de cada backup), o que foi verificado, avisos reais e `Pronto. Próximo: /kit:spec <ideia>`. Ele não lista tarefas para você.

Rodado de novo num projeto já configurado, entra em modo reparo: valida o `kit.json`, os comandos e o settings, soma só o que falta (mesma confirmação única) e roda `/kit:map --update` se o mapa estiver desatualizado.

Na configuração do projeto:

- **Repositório sem configuração do Claude Code:** o init detecta o stack (manifestos, Makefile, CI) e cria:
  - `.claude/kit.json` com os comandos reais do projeto;
  - `.claude/settings.json`, que liga o plugin e o LSP, libera os comandos do `kit.json`, pergunta antes de instalar dependência e traz os grupos de permissão que você marcar (abaixo);
  - um `CLAUDE.md` curto;
  - as linhas `.claude/state/` e `.claude/*.bak-kit-*` no `.gitignore`.
- **Repositório que já tem `.claude/`, `CLAUDE.md` ou `.mcp.json` (modo adotar):** o init faz o inventário de hooks, skills, agents e rules, aponta sobreposições com o kit, soma ao `.claude/settings.json` o que falta e grava o relatório em `docs/claude-adoption.md`.

### Permissões: no projeto, você escolhe

O kit não altera seu settings global (`~/.claude/settings.json` ou o de `CLAUDE_CONFIG_DIR`): nem o `/kit:setup` nem o `/kit:init` gravam nele. As permissões ficam no `.claude/settings.json` do projeto, e você escolhe os grupos numa pergunta de múltipla escolha da confirmação (todos vêm recomendados; o desmarcado fica de fora):

| Grupo | O que faz |
| --- | --- |
| `segredos` | Nega ler `.env`, `.env.local`, `.env.*.local`, `.env.test`, `.env.production`, `.env.development`, `.env.staging`, `*.pem`, `*.key`, `secrets/` e credenciais em `~` (`.ssh`, `.aws`, `.kube`, `.git-credentials`, `.npmrc`, `gh`, `docker`). Por nome, nunca `.env.*`, para `.env.example` e `.env.test.example` continuarem legíveis |
| `git-destrutivo` | Nega `git push --force`/`-f`, `git reset --hard` e `git clean -fdx` |
| `push` | Todo `git push` pede confirmação |
| `curl-wget` | Nega `curl` e `wget` (o registry do stack fica liberado no sandbox). Só é oferecido se o projeto não usa nenhum dos dois (skills, agents, commands, hooks, scripts do `package.json`, `Makefile`, `justfile`, regras `allow`/`ask`); senão o relatório diz quantos arquivos usam |
| `powershell` | Só no Windows nativo: nega a ferramenta PowerShell, que os guardas não cobrem |
| `sandbox` | Só no macOS e no Linux/WSL2 com `bwrap` e `socat`: liga o sandbox do Bash e pede confirmação para rodar fora dele |

A escolha fica em `permissions.groups` do `.claude/kit.json`; no modo reparo, grupo que você desmarcou não volta a ser proposto. Habilitar o kit num projeto é o mesmo que instalar com `--scope project`: `enabledPlugins` e `extraKnownMarketplaces` vão para o settings do projeto.

### O kit só soma

- **Nunca altera** skills, agents, commands, rules, hooks, `CLAUDE.md`, `.mcp.json` nem `.claude/settings.local.json`, seus ou do projeto.
- **No `.claude/settings.json` do projeto só acrescenta**: itens novos em listas (`allow`, `ask`, `deny`, `allowedDomains`, `excludedCommands`) e chaves que não existem. Nunca remove, nunca troca um valor seu e nunca mexe em `hooks`. Antes de gravar, faz backup em `<arquivo>.bak-kit-<data>` e mostra o diff na confirmação. Se uma chave sua tem outro valor, o seu fica e o relatório cita em uma linha. Regra sua em `allow` ou `ask` que um deny do kit cobriria (ex.: `ask` de `Bash(curl *meusite.com*)`) deixa esse deny de fora, porque deny vence e você perderia a chance de autorizar.
- **Sobreposição:** se uma skill ou agent seu faz o mesmo que um do kit, o do kit sai do caminho (`Skill(kit:fix)` em `permissions.deny`). Um hook seu que o kit cobre fica como está; `docs/claude-adoption.md` registra qual é.
- Os arquivos do próprio kit podem ser regravados: `.claude/kit.json`, `docs/claude-adoption.md` e os do mapa (`.claude/rules/map-*.md`, `.claude/rules/kit-codemap.md`, `docs/codemap.md`, com o cabeçalho `kit:map`).

Os arquivos criados ficam no git para você commitar junto com o código (o kit nunca commita). Quem clonar o repositório recebe o plugin pelo settings versionado; na própria máquina, basta rodar o `/kit:init`.

Na pasta-mãe de vários repositórios (cada um com seu `.git`), rode o `/kit:init` na pasta-mãe: ele configura cada repositório e as regras que cruzam repositórios.

## Fluxo do dia a dia

**Feature:** `/kit:spec` → `/clear` → `/kit:plan` → `/kit:execute`

1. `/kit:spec` entrevista você e grava `docs/specs/<slug>/SPEC.md` (objetivo, escopo, fora de escopo, como verificar).
   - `/kit:spec exportar o relatório de vendas em CSV`
   - `/kit:spec usuário pode trocar o e-mail com confirmação por link`
2. `/clear` limpa o contexto antes de planejar.
3. `/kit:plan` transforma a SPEC num `PLAN.md` com tarefas testáveis agrupadas em etapas (waves). Decide sozinho os detalhes técnicos e registra cada decisão no plano; só pergunta o que é decisão de produto. Um revisor confere o plano contra a SPEC antes de entregar: cada achado cita uma regra com id e severidade fixa (por exemplo `BLOCKER [B1]`, tarefa que usa algo da mesma wave), e o plano só sai quando o revisor diz `aprovado`.
   - `/kit:plan docs/specs/export-csv/SPEC.md`
   - `/kit:plan` (sem argumento: usa a SPEC mais recente)
4. `/kit:execute` implementa wave a wave, escreve os testes de cada tarefa e só marca uma tarefa como feita com evidência. Ao fim de cada wave revisa o diff; no fim do plano passa por revisão de código e de segurança. Para antes de qualquer ação irreversível (deploy, push, migração em banco real) e nunca commita sem você pedir.
   - `/kit:execute docs/specs/export-csv/PLAN.md`
   - `/kit:execute` (retoma o plano mais recente da primeira tarefa pendente; útil depois de um `/compact`)

**Épico** (algo grande demais para uma feature): `/kit:epic` quebra em fatias que entregam valor sozinhas e grava `docs/specs/<epico>/EPIC.md`; cada fatia vira uma feature.

**`/kit:epic` ou `/kit:spec`?** Use `/kit:spec` para uma entrega que cabe num plano revisável: até 8 itens de Escopo, ~25 arquivos e 2 repositórios. Acima disso, comece pelo `/kit:epic`. Se você começar pelo `/kit:spec` e passar do limite, ele não grava uma SPEC única: pergunta uma vez se quebra em fatias (recomendado, já com as fatias sugeridas), mantém numa spec só ou reduz o escopo. Quebrar não pede outro comando: o próprio `/kit:spec` grava o `EPIC.md` e uma SPEC por fatia, no formato do `/kit:epic`, e indica o `/kit:plan` da fatia 1. O `/kit:plan` faz a mesma pergunta quando o plano passa de 15 tarefas ou 6 waves; se você escolher manter, a escolha fica em Decisões e o revisor não reclama mais (sem ela, acusa `MAJOR [M8]`). Os limites são configuráveis em `spec` e `plan` no `kit.json`.

- `/kit:epic portal do cliente com login, faturas e suporte`
- `/kit:epic migrar o checkout para o novo gateway de pagamento`

**Bug conhecido:** `/kit:fix` começa por um teste que reproduz a falha e corrige pela causa raiz.

- `/kit:fix #482`
- `/kit:fix o total do carrinho ignora o desconto quando há frete grátis`

**Falha vaga** (às vezes falha, ficou lento, ninguém sabe onde quebrou): `/kit:hunt` investiga sem editar código e devolve hipóteses ranqueadas com evidência. Depois, `/kit:fix` com a causa encontrada.

- `/kit:hunt o teste de integração de pedidos falha uma vez a cada dez execuções`
- `/kit:hunt a listagem de produtos ficou lenta depois do último deploy`

## Referência dos comandos

| Comando | Quando usar | O que gera | Como dispara |
| --- | --- | --- | --- |
| `/kit:init` | Uma vez por repositório; de novo para reparar | Máquina pronta, `.claude/kit.json`, `.claude/settings.json`, `CLAUDE.md` (e `docs/claude-adoption.md` no modo adotar, `docs/codemap.md` em projeto grande) | Só manual |
| `/kit:spec` | Começo de uma feature sem especificação | `docs/specs/<slug>/SPEC.md` | Manual ou sozinho, quando você descreve uma feature nova |
| `/kit:plan` | SPEC pronta | `PLAN.md` ao lado da SPEC | Manual ou sozinho, quando há uma SPEC para planejar |
| `/kit:execute` | Plano pronto | Código e testes; caixas do `PLAN.md` marcadas com evidência | Só manual |
| `/kit:epic` | Trabalho grande, várias entregas | `docs/specs/<epico>/EPIC.md` | Só manual |
| `/kit:fix` | Bug com sintoma claro ou teste falhando | Teste que reproduz + correção | Manual ou sozinho, quando você relata um bug |
| `/kit:hunt` | Falha intermitente, lentidão, causa desconhecida | Hipóteses com evidência, sem editar código | Manual ou sozinho, quando você relata uma falha vaga |

| `/kit:setup` | Avançado: conferir a máquina sem abrir um projeto | Só um resumo: não grava nada | Só manual |
| `/kit:map` | Avançado: mapear de novo, uma área ou só o que mudou | `.claude/rules/map-*.md`, `docs/codemap.md` | Só manual |

"Sozinho" quer dizer que o Claude pode escolher o comando ao reconhecer o pedido, sem você digitar a barra.

## Avançado (opcional)

Nada aqui é necessário: o `/kit:init` já faz a conferência do `/kit:setup` e roda o `/kit:map` quando precisa.

### `/kit:setup`

Só confere a máquina, sem abrir um projeto e sem gravar nada:

- Claude Code na versão mínima, `git`, `bash` e `jq`; no Linux e no WSL2, também `bwrap` e `socat`. O que faltar sai com o comando de instalação (o `/kit:init` instala com a sua confirmação);
- a plataforma (Windows nativo, WSL2, macOS ou Linux) e o sandbox: no Windows nativo não há sandbox, e ele avisa; no Linux e no WSL2 avisa se o AppArmor restringe user namespaces.

### `/run-skill-generator` e `/verify`

Comandos do próprio Claude Code, úteis depois do `/kit:init` se você quiser verificação com o app rodando:

- `/run-skill-generator` sobe o app a partir de um ambiente limpo e grava a receita em `.claude/skills/run-<nome>/`;
- `/verify` grava a skill de verificação do projeto em `.claude/skills/verify/SKILL.md`, que o Claude Code roda antes de cada commit.

### `/kit:map`

Dá ao Claude o contexto de arquitetura de um projeto grande ou com vários repositórios sem inchar o `CLAUDE.md`. Um script divide o código em unidades (pacotes, workspaces, pastas de topo; ~150 arquivos ou ~20 mil linhas cada), um subagent somente leitura mapeia cada unidade em paralelo, dois outros cruzam integrações e fluxos ponta a ponta, e um verificador separado confere as afirmações abrindo cada `arquivo:linha`; o que ele reprova sai do mapa.

```text
/kit:map                 # tudo: todos os repositórios de "repos", ou só o atual
/kit:map src/billing     # só uma área
/kit:map --update        # só as unidades que mudaram desde o último mapa
```

O resultado fica no git:

- `.claude/rules/map-<unidade>.md`: carregada só quando o Claude mexe naquela área (frontmatter `paths:`), até 40 linhas;
- `docs/codemap.md`: visão geral, tabela de unidades, integrações, fluxos e divergências de contrato, até 150 linhas;
- `.claude/rules/kit-codemap.md`, sem `paths:` (carrega em toda sessão), com 2 a 3 linhas apontando para o codemap. O `CLAUDE.md` não é tocado.

**Confirmação de escrita.** O `/kit:map` já traz permissão para gravar só os arquivos dele (`docs/codemap*.md`, `.claude/rules/map-*.md`, `.claude/rules/kit-codemap*.md`), então o `docs/codemap.md` sai sem prompt. A pasta `.claude/`, porém, é um caminho protegido do Claude Code: escrita nela sempre pede confirmação, mesmo com permissão liberada ou em `acceptEdits` (só `bypassPermissions` dispensa). No primeiro prompt, escolha a opção que libera a edição da pasta `.claude` do projeto nesta sessão, e as demais rules saem sem perguntar.

Texto seu entre `<!-- manual -->` e `<!-- /manual -->` sobrevive ao remapeamento. O kit só regrava arquivos com o cabeçalho `kit:map`; rules que você escreveu nunca são tocadas. Os investigadores de `/kit:plan`, `/kit:fix` e `/kit:hunt` leem o codemap antes de explorar e confiam no código quando divergem. Quando o codemap fica mais de 50 commits atrás (`map.stale_after_commits`), o início da sessão sugere `/kit:map --update`.

**Custo.** Cada unidade é um subagent, mais dois transversais e um verificador a cada 8 unidades, em ondas de até 8 em paralelo. Ordem de grandeza: ~50 mil tokens por agent; um projeto de 3 mil arquivos dá ~20 unidades, ~25 agents. Antes de lançar, o `/kit:map` mostra o plano; acima de 30 agents (`map.max_agents`) ele pergunta. Para gastar menos, mapeie uma área ou aumente `map.unit_max_files`/`map.unit_max_loc`. O `--update` só paga as unidades que mudaram.

## O que o kit faz sozinho

Sem você chamar nada, em todo projeto com o kit ligado:

- **Guardas.** Antes de cada comando ou escrita, o kit barra o que é destrutivo ou sensível:
  - `rm -rf` fora do projeto, `git push --force`, `git reset --hard`, `git clean -fdx`;
  - `DROP`/`TRUNCATE` em SQL, `curl ... | sh`;
  - escrita em `.env`, chaves e `secrets/`, e nos caminhos protegidos do projeto (código gerado, migrações).

  O Claude recebe o motivo e procura outro caminho.
- **Formatação.** Cada arquivo editado passa pelo formatter do projeto, se o `kit.json` declarar um.
- **Gate de fim de turno.** Se o Claude mexeu em código, os comandos de verificação do projeto (build, testes relacionados) rodam antes de ele encerrar. Falhou: ele recebe o erro e continua corrigindo. O gate também confere regras do projeto, como "mudou a tela, atualize o manual" e "todo texto existe nas 3 línguas".
- **Avisos.** Regras de acoplamento leves ("se mudou a API, confira o site") viram um lembrete para o Claude na hora da edição, sem bloquear nada.
- **Contexto da sessão.** No início de cada sessão o Claude recebe a branch, os arquivos alterados e as tarefas pendentes do plano ativo. Antes de uma compactação, o kit salva esse estado e o devolve depois. Se faltar `jq` ou `git`, ou se o Claude Code estiver desatualizado, o aviso aparece aqui, com o comando para corrigir. O mesmo vale para um `docs/codemap.md` muito atrás do código: o aviso sugere `/kit:map --update`.

## Ajustar o kit ao projeto

Tudo fica no `.claude/kit.json` do projeto, versionado.

- **Liberar um arquivo protegido:** `guards.allow_write` com o caminho exato (ou um glob estreito). Vale para o que casa `protected_paths`. Glob largo (`*`, `**`, `**/*`, `.env*`, `*.env`) é ignorado, e segredo de verdade (`.env`, `.env.<qualquer>` sem sufixo de exemplo, `*.pem`, `*.key`, `keys/`, `secrets/`) não tem exceção: o `/kit:init` avisa que a entrada foi ignorada.
- **Bloquear mais caminhos:** `guards.deny_write`, com `message` opcional por item.
- **Grupos de permissão:** `permissions.groups` guarda o que você marcou no init; tire um id da lista e o reparo não o propõe mais.

```json
{
  "guards": {
    "allow_write": ["src/generated/README.md"],
    "deny_write": [{ "glob": "docs/legal/**", "message": "Texto jurídico: só o time legal altera." }]
  },
  "permissions": { "groups": ["segredos", "git-destrutivo", "push", "sandbox"] }
}
```

Arquivo com nome terminado em `.example`, `.sample`, `.template` ou `.dist` (ex.: `.env.test.example`, `.env.production.sample`) não é tratado como segredo.

Os subagents do kit e os que o `/kit:execute` dispara rodam um comando por chamada de Bash, sem encadear com `&&`, `;` ou `|`, e leem arquivo com Read: um bloco encadeado cai inteiro numa regra `ask` do projeto e pede aprovação até para uma leitura. Nenhum comando do kit entrega a você um comando com placeholder (`<seu valor>`): o valor é perguntado antes e gravado na config do projeto, ou, se for segredo, no `.env` que o próprio script carrega.

## Notificações

Opcionais e desligadas por padrão. O kit avisa quando a sessão precisa de você (pedido de permissão, pergunta parada) e quando um turno longo termina de verdade:

```text
⏳ meu-app: Claude needs your permission to use Bash
✅ meu-app (main): concluído em 4m12s
```

O "concluído" só sai quando o gate de fim de turno liberou (passou ou não havia o que verificar) e o turno durou pelo menos `done_min_seconds` (60 s). Gate que bloqueou não avisa. Turno em que o gate barrou e o Claude corrigiu avisa quando o gate libera.

**Como ligar.** O `/kit:init` pergunta na confirmação única, com as duas opções desmarcadas: "Avisar quando aguardar resposta" e "Avisar quando terminar". Antes, ele procura alertas que você já tem (hooks de Notification ou Stop no seu settings, no do projeto ou em outros plugins, e o `preferredNotifChannel`) e, se achar, avisa que ligar os do kit vai duplicar. Esses alertas nunca são alterados, só relatados. Se você não marcar nada, o init grava `"notify": false` e o reparo não pergunta de novo. Para mudar depois, edite o `.claude/kit.json`:

```json
{
  "notify": {
    "waiting": true,
    "done": true,
    "done_min_seconds": 60,
    "sound": true,
    "push": { "ntfy_topic_env": "KIT_NTFY_TOPIC", "discord_webhook_env": "KIT_DISCORD_WEBHOOK" }
  }
}
```

Onde aparece: toast do Windows (Git Bash e WSL, pelo `powershell.exe`, sem módulo extra), Central de Notificações no macOS e `notify-send` no Linux. Sem nenhum deles, o sino do terminal. `sound` usa o som do sistema. A notificação roda em segundo plano e nunca atrasa nem bloqueia o Claude.

**Push no celular com ntfy, em 2 passos:**

1. Instale o app [ntfy](https://ntfy.sh) no celular e assine um tópico difícil de adivinhar, como `claude-7f3k9q2x` (quem souber o nome lê as mensagens).
2. Defina a variável no ambiente em que o Claude Code roda e reabra-o: `export KIT_NTFY_TOPIC=claude-7f3k9q2x` no `~/.bashrc`/`~/.zshrc`, ou `setx KIT_NTFY_TOPIC claude-7f3k9q2x` no Windows.

O `push` precisa estar no `notify` (o init já grava assim). Servidor ntfy próprio: use a URL completa (`https://ntfy.exemplo.com/claude`). Discord: a URL do webhook em `KIT_DISCORD_WEBHOOK`. O `kit.json` guarda só o nome da variável, nunca o tópico ou a URL.

**Diferença para o aviso nativo do Claude Code.** O Claude Code tem a configuração `preferredNotifChannel` no settings (`auto`, o padrão; `terminal_bell`; `notifications_disabled`; e canais de terminal, ver a [doc oficial](https://code.claude.com/docs/en/terminal-config)). No `auto`, a notificação do sistema só aparece no iTerm2, no Ghostty e no Kitty; nos outros terminais (Windows Terminal, VS Code, a maioria no Linux) fica o sino, se você escolher `terminal_bell`. O aviso nativo não manda push nem sabe do gate. O do kit funciona em qualquer terminal, manda push e só diz "concluído" quando o gate liberou. Os dois convivem (hooks de Notification rodam junto do aviso nativo, sem substituí-lo): se o nativo já te avisa, ligue só o "concluído" ou só o push.

## O kit bloqueou, e agora?

**Um guarda negou algo legítimo.** A mensagem diz o que foi barrado e por quê.
- Comando destrutivo de verdade necessário (ex.: `git reset --hard` de propósito): rode você mesmo, num terminal fora do Claude Code.
- Caminho protegido do projeto (`protected_paths`): a mensagem diz o que fazer em vez de editar, como o comando que regenera o arquivo. Se a proteção estiver errada e o arquivo não é segredo, adicione o caminho em `guards.allow_write` no `.claude/kit.json` (ver [Ajustar o kit ao projeto](#ajustar-o-kit-ao-projeto)).
- Arquivo de segredo (`.env`, `.env.test`, chave): não tem exceção. Arquivo de exemplo leva um sufixo `.example`, `.sample`, `.template` ou `.dist`.

**O gate não deixa o turno terminar.** Ele mostra numa única mensagem tudo o que falhou: comando de build ou teste, chave de tradução faltando, arquivo acoplado não atualizado. O Claude tenta corrigir; se ainda falhar na tentativa seguinte, o turno termina e a falha fica visível para você. Se o comando de verificação estiver errado ou lento demais, ajuste `verify_on_stop` e `commands` no `.claude/kit.json`.

**Regra de acoplamento que não se aplica a esta mudança.** Grave uma linha de justificativa em `.claude/kit-skip` (ex.: `só renomeei uma variável na tela, o manual não muda`). Isso libera só os acoplamentos (`coupled_changes`), não build, testes nem tradução. O arquivo é apagado quando o gate passa e a justificativa fica registrada em `docs/claude-adoption.md` (ou `.claude/kit-skip.log`). Arquivo vazio não libera.

**"kit: jq não encontrado — instale com <comando> e reabra o Claude Code".** Sem `jq` os guardas bloqueiam toda chamada, de propósito: guarda que não consegue checar não deixa passar. A única exceção é o comando exato de instalação do `jq` da plataforma (`winget install jqlang.jq` no Windows, `brew install jq` no macOS, `sudo apt install jq`, `sudo apt-get install jq`, `sudo dnf install jq` ou `sudo pacman -S jq` no Linux/WSL), sozinho, sem nada junto. A mesma mensagem aparece ao abrir a sessão. Peça ao Claude para rodar o comando, ou rode num terminal, e reabra o Claude Code.

**`Executable not found in $PATH: "bash"`.** Versões antigas do kit chamavam `bash` pelo PATH, o que falha no Windows quando o Git não está no PATH. Atualize o kit (veja [Atualizar e desinstalar](#atualizar-e-desinstalar)). Se persistir no Windows, instale o Git for Windows (`winget install Git.Git`) ou aponte a variável de ambiente `CLAUDE_CODE_GIT_BASH_PATH` para o `bash.exe` (ex.: `C:\Program Files\Git\bin\bash.exe`).

**O kit instalado em dois escopos.** `claude plugin list` mostra `kit@claude-kit` duas vezes, com `Scope: user` e `Scope: project`, cada um com sua `Version`. Cada escopo é atualizado em separado, então um deles pode ficar para trás e você continua vendo o comportamento antigo.
- Atualize cada um. O do projeto se atualiza de dentro da pasta dele: `claude plugin update kit@claude-kit --scope project`.
- Ou mantenha só um: `claude plugin uninstall kit@claude-kit --scope project`.

  O `.claude/settings.json` versionado do projeto continua ligando o plugin para quem clonar.

**Testes com Docker ou banco de dados não rodam.** O sandbox bloqueia o acesso ao Docker e a portas locais. No `.claude/settings.json` do projeto, tire do sandbox só o comando exato da suíte e peça confirmação antes de rodá-lo:

```json
{
  "permissions": { "ask": ["Bash(npm run test:integration)"] },
  "sandbox": { "excludedCommands": ["npm run test:integration"] }
}
```

O `/kit:init` já soma isso ao settings quando detecta testes de integração (inclusive no modo reparo).

**Windows nativo sem sandbox.** O sandbox do Claude Code não existe no Windows nativo. O `/kit:init` não oferece o grupo `sandbox` lá: as regras de `permissions.deny` e os guardas continuam valendo, mas disco e rede não ficam isolados. Para ter sandbox, use o WSL2 e rode o `/kit:init` lá. O grupo `powershell` (só no Windows nativo) nega a ferramenta PowerShell porque os guardas não a cobrem. Quem precisar dela desmarca o grupo, ou remove `"PowerShell"` de `permissions.deny` no `.claude/settings.json` do projeto e tira `powershell` de `permissions.groups`, e fica sem guarda nessa ferramenta.

## Atualizar e desinstalar

Atualizar (no terminal):

```bash
claude plugin marketplace update claude-kit
claude plugin update kit@claude-kit
claude plugin list
```

Reinicie a sessão do Claude Code para a nova versão valer e confira o `Version` de `kit@claude-kit` no `claude plugin list` (em todos os escopos listados). Se ele estiver em mais de um escopo, veja [O kit bloqueou, e agora?](#o-kit-bloqueou-e-agora).

Desinstalar:

```bash
claude plugin uninstall kit@claude-kit --scope user
claude plugin uninstall kit@claude-kit --scope project   # só se estiver instalado no projeto
claude plugin marketplace remove claude-kit              # opcional
```

As regras que o kit acrescentou ao `.claude/settings.json` de cada projeto ficam; o estado anterior está no backup `.claude/settings.json.bak-kit-<data>`. Versões até a 0.8.6 também gravavam regras no `~/.claude/settings.json`, com backup `~/.claude/settings.json.bak-kit-<data>` ao lado; a 0.8.7 em diante não toca nesse arquivo.

## Configuração do projeto (`.claude/kit.json`)

O `/kit:init` gera este arquivo. Todas as chaves são opcionais; chave ausente é pulada sem erro. Os comandos rodam na pasta do `.claude/`.

| Chave | Para que serve | Exemplo |
| --- | --- | --- |
| `commands` | Comandos do stack: `build`, `test`, `test_related`, `lint`, `typecheck`, `smoke`. `{files}` vira a lista de arquivos alterados | `"test_related": "npx vitest related {files} --run"` |
| `verify_on_stop` | Quais `commands` o gate roda ao fim do turno, em ordem | `["build", "test_related"]` |
| `source_globs` | Que arquivos contam como código (só eles disparam o gate) | `["src/**/*.ts"]` |
| `format` | Formatter por tipo de arquivo, rodado a cada edição | `{ "**/*.py": "ruff format {files}" }` |
| `protected_paths` | Caminhos que o Claude não edita, com mensagem do que fazer | `{ "glob": "src/generated/**", "message": "Gerado por npm run codegen." }` |
| `guards` | `allow_write`: caminhos liberados apesar de `protected_paths`; `deny_write`: caminhos extras bloqueados, com `message` opcional | `{ "allow_write": ["src/generated/README.md"] }` |
| `permissions` | `groups`: grupos de permissão escolhidos no `/kit:init` | `{ "groups": ["segredos", "push"] }` |
| `coupled_changes` | Arquivos que mudam juntos; `block` barra no fim do turno, `warn` só avisa | `{ "when": ["src/views/**"], "require": ["manual/**"], "message": "Atualize o manual." }` |
| `key_parity` | Arquivos de tradução que precisam ter as mesmas chaves | `{ "files": ["i18n/pt.json", "i18n/en.json"] }` |
| `plan_dirs` | Pastas extras onde o projeto guarda planos | `[".claude/plans"]` |
| `inject_plan_on_prompt` | Repete a linha do plano ativo a cada mensagem (custa contexto) | `false` |
| `notify` | Notificações de "aguardando" e "concluído", som e push (ver [Notificações](#notificações)); `false` = recusado no init | `{ "waiting": true, "done": true }` |
| `repos` | Na pasta-mãe de vários repositórios, quais filhos considerar | `["app", "web"]` |
| `spec` | Limites de tamanho do `/kit:spec`: `max_scope_items` (8), `max_files` (25) | `{ "max_scope_items": 12 }` |
| `plan` | Limites de tamanho do `/kit:plan`: `max_tasks` (15), `max_waves` (6) | `{ "max_tasks": 20 }` |
| `map` | Limites do `/kit:map`: `stale_after_commits` (50), `unit_max_files` (150), `unit_max_loc` (20000), `max_agents` (30), `primary` (repositório do codemap) | `{ "stale_after_commits": 100 }` |

Exemplo completo em [`plugins/kit/templates/kit.example.json`](plugins/kit/templates/kit.example.json); todas as regras (globs, monorepo, vários repositórios, `kit-skip`) em [docs/reference.md](docs/reference.md).

## Requisitos e plataformas

- **Claude Code ≥ 2.1.295.** Em versão anterior, um guarda que falha ou estoura o tempo deixa a ação passar. O `/kit:init` atualiza com `claude update` (com sua confirmação), e o início da sessão avisa quando a versão é menor.

  | Recurso usado pelo kit | Desde | Efeito em versão anterior |
  | --- | --- | --- |
  | `onFailure: "block"` nos guardas | 2.1.295 | Guarda ausente ou quebrado deixa a ação passar |
  | Skill `verify` do projeto rodada antes de cada commit | 2.1.286 | O commit não roda a receita do `/verify` sozinho |
  | Auto mode como modo padrão | 2.1.283 (provedores terceiros ou sem telemetria); 2.1.284 (todos) | A sessão começa no modo default e pede mais confirmações |
  | `/skill-doctor` | 2.1.261 | Não existe; a rotina de poda usa só o `/doctor` |
  | `claude plugin validate` | 2.1.47 ou anterior (`/plugin validate` desde 2.0.12); 2.1.233 passou a checar `.claude/skills` | Sem validação de manifesto pela CLI |

  Fonte: [changelog oficial](https://code.claude.com/docs/en/changelog) e [referência de hooks](https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails).
- **`bash` 3.2 ou mais novo, `git` e `jq`.** Os scripts rodam no `/bin/bash` 3.2 do macOS, sem `realpath` nem `readlink -f`. No Windows, Git for Windows (traz Git Bash) e `jq` no PATH.
- **Linux e WSL2: `bwrap` e `socat`** para o sandbox (`sudo apt install bubblewrap socat`). Sem eles, o `/kit:init` propõe instalar na confirmação; até lá o grupo `sandbox` não é oferecido. No Ubuntu 24.04 ou mais novo, o AppArmor pode restringir os user namespaces que o `bwrap` usa; o `/kit:init` avisa quando isso acontece.
- **Plataformas:**

  | Plataforma | Sandbox | Observação |
  | --- | --- | --- |
  | macOS | Sim | |
  | Linux | Sim | Precisa de `bwrap` e `socat` |
  | WSL2 | Sim | Recomendado no Windows; precisa de `bwrap` e `socat` |
  | Windows nativo | Não | Sem grupo `sandbox`; valem `permissions.deny` (com o grupo `powershell`) e os guardas |

Para contribuir com o kit (estrutura do repositório, testes, publicação), veja [CONTRIBUTING.md](CONTRIBUTING.md). Decisões de desenho em [docs/design.md](docs/design.md).
