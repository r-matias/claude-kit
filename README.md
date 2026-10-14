# claude-kit

Plugin do Claude Code que serve para qualquer stack (.NET, Node, Python, Go ou outro). Traz comandos de fluxo (spec, plano, execução, correção de bug), revisores independentes e guardas automáticos.
Cada projeto só declara os comandos do seu stack em `.claude/kit.json`; o resto é igual em todos.

O que você ganha:

- **Menos estrago.** Comandos destrutivos (`rm -rf` fora do projeto, `git push --force`, `DROP TABLE`) e escrita em segredos (`.env`, chaves) são barrados antes de rodar.
- **Turno só termina verde.** Quando o Claude mexe em código, build e testes rodam antes de ele dizer que acabou.
- **Feature com plano conferível.** SPEC → PLAN com tarefas testáveis → execução em etapas, com revisão de código e de segurança no fim.
- **Bug pela causa raiz.** Primeiro um teste que reproduz, depois a correção.

## Começar

Requisitos mínimos: Claude Code 2.1.295 ou mais novo, `git`, `bash` e `jq` (no Windows, o Git for Windows traz `git` e `bash`). Detalhes em [Requisitos e plataformas](#requisitos-e-plataformas).

O fluxo inteiro é: **instalar o plugin → `/kit:init` → `/kit:spec` → `/kit:plan` → `/kit:execute`**.

1. Instale o plugin, uma vez por máquina, no Claude Code:

   ```text
   /plugin marketplace add r-matias/claude-kit
   /plugin install kit@claude-kit
   ```

   Pelo terminal: `claude plugin marketplace add r-matias/claude-kit` e `claude plugin install kit@claude-kit`. Se o `/kit:init` não aparecer logo depois, reinicie a sessão.
2. Abra o Claude Code na raiz do repositório e rode `/kit:init`. É o único comando de configuração que você precisa conhecer.
3. Para cada feature: `/kit:spec` → `/clear` → `/kit:plan` → `/kit:execute` (ver [Fluxo do dia a dia](#fluxo-do-dia-a-dia)).

## O que o `/kit:init` faz

Em ordem, sem você chamar mais nada:

1. **Prepara a máquina**, se faltar algo: confere Claude Code, `git`, `bash` e `jq`, as regras de usuário do kit no `~/.claude/settings.json` e o marketplace. Faltando, roda os passos do `/kit:setup` (mostra o diff e só grava com sua confirmação). Se faltar dependência, mostra o comando de instalação do seu sistema e para.
2. **Configura o projeto** (o adaptador), descrito abaixo.
3. **Mapeia o código**, se o projeto tiver mais de 300 arquivos de código ou mais de um repositório: roda o `/kit:map` ao final, sem perguntar (só pergunta se passar de 30 agents).
4. **Rodado de novo** num projeto já configurado, entra em modo reparo: valida o `kit.json`, os comandos e o settings, propõe só o que falta e roda `/kit:map --update` se o mapa estiver desatualizado.

Na configuração do projeto:

- **Repositório sem configuração do Claude Code:** o init detecta o stack (manifestos, Makefile, CI) e propõe três arquivos:
  - `.claude/kit.json` com os comandos reais do projeto;
  - `.claude/settings.json`, que liga o plugin, libera os comandos do `kit.json` e pergunta antes de instalar dependência;
  - um `CLAUDE.md` curto.

  Ele mostra tudo e só grava após confirmação.
- **Repositório que já tem `.claude/`, `CLAUDE.md` ou `.mcp.json` (modo adotar):** o init faz o inventário de hooks, skills, agents e rules, aponta sobreposições com o kit e grava o relatório em `docs/claude-adoption.md`. A sua configuração fica como está (veja abaixo).

### O kit só soma, nunca altera sua configuração

Em nenhum comando (init, setup, map, reparo) o kit edita, mescla, desativa ou apaga um arquivo de Claude Code que já existe: `CLAUDE.md`, `.claude/settings.json`, `.claude/settings.local.json`, `.mcp.json`, `.claude/skills/`, `.claude/agents/`, `.claude/commands/`, `.claude/rules/` e hooks, nem o `~/.claude/settings.json`. Ele só cria arquivos novos dele.

- `CLAUDE.md` e `.claude/settings.json` que não existem podem ser criados (com sua confirmação).
- Se existem, o que o kit acrescentaria vai para `.claude/kit-settings.suggested.json` (ou `~/.claude/kit-settings.suggested.json`, no setup) e para o relatório final, com o diff. Você aplica se quiser.
- Uma skill, agent ou hook seu que faz o mesmo que o kit só aparece no relatório, com a sugestão de qual desativar e como (ex.: `Skill(kit:fix)` em `permissions.deny`).
- Os arquivos do próprio kit podem ser regravados: `.claude/kit.json`, `.claude/kit-settings.suggested.json`, `docs/claude-adoption.md` e os do mapa (`.claude/rules/map-*.md`, `.claude/rules/kit-codemap.md`, `docs/codemap.md`, com o cabeçalho `kit:map`).

Depois, revise e commite os arquivos criados (`.claude/kit.json`, `docs/claude-adoption.md`, `docs/codemap.md` e as rules do mapa). Quem clonar o repositório recebe a indicação do marketplace e do plugin pelo settings versionado; na própria máquina, basta rodar o `/kit:init`, que prepara o que faltar.

Na pasta-mãe de vários repositórios (cada um com seu `.git`), rode o `/kit:init` na pasta-mãe: ele configura cada repositório e as regras que cruzam repositórios.

## Fluxo do dia a dia

**Feature:** `/kit:spec` → `/clear` → `/kit:plan` → `/kit:execute`

1. `/kit:spec` entrevista você e grava `docs/specs/<slug>/SPEC.md` (objetivo, escopo, fora de escopo, como verificar).
   - `/kit:spec exportar o relatório de vendas em CSV`
   - `/kit:spec usuário pode trocar o e-mail com confirmação por link`
2. `/clear` limpa o contexto antes de planejar.
3. `/kit:plan` transforma a SPEC num `PLAN.md` com tarefas testáveis agrupadas em etapas (waves). Decide sozinho os detalhes técnicos e registra cada decisão no plano; só pergunta o que é decisão de produto. Um revisor confere o plano contra a SPEC antes de entregar.
   - `/kit:plan docs/specs/export-csv/SPEC.md`
   - `/kit:plan` (sem argumento: usa a SPEC mais recente)
4. `/kit:execute` implementa wave a wave, escreve os testes de cada tarefa e só marca uma tarefa como feita com evidência. Ao fim de cada wave revisa o diff; no fim do plano passa por revisão de código e de segurança. Para antes de qualquer ação irreversível (deploy, push, migração em banco real) e nunca commita sem você pedir.
   - `/kit:execute docs/specs/export-csv/PLAN.md`
   - `/kit:execute` (retoma o plano mais recente da primeira tarefa pendente; útil depois de um `/compact`)

**Épico** (algo grande demais para uma feature): `/kit:epic` quebra em fatias que entregam valor sozinhas e grava `docs/specs/<epico>/EPIC.md`; cada fatia vira uma feature.

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

| `/kit:setup` | Avançado: máquina nova sem projeto, ou reparo da máquina | `~/.claude/settings.json` (se não existir) ou `~/.claude/kit-settings.suggested.json` | Só manual |
| `/kit:map` | Avançado: mapear de novo, uma área ou só o que mudou | `.claude/rules/map-*.md`, `docs/codemap.md` | Só manual |

"Sozinho" quer dizer que o Claude pode escolher o comando ao reconhecer o pedido, sem você digitar a barra.

## Avançado

O `/kit:init` já chama os dois comandos abaixo quando precisa. Use-os sozinhos para preparar uma máquina sem abrir um projeto, reparar a máquina ou atualizar o mapa.

### `/kit:setup`

Prepara a máquina, uma vez por máquina:

- confere as dependências; se faltar alguma, mostra o comando de instalação do seu sistema (`winget`, `brew`, `apt` ou `claude update`) e para. Instale, reabra o Claude Code e rode de novo;
- detecta Windows nativo, WSL2, macOS ou Linux e ajusta o sandbox (no Windows nativo não há sandbox, e ele avisa);
- pergunta se o kit fica ligado em **todos os projetos** ou **só nos projetos que o habilitam** (nesse caso, `claude plugin list` mostra o kit como `disabled` no escopo `user`, e cada projeto o liga pelo próprio `.claude/settings.json`);
- sem `~/.claude/settings.json`, mostra o arquivo e só cria depois que você confirmar. Se ele já existe, não é alterado: o setup grava `~/.claude/kit-settings.suggested.json` só com o que somaria e mostra o diff.

Prefere configurar à mão? Mescle [`plugins/kit/templates/user-settings.json`](plugins/kit/templates/user-settings.json) no seu `~/.claude/settings.json` e, no Windows nativo, troque `sandbox.failIfUnavailable` para `false`.

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

## O kit bloqueou, e agora?

**Um guarda negou algo legítimo.** A mensagem diz o que foi barrado e por quê.
- Comando destrutivo de verdade necessário (ex.: `git reset --hard` de propósito): rode você mesmo, num terminal fora do Claude Code.
- Caminho protegido do projeto (`protected_paths`): a mensagem diz o que fazer em vez de editar, como o comando que regenera o arquivo. Se a proteção estiver errada, ajuste `protected_paths` no `.claude/kit.json`.

**O gate não deixa o turno terminar.** Ele mostra numa única mensagem tudo o que falhou: comando de build ou teste, chave de tradução faltando, arquivo acoplado não atualizado. O Claude tenta corrigir; se ainda falhar na tentativa seguinte, o turno termina e a falha fica visível para você. Se o comando de verificação estiver errado ou lento demais, ajuste `verify_on_stop` e `commands` no `.claude/kit.json`.

**Regra de acoplamento que não se aplica a esta mudança.** Grave uma linha de justificativa em `.claude/kit-skip` (ex.: `só renomeei uma variável na tela, o manual não muda`). Isso libera só os acoplamentos (`coupled_changes`), não build, testes nem tradução. O arquivo é apagado quando o gate passa e a justificativa fica registrada em `docs/claude-adoption.md` (ou `.claude/kit-skip.log`). Arquivo vazio não libera.

**"kit: jq não encontrado; instale o jq".** Sem `jq` os guardas bloqueiam toda chamada, de propósito: guarda que não consegue checar não deixa passar. Instale com `winget install jqlang.jq` (Windows), `brew install jq` (macOS) ou `sudo apt install jq` (Linux/WSL), reabra o Claude Code e rode `/kit:setup`.

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

O `/kit:init` propõe isso quando detecta testes de integração.

**Windows nativo sem sandbox.** O sandbox do Claude Code não existe no Windows nativo. O `/kit:setup` configura o kit para rodar sem ele: as regras de `permissions.deny` e os guardas continuam valendo, mas disco e rede não ficam isolados. Para ter sandbox, use o WSL2 e rode o `/kit:setup` lá. A ferramenta PowerShell fica desligada pelo setup porque os guardas não a cobrem. Quem precisar dela remove `"PowerShell"` de `permissions.deny` no `~/.claude/settings.json` e fica sem guarda nessa ferramenta.

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

As regras que o `/kit:setup` acrescentou ao `~/.claude/settings.json` (deny de segredos, sandbox) ficam; remova à mão se não quiser mais.

## Configuração do projeto (`.claude/kit.json`)

O `/kit:init` gera este arquivo. Todas as chaves são opcionais; chave ausente é pulada sem erro. Os comandos rodam na pasta do `.claude/`.

| Chave | Para que serve | Exemplo |
| --- | --- | --- |
| `commands` | Comandos do stack: `build`, `test`, `test_related`, `lint`, `typecheck`, `smoke`. `{files}` vira a lista de arquivos alterados | `"test_related": "npx vitest related {files} --run"` |
| `verify_on_stop` | Quais `commands` o gate roda ao fim do turno, em ordem | `["build", "test_related"]` |
| `source_globs` | Que arquivos contam como código (só eles disparam o gate) | `["src/**/*.ts"]` |
| `format` | Formatter por tipo de arquivo, rodado a cada edição | `{ "**/*.py": "ruff format {files}" }` |
| `protected_paths` | Caminhos que o Claude não edita, com mensagem do que fazer | `{ "glob": "src/generated/**", "message": "Gerado por npm run codegen." }` |
| `coupled_changes` | Arquivos que mudam juntos; `block` barra no fim do turno, `warn` só avisa | `{ "when": ["src/views/**"], "require": ["manual/**"], "message": "Atualize o manual." }` |
| `key_parity` | Arquivos de tradução que precisam ter as mesmas chaves | `{ "files": ["i18n/pt.json", "i18n/en.json"] }` |
| `plan_dirs` | Pastas extras onde o projeto guarda planos | `[".claude/plans"]` |
| `inject_plan_on_prompt` | Repete a linha do plano ativo a cada mensagem (custa contexto) | `false` |
| `repos` | Na pasta-mãe de vários repositórios, quais filhos considerar | `["app", "web"]` |
| `map` | Limites do `/kit:map`: `stale_after_commits` (50), `unit_max_files` (150), `unit_max_loc` (20000), `max_agents` (30), `primary` (repositório do codemap) | `{ "stale_after_commits": 100 }` |

Exemplo completo em [`plugins/kit/templates/kit.example.json`](plugins/kit/templates/kit.example.json); todas as regras (globs, monorepo, vários repositórios, `kit-skip`) em [docs/reference.md](docs/reference.md).

## Requisitos e plataformas

- **Claude Code ≥ 2.1.295.** Em versão anterior, um guarda que falha ou estoura o tempo deixa a ação passar. O `/kit:setup` para e o início da sessão avisa quando a versão é menor; corrija com `claude update`.

  | Recurso usado pelo kit | Desde | Efeito em versão anterior |
  | --- | --- | --- |
  | `onFailure: "block"` nos guardas | 2.1.295 | Guarda ausente ou quebrado deixa a ação passar |
  | Skill `verify` do projeto rodada antes de cada commit | 2.1.286 | O commit não roda a receita do `/verify` sozinho |
  | Auto mode como modo padrão | 2.1.283 (provedores terceiros ou sem telemetria); 2.1.284 (todos) | A sessão começa no modo default e pede mais confirmações |
  | `/skill-doctor` | 2.1.261 | Não existe; a rotina de poda usa só o `/doctor` |
  | `claude plugin validate` | 2.1.47 ou anterior (`/plugin validate` desde 2.0.12); 2.1.233 passou a checar `.claude/skills` | Sem validação de manifesto pela CLI |

  Fonte: [changelog oficial](https://code.claude.com/docs/en/changelog) e [referência de hooks](https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails).
- **`bash`, `git` e `jq`.** No Windows, Git for Windows (traz Git Bash) e `jq` no PATH.
- **Plataformas:**

  | Plataforma | Sandbox | Observação |
  | --- | --- | --- |
  | macOS | Sim | |
  | Linux | Sim | |
  | WSL2 | Sim | Recomendado no Windows |
  | Windows nativo | Não | O `/kit:setup` grava `failIfUnavailable: false`; valem só `permissions.deny` e os guardas |

Para contribuir com o kit (estrutura do repositório, testes, publicação), veja [CONTRIBUTING.md](CONTRIBUTING.md). Decisões de desenho em [docs/design.md](docs/design.md).
