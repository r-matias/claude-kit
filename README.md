# claude-kit

Plugin do Claude Code que serve para qualquer stack (.NET, Node, Python, Go ou outro). Traz comandos de fluxo (spec, plano, execução, correção de bug), revisores independentes e guardas automáticos.
Cada projeto só declara os comandos do seu stack em `.claude/kit.json`; o resto é igual em todos.

O que você ganha:

- **Menos estrago.** Comandos destrutivos (`rm -rf` fora do projeto, `git push --force`, `DROP TABLE`) e escrita em segredos (`.env`, chaves) são barrados antes de rodar.
- **Turno só termina verde.** Quando o Claude mexe em código, build e testes rodam antes de ele dizer que acabou.
- **Feature com plano conferível.** SPEC → PLAN com tarefas testáveis → execução em etapas, com revisão de código e de segurança no fim.
- **Bug pela causa raiz.** Primeiro um teste que reproduz, depois a correção.

## Primeiro uso

Requisitos mínimos: Claude Code 2.1.295 ou mais novo, `git`, `bash` e `jq` (no Windows, o Git for Windows traz `git` e `bash`). Detalhes em [Requisitos e plataformas](#requisitos-e-plataformas).

No Claude Code, uma vez por máquina:

```text
/plugin marketplace add r-matias/claude-kit
/plugin install kit@claude-kit
/kit:setup
```

Pelo terminal, os dois primeiros passos também funcionam assim: `claude plugin marketplace add r-matias/claude-kit` e `claude plugin install kit@claude-kit`. O `/kit:setup` roda dentro do Claude Code; se ele não aparecer logo depois do install, reinicie a sessão.

O `/kit:setup`:

- confere as dependências; se faltar alguma, mostra o comando de instalação do seu sistema (`winget`, `brew`, `apt` ou `claude update`) e para. Instale, reabra o Claude Code e rode `/kit:setup` de novo;
- detecta Windows nativo, WSL2, macOS ou Linux e ajusta o sandbox (no Windows nativo não há sandbox, e ele avisa);
- pergunta se o kit fica ligado em **todos os projetos** ou **só nos projetos que o habilitam** (nesse caso, `claude plugin list` mostra o kit como `disabled` no escopo `user`, e cada projeto o liga pelo próprio `.claude/settings.json`);
- mostra o diff do seu `~/.claude/settings.json` e só grava depois que você confirmar. Nada que já existe é removido.

Prefere configurar à mão? Mescle [`plugins/kit/templates/user-settings.json`](plugins/kit/templates/user-settings.json) no seu `~/.claude/settings.json` e, no Windows nativo, troque `sandbox.failIfUnavailable` para `false`.

## Ligar num projeto

Abra o Claude Code na raiz do repositório e rode:

```text
/kit:init
```

- **Repositório sem configuração do Claude Code:** o init detecta o stack (manifestos, Makefile, CI) e propõe três arquivos:
  - `.claude/kit.json` com os comandos reais do projeto;
  - `.claude/settings.json`, que liga o plugin, libera os comandos do `kit.json` e pergunta antes de instalar dependência;
  - um `CLAUDE.md` curto.

  Ele mostra tudo e só grava após confirmação.
- **Repositório que já tem `.claude/`, `CLAUDE.md` ou `.mcp.json` (modo adotar):** o init soma em vez de substituir.
  - Faz o inventário de hooks, skills, agents e rules existentes e aponta sobreposições com o kit.
  - Mescla os JSON chave a chave e nunca apaga nada sozinho. Uma peça existente só sai depois de provar que o kit faz o mesmo e de você confirmar, um commit por peça.
  - O relatório fica em `docs/claude-adoption.md`.

Depois, revise e commite `.claude/` e `CLAUDE.md`. Quem clonar o repositório recebe a indicação do marketplace e do plugin pelo settings versionado; só precisa fazer o [Primeiro uso](#primeiro-uso) na própria máquina.

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
| `/kit:setup` | Uma vez por máquina, ou quando o início da sessão avisar que falta dependência | `~/.claude/settings.json` mesclado | Só manual |
| `/kit:init` | Uma vez por repositório | `.claude/kit.json`, `.claude/settings.json`, `CLAUDE.md` (e `docs/claude-adoption.md` no modo adotar) | Só manual |
| `/kit:spec` | Começo de uma feature sem especificação | `docs/specs/<slug>/SPEC.md` | Manual ou sozinho, quando você descreve uma feature nova |
| `/kit:plan` | SPEC pronta | `PLAN.md` ao lado da SPEC | Manual ou sozinho, quando há uma SPEC para planejar |
| `/kit:execute` | Plano pronto | Código e testes; caixas do `PLAN.md` marcadas com evidência | Só manual |
| `/kit:epic` | Trabalho grande, várias entregas | `docs/specs/<epico>/EPIC.md` | Só manual |
| `/kit:fix` | Bug com sintoma claro ou teste falhando | Teste que reproduz + correção | Manual ou sozinho, quando você relata um bug |
| `/kit:hunt` | Falha intermitente, lentidão, causa desconhecida | Hipóteses com evidência, sem editar código | Manual ou sozinho, quando você relata uma falha vaga |

"Sozinho" quer dizer que o Claude pode escolher o comando ao reconhecer o pedido, sem você digitar a barra.

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
- **Contexto da sessão.** No início de cada sessão o Claude recebe a branch, os arquivos alterados e as tarefas pendentes do plano ativo. Antes de uma compactação, o kit salva esse estado e o devolve depois. Se faltar `jq` ou `git`, ou se o Claude Code estiver desatualizado, o aviso aparece aqui, com o comando para corrigir.

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
