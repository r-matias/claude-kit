# claude-kit

Plugin pessoal do Claude Code com o núcleo independente de stack: skills de fluxo, subagents e hooks. Cada projeto só declara os comandos do seu stack em `.claude/kit.json`; nada do núcleo muda entre .NET, Node, Python, Go ou outro.

O desenho detalhado do kit está documentado fora deste repositório. [`docs/design.md`](docs/design.md) resume os princípios, as camadas e a versão mínima; este README cobre instalação, uso e o comportamento de cada peça.

## Estrutura

```text
claude-kit/
├── .claude-plugin/marketplace.json     # este repo é o marketplace
├── plugins/kit/
│   ├── .claude-plugin/plugin.json
│   ├── skills/{init,spec,plan,execute,epic,fix,hunt}/SKILL.md
│   ├── skills/init/{adopt.md,stacks.md}  # modo adotar e referência de stacks
│   ├── skills/plan/template.md          # formato do PLAN.md
│   ├── agents/{investigator,code-reviewer,plan-reviewer,security-reviewer,test-writer}.md
│   ├── hooks/hooks.json
│   ├── scripts/{lib.sh,guard-bash.sh,guard-files.sh,format.sh,advise.sh,verify-gate.sh,session-context.sh,pre-compact.sh}
│   ├── scripts/{inventory.sh,merge-json.sh}   # apoio do /kit:init, não são hooks
│   └── templates/{kit.example.json,project-settings.json,CLAUDE.project.md}
├── templates/user-settings.json        # camada 1, aplicada à mão em ~/.claude
├── docs/design.md                      # princípios, camadas e versão mínima
└── tests/
    ├── run-tests.sh                    # fixtures dos hooks + scripts de apoio + checagens estáticas
    ├── run-adopt-test.sh               # aceite ao vivo do modo adotar (usa claude -p)
    ├── run-skills-live-test.sh         # aceite ao vivo do carregamento das skills e do deny de skill/agent
    ├── run-guards-live-test.sh         # aceite ao vivo do onFailure: guarda ausente bloqueia
    ├── run-plan-live-test.sh           # aceite ao vivo do /kit:plan: decide lacuna técnica, pergunta lacuna de produto
    ├── fixtures/*.json
    ├── sample/                         # projeto mínimo com kit.json de comandos true/false
    ├── plan/{repo,specs}/              # projeto mínimo e SPECs com lacuna técnica e de produto
    └── adopt/repo/                     # repo com .claude/ próprio (guardado como _claude/, _CLAUDE.md, _mcp.json)
```

## Requisitos

- **Claude Code ≥ 2.1.295** (necessário para `onFailure: "block"` nos guardas). Em versões anteriores o campo é ignorado: se o script de um guarda faltar, falhar ou estourar o tempo, a ação passa. O `session-context` avisa no início da sessão quando `claude --version` é menor que 2.1.295. O `plugin.json` não tem campo de versão mínima do Claude Code, então a exigência fica só documentada aqui e no aviso.

  | Recurso usado pelo kit | Desde | Efeito em versão anterior |
  | --- | --- | --- |
  | `onFailure: "block"` nos guardas | 2.1.295 | Guarda ausente ou quebrado deixa a ação passar |
  | Skill `verify` do projeto rodada antes de cada commit | 2.1.286 | O commit não roda a receita do `/verify` sozinho |
  | Auto mode como modo padrão | 2.1.283 (provedores terceiros ou sem telemetria); 2.1.284 (todos) | A sessão começa no modo default e pede mais confirmações |
  | `/skill-doctor` | 2.1.261 | Não existe; a rotina de poda usa só o `/doctor` |
  | `claude plugin validate` | 2.1.47 ou anterior (`/plugin validate` desde 2.0.12); 2.1.233 passou a checar `.claude/skills` | Sem validação de manifesto pela CLI |

  Fonte: [changelog oficial](https://code.claude.com/docs/en/changelog) e [referência de hooks](https://code.claude.com/docs/en/hooks#block-the-action-when-a-hook-fails).
- `bash`, `jq` e `git` (no Windows, Git Bash + `jq` no PATH). Sem `jq`, os guardas (`guard-bash`, `guard-files`) bloqueiam toda chamada com "kit: jq não encontrado; instale o jq"; os hooks de qualidade (`format`, `verify-gate`, `session-context`) saem com 0 sem fazer nada.
- **Windows nativo não tem sandbox.** O `templates/user-settings.json` usa `sandbox.failIfUnavailable: true`, e com isso o Claude Code se recusa a iniciar no Windows nativo. Escolha um dos dois:
  - usar o WSL2 (recomendado: mantém o sandbox); ou
  - remover `failIfUnavailable` da cópia em `~/.claude/settings.json` e aceitar rodar sem sandbox. Nesse caso, as regras de `permissions.deny` e os guardas do kit continuam valendo, mas não há isolamento de disco e rede.
- **Ferramenta PowerShell desligada.** Os guardas do kit cobrem só `Bash` e `Edit|Write|MultiEdit`; comandos da ferramenta PowerShell não passam por nenhum deles. Por isso o `templates/user-settings.json` tem `"PowerShell"` em `permissions.deny`, o que tira a ferramenta do contexto do Claude. Quem precisar do PowerShell remove essa linha da cópia em `~/.claude/settings.json` e fica sem guarda nessa ferramenta.

## Como usar

O plugin é instalado uma vez por máquina; em cada repositório ele só é ligado por uma linha versionada no `.claude/settings.json`, e o único arquivo de stack é o `kit.json`.

**Uma vez por máquina**

1. `/plugin marketplace add r-matias/claude-kit` e `/plugin install kit@claude-kit`.
2. Copiar `templates/user-settings.json` para `~/.claude/settings.json` (mesclando com o que já existir).

**Em cada repositório novo**

3. Abrir o Claude Code no repo e rodar `/kit:init`. Ele detecta o stack e propõe `kit.json`, `.claude/settings.json` (liga o plugin, allow-list, domínios) e um CLAUDE.md curto. Se o repo já tem `.claude/`, `CLAUDE.md` ou `.mcp.json`, entra no [modo adotar](#modo-adotar).
4. Revisar, ajustar e commitar. Quem clonar o repo, ou você em outra máquina, recebe a indicação do marketplace e do plugin pelo settings versionado.

**No dia a dia**

- Feature: `/kit:spec` → `/clear` → `/kit:plan` → `/kit:execute`
  - O `/kit:plan` não pede revisão do plano. Lacuna técnica (nome de campo, parâmetro, flag, pasta, biblioteca já prevista) ele decide pelo padrão mais simples coerente com os docs, registra em "Decisões" do PLAN.md com data, origem e motivo e atualiza o doc de referência quando houver. Ele só pergunta em decisão de produto (o que o usuário vê, regra de negócio), escopo fora da SPEC ou decisão cara de reverter (schema público, contrato de API, dependência nova). Antes de entregar, o `kit:plan-reviewer` confere o plano contra a SPEC e a skill corrige o que ele apontar; você recebe um resumo de até 5 linhas.
  - O PLAN.md ([template](plugins/kit/skills/plan/template.md)) é derivado de trás para frente: `must_haves` no topo (truths verificáveis, artifacts com o que cada arquivo provê, tests com o que cada teste cobre), depois `Interfaces` com assinaturas, rotas, schemas e códigos de erro exatos. As tarefas ficam agrupadas em waves por dependência, com a linha `Paralelo:` dizendo quais podem rodar ao mesmo tempo, e cada uma tem `files`, `behavior` (cada linha vira teste), `action` (com o molde `arquivo:linha`), `verify` (chave do `kit.json`) e `done` (assertiva testável). Toda wave termina num checkpoint. A wave final é fixa: revisão pelo `kit:code-reviewer` e pelo `kit:security-reviewer`, correção de BLOCKER/MAJOR com nova revisão, verificação ponta a ponta da SPEC e `smoke` se o `kit.json` tiver. Só tarefas, checkpoints e passos da wave final levam caixa `- [ ]`, que é o que os hooks contam como progresso.
  - O `/kit:execute` segue as waves (delegando as tarefas paralelas a subagents), só marca `[x]` com o `done` comprovado e, em cada checkpoint, re-roda os `verify` da wave, confere os `done` e avalia o contexto: acima de ~70%, para e recomenda `/compact` seguido de `/kit:execute`, que retoma da próxima caixa. Plano no formato antigo (sem waves) roda tarefa a tarefa.
  - O `/kit:execute` segue a mesma regra para decisões que surgem na execução e também para antes de ação irreversível (deploy, push, chamada a serviço externo real, migração em banco real).
- Épico: `/kit:epic`; cada fatia vira uma feature
- Bug conhecido: `/kit:fix <issue>`
- Falha sem causa clara: `/kit:hunt`, depois `/kit:fix`
- Hooks e revisores rodam sozinhos: bloqueiam o perigoso, formatam e só deixam o turno terminar com build e testes verdes.

**Para evoluir**

- Editar o repo `claude-kit`, push, e `/plugin update kit` em cada máquina. Todos os projetos recebem a mudança; nenhum arquivo é copiado entre repositórios.
- Mudar a versão em `plugin.json` a cada release ajuda a saber qual versão cada máquina usa.

## O contrato `.claude/kit.json`

```json
{
  "commands": {
    "build": "dotnet build --nologo -v q",
    "test": "dotnet test --nologo",
    "test_related": "dotnet test --nologo --filter {files}",
    "lint": "npm run lint --prefix frontend",
    "typecheck": "npx tsc --noEmit -p frontend",
    "smoke": "bash scripts/smoke.sh"
  },
  "format": {
    "**/*.cs": "dotnet format --include {files}",
    "**/*.{ts,html,scss}": "npx prettier --write {files}"
  },
  "protected_paths": [
    "**/Migrations/**",
    { "glob": "web/src/i18n/generated/**",
      "message": "Gerado por npm run sync-strings. Edite em app/src/locales/ e rode o sync." },
    { "glob": "**/*.db*", "message": "Banco local. Use a CLI de admin.", "write": "deny" }
  ],
  "verify_on_stop": ["build", "test_related"],
  "source_globs": ["**/*.cs", "**/*.ts"],
  "coupled_changes": [
    { "when": ["src/views/**", "src/widgets/**"],
      "require": ["manual/**"],
      "level": "block",
      "message": "Telas mudaram; atualize o manual para refletir as telas atuais.",
      "hint": "o manual de cada tela fica em manual/<tela>.md" },
    { "when": ["api/src/**"], "require": ["web/src/pages/**"],
      "level": "warn", "message": "Se o formato da resposta mudou, ajuste os fetch do site." }
  ],
  "key_parity": [
    { "files": ["strings/pt.json", "strings/en.json", "strings/es.json"],
      "message": "Textos precisam existir nas 3 línguas." }
  ],
  "plan_dirs": [".claude/plans"],
  "inject_plan_on_prompt": false
}
```

- Comandos rodam com `bash -c` na pasta que contém o `.claude/` do `kit.json`.
- `smoke` é opcional e só o `/kit:execute` usa, no último passo da wave final do plano.
- `{files}` vira a lista de caminhos relativos, cada um entre aspas simples.
- Globs aceitam `**`, `*`, `?` e `{a,b}`, relativos à raiz do `kit.json`. Glob sem `/` também casa pelo nome do arquivo.
- Chaves ausentes são puladas sem erro. Monorepo: um `kit.json` por pacote; os hooks usam o mais próximo do arquivo.
- Valores de partida por stack: `plugins/kit/skills/init/stacks.md`.

### `protected_paths`

Cada item é uma string (glob) ou um objeto `{ "glob", "message", "write" }`.
- `message` substitui o texto genérico da negação. Use para dizer o que fazer em vez de editar.
- `write`: `"allow"` (padrão: arquivo novo pode ser criado ali) ou `"deny"` (nem criar). Útil para binários, bancos e artefatos.
- Edit, e Write sobre arquivo existente, são sempre negados para um caminho protegido. Strings continuam com o comportamento da v0.1.0.

### Planos ativos

O `session-context` e o `pre-compact` mostram até 3 planos ativos com a contagem "feitas/total" e as tarefas pendentes do mais recente. Plano ativo é um `docs/specs/**/PLAN.md` (na raiz da sessão ou em qualquer repositório dela), ou um `.md` dos diretórios de `plan_dirs`, modificado nos últimos 14 dias e com tarefa `- [ ]` pendente. Com `"inject_plan_on_prompt": true`, a linha de planos ativos entra também em cada mensagem (UserPromptSubmit); custa contexto a cada turno, então fica desligado por padrão.

### Checks de domínio (opcionais)

Avaliados pelo `verify-gate` sobre os arquivos alterados (diff contra HEAD + não rastreados). Projeto que não declara as chaves não é afetado.

- **`coupled_changes`**: cada regra tem um `level`.
  - `"block"` (padrão): no Stop, se algum arquivo alterado casa um glob de `when` e nenhum casa `require`, o gate bloqueia com `message`, a lista dos arquivos que dispararam a regra e o `hint`, se houver.
  - `"warn"`: o `verify-gate` ignora a regra. Na edição (PostToolUse) de um arquivo que casa `when`, o `advise.sh` injeta no contexto do Claude `[kit] <message> | verificar: <require> | editado: <arquivo> | dica: <hint>`, como fato e não como ordem. Não bloqueia nada e aparece uma vez por arquivo por sessão.
- **`key_parity`**: só roda se algum dos `files` mudou. Achata as chaves aninhadas com `.` e lista cada chave ausente e em quais arquivos (`home.welcome falta em en.json, es.json`). Arquivo listado inexistente ou JSON inválido também é falha. Quando dois arquivos têm o mesmo nome (`pt/common.json`, `en/common.json`), o rótulo é o caminho declarado.
- **Válvula de escape**: `.claude/kit-skip` com uma linha de justificativa libera `coupled_changes` (não libera `key_parity` nem os comandos). Quando o gate passa, o arquivo é apagado e a justificativa vai para a seção "Registro de kit-skip" de `docs/claude-adoption.md`, ou para `.claude/kit-skip.log` se aquele não existir. Se outra checagem falhar no mesmo turno, o `kit-skip` é mantido até o gate passar. Arquivo vazio não libera.
- **Ordem**: comandos de `verify_on_stop`, depois `key_parity`, depois `coupled_changes`. Todas as falhas do turno saem numa única mensagem numerada.

### Workspace com vários repositórios

Numa pasta-mãe com repositórios filhos independentes (ex.: `workspace/` com `app/` e `web/`, cada um com seu `.git`), abra a sessão na pasta-mãe. Os hooks descobrem os repositórios:
- o repositório do próprio `cwd`, se houver;
- os filhos: diretórios com `.git` (pasta ou arquivo) até 3 níveis, ignorando `node_modules`, `target`, `dist`, `build`, `vendor`, `.venv` e o que o `.gitignore` do pai ignorar;
- ou só os listados em `"repos": ["app", "web"]` no `kit.json` da pasta-mãe, que tem prioridade sobre a descoberta.

A descoberta tem cache por sessão em `$TMPDIR`, invalidado quando o `kit.json` da pasta-mãe muda.

- **`verify-gate`**: coleta os alterados de cada repositório, agrupa pelo `kit.json` mais próximo e roda as checagens de cada grupo. A mensagem única cita o repositório em cada item (`[app] 'test_related' falhou ...`).
- **Regras entre repositórios**: `coupled_changes` e `key_parity` do `kit.json` da pasta-mãe enxergam os alterados de todos os filhos, com caminho relativo à pasta-mãe (`app/src/types.rs` → `web/src/types.ts`). O mesmo vale para `protected_paths` e para as regras `warn` da pasta-mãe.
- **Busca do `kit.json`**: sobe do arquivo até o primeiro `.git`; se esse `.git` é de um filho da pasta da sessão, continua subindo até a pasta da sessão, nunca acima dela.
- **`session-context`**: branch e alterados de cada repositório, até 15 linhas por repositório.
- Repositório único: comportamento idêntico ao da v0.1.0.

## Modo adotar

Quando o repositório já tem configuração do Claude Code, o `/kit:init` entra somando: nada existente é apagado ou sobrescrito sozinho, e uma peça só é removida depois que o equivalente do kit provar que faz o mesmo e você confirmar. Detalhes em `plugins/kit/skills/init/adopt.md`.

1. **Inventário** com `scripts/inventory.sh`: hooks de todos os settings (projeto, local, usuário), skills, commands, agents, rules, CLAUDE.md e MCP.
2. **Classificação** de cada peça: manter no projeto, substituir pelo kit, virar declaração no `kit.json` (`coupled_changes`/`key_parity`), promover ao kit ou somar. Sobreposições (dois hooks bloqueando o mesmo, duas skills de review) ganham uma peça dona.
3. **Prova de equivalência** antes de remover: o mesmo cenário passa pelo hook original e pelo do kit (ou pelo `verify-gate` num worktree descartável) e precisa dar o mesmo bloqueio.
4. **Adições** com merge chave a chave via `scripts/merge-json.sh` (arrays por união, valor existente vence, conflitos reportados) e conferência com `merge-json.sh --check` (só adições).
5. **Remoção** só com confirmação explícita na conversa, um commit por peça. Respostas pré-aprovadas no argumento (`/kit:init <respostas>`) valem para adições, nunca para remoções.
6. **Relatório** em `docs/claude-adoption.md`: peça, destino, prova e status.

O inventário também detecta, com uma recomendação para cada item:
- **Sobreposição de skills e agents** com os do kit. Se a skill do projeto tem `disable-model-invocation: true` e a do kit não, o Claude escolhe sozinho a do kit (ex.: `kit:fix` para "corrige esse bug"). Recomendação: a peça do projeto é a dona, e entram `Skill(kit:<nome>)` ou `Agent(kit:<nome>)` em `permissions.deny` do projeto.
- **Aviso possivelmente mudo**: hook PreToolUse, PostToolUse ou Stop que imprime texto no stdout sem JSON `additionalContext`; com exit 0 esse texto não chega ao Claude.
- **Falha aberta**: hook PreToolUse com `jq ... || exit 0`, que libera tudo sem jq.
- **Outros riscos**, só listados: skill com efeito colateral sem `disable-model-invocation`, `settings.local.json` versionado, regra com a sintaxe antiga `:*` e ausência de deny de leitura para segredos.

Listas de bloqueio do projeto viram `protected_paths` em forma de objeto, com a mesma mensagem que o hook original mostrava.

Regras de escrita do init, inclusive em repo novo: mesclar JSON chave a chave, nunca sobrescrever settings, hooks, skills, agents ou CLAUDE.md existentes, mostrar o diff e só gravar após confirmação.

## Hooks

| Script | Evento | O que faz |
| --- | --- | --- |
| `guard-bash.sh` | PreToolUse `Bash` | Nega `rm -rf` fora do projeto ou em `/`, `~`, `..`, variáveis não resolvíveis; `git push --force`/`-f`/`+refspec`; `git reset --hard`; `git clean -fdx` (dry-run liberado); `DROP DATABASE/TABLE/SCHEMA`, `TRUNCATE` SQL; `curl`/`wget` com pipe para shell; `chmod -R 777`; `mkfs`; `dd of=/dev/*` (exceto `/dev/null`). Analisa também o conteúdo de `sh -c`, `bash -c`, `$()` e cadeias com `&&`, `;`, `\|`. |
| `guard-files.sh` | PreToolUse `Edit\|Write` | Nega escrita em `.env*` (exceto `.env.example/.sample/.template/.dist`), `*.pem`, `*.key`, `secrets/`. Nega Edit, e Write sobre arquivo existente, em `protected_paths` do `kit.json` mais próximo e dos `kit.json` acima dele até a pasta da sessão; Write de arquivo novo só é negado em item com `"write": "deny"`. Item com `message` usa esse texto na negação. |
| `format.sh` | PostToolUse `Edit\|Write` | Roda o formatter do primeiro glob de `format` que casa. Falha: exit 2 com as últimas 30 linhas. |
| `advise.sh` | PostToolUse `Edit\|Write` | Regras `coupled_changes` com `level: "warn"` cujo `when` casa com o arquivo editado viram `additionalContext` (JSON, porque stdout puro de PostToolUse não chega ao Claude). Uma vez por arquivo por sessão. Nunca bloqueia. |
| `verify-gate.sh` | Stop | Em cada repositório da sessão, se algum arquivo alterado (diff contra HEAD + não rastreados) casa `source_globs`, roda `verify_on_stop` em ordem até a primeira falha (últimas 60 linhas). Depois avalia `key_parity` e `coupled_changes` com `level: "block"`. Todas as falhas saem numa única mensagem com exit 2. Respeita `stop_hook_active`. Comandos já verificados com sucesso no mesmo estado não rodam de novo (marca em `.git/kit-verify-*`). |
| `session-context.sh` | SessionStart (`startup\|resume\|compact\|fork`) | Injeta branch e `git status --short` de cada repositório, os planos ativos e as tarefas pendentes do mais recente. Na origem `compact`, inclui o snapshot do `pre-compact` se ele tiver menos de 2 horas. |
| `session-context.sh --plan-only` | UserPromptSubmit | Só a linha de planos ativos, e só se `inject_plan_on_prompt` for `true`; caso contrário não imprime nada. |
| `pre-compact.sh` | PreCompact | Grava `<raiz>/.claude/state/kit-snapshot.md` com data, branch, modificados e staged (até 20 cada) de cada repositório e os planos ativos. Sempre exit 0: nunca bloqueia a compactação. Adicione `.claude/state/` ao `.gitignore` (o `/kit:init` propõe). |

Sem `jq`, os guardas bloqueiam e os demais hooks saem com 0 sem fazer nada.

Os guardas devolvem `permissionDecision: "deny"` com o motivo; Claude recebe o motivo e ajusta. Com `onFailure: "block"` (Claude Code 2.1.295+), um guarda que não consegue rodar também bloqueia: script ausente, saída com código diferente de 0 e 2, timeout ou JSON inválido. No `Stop` o campo não tem efeito, segundo a doc oficial.

Os hooks usam a forma shell com `"shell": "bash"` explícito (`"command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh\""`, sem `args`). Na forma exec (`command` + `args`) o Claude Code procura `bash` no PATH, e no Windows isso falha com `Executable not found in $PATH: "bash"` quando o `Git\bin` não está no PATH; com `onFailure: "block"`, todo Bash/Edit/Write ficaria bloqueado. Na forma shell, o Windows roda o comando pelo Git Bash que o Claude Code localiza (o mesmo da ferramenta Bash; se não achar, `CLAUDE_CODE_GIT_BASH_PATH`), e o `bash` dentro da string é resolvido pelo PATH que o Git Bash monta.

## Testes

```bash
bash tests/run-tests.sh            # todos
bash tests/run-tests.sh "rm -rf"   # filtra por nome do caso
KIT_TEST_DEBUG=1 bash tests/run-tests.sh "<caso>"   # mostra input, stdout e stderr
```

Cada caso monta um workspace novo a partir de `tests/sample/` (repo git com `kit.json` de comandos `true`/`false`), grava os arquivos de base (`files`), faz commit, aplica as mudanças do turno (`change`, `edit`, `touch` para envelhecer arquivos), passa o JSON do hook pelo script e confere decisão, motivo (`reason`), exit code, stdout e stderr (conteúdo e ordem), JSON de saída (`json_check`), execução repetida (`repeat_empty`) e arquivos depois do hook (`after`). Com `workspace.repos`, o caso roda numa pasta-mãe sem git com repositórios filhos. Cada caso tem `session_id` e `TMPDIR` próprios. Fixtures podem declarar `defaults` mesclados em cada caso. Também testa `merge-json.sh` e `inventory.sh`, a ordem de seções e campos do template do PLAN.md e que só tarefas, checkpoints e passos da wave final têm caixa, confere que todo hook do `hooks.json` está em forma shell e, no Windows, roda cada um pelo `bash.exe` do Git com um PATH sem nenhum `bash` (o caso que quebrava a forma exec), checa que nenhum script referencia comando de stack, que todos os JSON são válidos e roda `claude plugin validate` no plugin e no marketplace.

```bash
bash tests/run-adopt-test.sh [--keep]   # aceite ao vivo do modo adotar
bash tests/run-skills-live-test.sh      # skills carregam sem commits e fora de repo git; deny de skill/agent do kit
bash tests/run-guards-live-test.sh      # guarda ausente bloqueia (onFailure), com controle e contraprova
bash tests/run-plan-live-test.sh [--keep]   # /kit:plan decide lacuna técnica e pergunta lacuna de produto
```

Copia `tests/adopt/repo/` (que tem hooks, skills, agent, rule, CLAUDE.md e MCP próprios) para uma pasta temporária, roda `/kit:init` com respostas pré-aprovadas via `claude -p --plugin-dir` e confere: nenhum arquivo removido, nenhum commit criado, JSON existentes só com adições (`merge-json.sh --check`), demais arquivos sem linhas removidas, `docs/claude-adoption.md` cobrindo todas as peças e recomendando `Skill(kit:fix)` em deny (com o motivo), aviso mudo e falha aberta marcados, `kit.json` com `key_parity`, `coupled_changes` e a lista de bloqueio convertida em `protected_paths` com mensagem, plugin habilitado e hook original ainda registrado. Leva alguns minutos e consome uma sessão do Claude Code. Roda com `--setting-sources project,local` para não disparar hooks pessoais do `~/.claude`.

O `run-guards-live-test.sh` exige Claude Code ≥ 2.1.295. Ele apaga o script de um guarda numa cópia do plugin e confere no disco que o comando (Bash) ou a escrita (Write) que criaria um arquivo-sonda não aconteceu. O controle, com o script presente, cria a sonda. A contraprova, com o script ausente e sem `onFailure`, também cria, o que mostra que o bloqueio vem do campo.

O `run-plan-live-test.sh` copia `tests/plan/repo/` com uma SPEC de `tests/plan/specs/` e roda `/kit:plan` via `claude -p`. Com a SPEC de lacuna técnica (último login), confere o formato do PLAN.md (seções na ordem, cada tarefa com `files`/`behavior`/`action`/`verify`/`done`, cada wave com `Paralelo:` e checkpoint, wave final F1 a F3 sem smoke porque a fixture não tem, caixa só onde deve, `lastLoginAt` em Interfaces) e Decisões com data, origem `kit` e motivo, sem `AskUserQuestion`, com o `kit:plan-reviewer` chamado, `docs/data-model.md` atualizado, nenhum código de produção alterado e resumo curto. Com a SPEC de lacuna de produto (bloqueio sem limite de tentativas definido), confere que a skill pergunta sobre o limite e não grava o PLAN.md. Como `claude -p` não tem usuário, vale a chamada ao `AskUserQuestion` ou a pergunta no texto final.

A fixture guarda a configuração como `_claude/`, `_CLAUDE.md` e `_mcp.json` para o próprio Claude Code não carregar as skills e o CLAUDE.md de teste quando você trabalha no repo do kit.

Para testar o plugin ao vivo sem instalar: `claude --plugin-dir ./plugins/kit`.

## Observações de plataforma

- Windows nativo e sandbox: ver [Requisitos](#requisitos).
- Comando `!` de skill que falha impede a skill de carregar. Todo `!` de git termina com `2>/dev/null || echo "(sem commits)"` ou `|| echo "(não é repo git)"`, e `!` não pode conter variável de ambiente (falha na checagem de permissão).
- Os scripts precisam de fim de linha LF; o `.gitattributes` do repo garante isso no clone.
