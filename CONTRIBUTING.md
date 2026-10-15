# Contribuindo com o claude-kit

Para quem mantém o kit. Uso e instalação estão no [README](README.md); o comportamento detalhado em [docs/reference.md](docs/reference.md) e as decisões em [docs/design.md](docs/design.md).

## Estrutura

```text
claude-kit/
├── .claude-plugin/marketplace.json     # este repo é o marketplace
├── plugins/kit/
│   ├── .claude-plugin/plugin.json
│   ├── skills/{setup,init,map,spec,plan,execute,epic,fix,hunt}/SKILL.md
│   ├── skills/init/{adopt.md,stacks.md}  # modo adotar e referência de stacks
│   ├── skills/plan/template.md          # formato do PLAN.md
│   ├── skills/map/output.md             # formato das rules e do codemap gerados
│   ├── agents/{investigator,code-reviewer,plan-reviewer,security-reviewer,test-writer,mapper,map-verifier}.md
│   ├── hooks/hooks.json
│   ├── scripts/{lib.sh,guard-bash.sh,guard-files.sh,format.sh,advise.sh,verify-gate.sh,session-context.sh,pre-compact.sh}
│   ├── scripts/{inventory.sh,merge-json.sh}   # apoio do /kit:init, não são hooks
│   ├── scripts/setup.sh                 # apoio do /kit:setup e do /kit:init: dependências, plataforma, grupos de permissão, guards, LSP e planos parados
│   ├── scripts/map-partition.sh         # apoio do /kit:map e do /kit:init: unidades de mapeamento e estado do codemap
│   ├── scripts/wave-base.sh             # apoio do /kit:execute: base do diff de cada wave
│   ├── templates/{kit.example.json,project-settings.json,CLAUDE.project.md}
│   ├── templates/project-permissions.json # grupos de permissão que o /kit:init oferece ao projeto
│   └── templates/lsp-plugins.txt        # plugin LSP oficial, binário e instalação por linguagem (setup.sh lsp)
├── README.md                           # para quem usa o kit
├── CONTRIBUTING.md                     # para quem mantém o kit
├── docs/design.md                      # princípios, camadas e decisões
├── docs/reference.md                   # kit.json completo, hooks, plan/execute, modo adotar
└── tests/
    ├── run-tests.sh                    # fixtures dos hooks + scripts de apoio + checagens estáticas (paralelo, --changed)
    ├── run-adopt-test.sh               # aceite ao vivo do modo adotar e do deny de curl/wget (usa claude -p)
    ├── run-skills-live-test.sh         # aceite ao vivo do carregamento das skills e do deny de skill/agent
    ├── run-guards-live-test.sh         # aceite ao vivo do onFailure: guarda ausente bloqueia
    ├── run-plan-live-test.sh           # aceite ao vivo do /kit:plan e do tamanho do /kit:spec: lacunas, plano e spec grandes
    ├── run-execute-live-test.sh        # aceite ao vivo do /kit:execute: waves, paralelo, checkpoint com revisão
    ├── run-reviewers-live-test.sh      # calibração ao vivo dos revisores: id e severidade certos, aprovado/reprovado
    ├── fixtures/*.json
    ├── sample/                         # projeto mínimo com kit.json de comandos true/false
    ├── plan/{repo,specs}/              # projeto mínimo e SPECs com lacuna técnica e de produto
    ├── execute/                        # projeto com PLAN.md de 2 waves e teste de aceite independente
    ├── reviewers/{repo,plans,diffs}/   # SPEC com migração, plano e diff limpos e com defeitos plantados
    └── adopt/repo/                     # repo com .claude/ próprio (guardado como _claude/, _CLAUDE.md, _mcp.json)
```

## Testes

```bash
bash tests/run-tests.sh            # todos, em paralelo
bash tests/run-tests.sh --changed  # só os grupos afetados pelo que mudou desde HEAD, mais as estáticas
bash tests/run-tests.sh --jobs 1   # serial, com a saída de cada grupo na hora
bash tests/run-tests.sh "rm -rf"   # filtra por nome do caso
KIT_TEST_DEBUG=1 bash tests/run-tests.sh "<caso>"   # mostra input, stdout e stderr
bash tests/run-tests.sh guard-bash.sh   # o filtro também casa o nome do script da fixture
bash tests/run-tests.sh --awk mawk # roda com o mawk (awk do Debian/Ubuntu) no lugar do awk; pula se nao houver
bash tests/run-tests.sh --bash /bin/bash   # no macOS, roda os scripts com o bash 3.2 do sistema
```

Durante o desenvolvimento, use `--changed`; antes de commit e push, a suíte inteira. O `--changed` olha `git diff HEAD` e os não rastreados: cada script leva às fixtures dele e aos grupos que o chamam (um hook também leva a "sem jq" e "forma shell"; `merge-json.sh` leva a init e setup; templates levam a setup), cada fixture ao próprio grupo, e `lib.sh`, `tests/sample/` ou o próprio runner levam à suíte inteira. Docs, skills e agents só rodam as estáticas. Os mesmos testes rodam no GitHub Actions (`.github/workflows/tests.yml`) a cada push e PR, em `ubuntu-latest` e `windows-latest`.

Como a suíte é rápida: os grupos (fixtures em fatias de 15 casos, sem jq, forma shell, init, wave-base, map-partition, setup, guardas, estáticas) são independentes e rodam em paralelo (`--jobs`, padrão o número de CPUs até 8), cada um com seu diretório temporário, e a saída sai na ordem no final. Cada caso copia um repositório-modelo já commitado (sample e nokit) em vez de `git init` + `add` + `commit`, e só refaz o commit quando o caso muda arquivos de base. Os campos de cada caso saem de uma única chamada de `jq`. O git dos repositórios de teste roda sem a config do sistema e do usuário (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL` num arquivo do runner com `core.autocrlf=false`, `core.fsmonitor=false`, `core.fscache=true`, `gc.auto=0` e template de init vazio). No Windows, criar processo é caro; é isso que deixava a suíte em 20+ minutos.

Bash mínimo: 3.2. Sem arrays associativos, `mapfile`/`readarray`, `${x,,}`, `local -n` nem `[[ -v ]]`; expansão de array sempre como `${a[@]+"${a[@]}"}` (no bash < 4.4 com `set -u`, `"${a[@]}"` de array vazio aborta); nada de `realpath` nem `readlink -f`. As checagens estáticas da suíte acusam esses usos. Os guardas chamam `kit_guard_fail_closed`: qualquer saída inesperada vira exit 2.

Os scripts usam só awk POSIX. Em especial, não escreva `X[k] = (k in X) ? ... : ...`: no mawk o lado esquerdo cria a chave antes do teste. Use `if (k in X) ...; else ...`.

Cada caso monta um workspace novo a partir de `tests/sample/` (repo git com `kit.json` de comandos `true`/`false`), grava os arquivos de base (`files`), faz commit, aplica as mudanças do turno (`change`, `edit`, `touch` para envelhecer arquivos), passa o JSON do hook pelo script e confere decisão, motivo (`reason`), exit code, stdout e stderr (conteúdo e ordem), JSON de saída (`json_check`), execução repetida (`repeat_empty`) e arquivos depois do hook (`after`). Com `workspace.repos`, o caso roda numa pasta-mãe sem git com repositórios filhos. Cada caso tem `session_id` e `TMPDIR` próprios. Fixtures podem declarar `defaults` mesclados em cada caso. Também testa `merge-json.sh` (`--preview`, `--apply` com backup, só adições, `hooks` intocados, `settings.local.json` recusado, deny que sombrearia `allow`/`ask` não aplicado com a linha de conflito, deny sem sombra aplicado e `--check` acusando sombreamento), `inventory.sh` (inclusive `--net`: curl/wget em skill, command, comando e script de hook, `package.json` scripts e `Makefile`, sem falso positivo como `libcurl`, regras de `allow`/`ask` com curl/wget no projeto, local e usuário, e projeto sem curl vazio), `map-partition.sh` (repo pequeno, monorepo com workspaces, vários repositórios, unidade gigante subdividida e pasta fatiada, caminhos protegidos e segredos ignorados, `--since`, `--path` e `--status`), `wave-base.sh` (diff da wave com arquivo alterado e novo, sem ignorado, index e commits intactos) e `setup.sh` (settings do usuário com o mesmo hash depois de todo subcomando e dos scripts do init, com `CLAUDE_CONFIG_DIR` numa fixture e com `~/.claude` de um HOME falso; `status` sem settings; `propose`/`apply` inexistentes; `groups` com `PowerShell` só no Windows nativo e `sandbox` só onde existe; `permissions` só com os grupos marcados, nenhum, fora da plataforma, deny que sombrearia `ask` da proposta, id desconhecido e `--kit` respeitando `permissions.groups`; `guards` com glob largo e segredo ignorados; Windows nativo, WSL2 e macOS simulados por um `uname` falso, `jq` ausente com o comando de cada plataforma, Claude Code antigo, `lsp` com binário presente, ausente e sem instalação automática, `plans` com plano parado há mais de 14 dias), os templates (sem template de usuário, `curl`/`wget` só no grupo `curl-wget`, segredos por nome sem `.env.*` e nenhum casando `.env*.example`), o `guard-files` com `.env.test.example` e afins liberados, `.env.test` negado, `guards.allow_write` exato, glob largo ignorado com mensagem, `.env` listado continuando negado e `guards.deny_write` com mensagem, o texto do `/kit:init` (relatório sem tarefa para o usuário) e do README, os guardas sem `jq` (bloqueiam `rm -rf /` e Edit em `.env` com a mensagem de instalação, liberam só o comando exato de instalação do `jq` da plataforma, sem nada junto), o aviso do `session-context` sem `jq` (JSON com `systemMessage` e `additionalContext`) e sem `git` e com codemap atrasado (`__HEAD0__` nos arquivos da fixture vira o hash do commit inicial e `commits: N` cria commits depois dele), os limites de tamanho do `/kit:spec` e do `/kit:plan` (padrões, pergunta única, leitura da skill do épico, M8 no `plan-reviewer`, chaves no `kit.example.json` e seção no README), que todo agent com Bash manda ler com Read e buscar com Grep/Glob, um comando por chamada, sem `cat` nem `cd <repo>;`, que a delegação a `general-purpose` inclui o bloco de `subagent-rules.md`, que as skills e o template do `CLAUDE.md` proíbem placeholder em comando e que nada sobrou do settings de usuário escrito pelo kit, a ordem de seções e campos do template do PLAN.md e que só tarefas, checkpoints e passos da wave final têm caixa, confere que todo hook do `hooks.json` está em forma shell e, no Windows, roda cada um pelo `bash.exe` do Git com um PATH sem nenhum `bash` do Git (o caso que quebrava a forma exec) e confere que os guardas negam com um `bash` do WSL antes no PATH, o verify-gate com `cwd` em nome curto 8.3 (TEMP do runner do GitHub) e o advise com TEMP com espaço e `~`, checa que nenhum script referencia comando de stack, que todos os JSON são válidos e roda `claude plugin validate` no plugin e no marketplace.

```bash
bash tests/run-adopt-test.sh [--keep]   # aceite ao vivo do modo adotar
bash tests/run-skills-live-test.sh      # skills carregam sem commits e fora de repo git; deny de skill/agent do kit
bash tests/run-guards-live-test.sh      # guarda ausente bloqueia (onFailure), com controle e contraprova
bash tests/run-plan-live-test.sh [--keep]   # /kit:plan decide lacuna técnica, pergunta produto e tamanho; /kit:spec grande pergunta a quebra
bash tests/run-permissions-live-test.sh [--keep]   # ${CLAUDE_PLUGIN_ROOT} e ${CLAUDE_SKILL_DIR} em allowed-tools; Agent(plugin:x) em deny
bash tests/run-execute-live-test.sh [--keep]   # /kit:execute: paralelo disjunto, serialização, checkpoint com revisão
```

Copia `tests/adopt/repo/` (que tem hooks, skills, agent, rule, CLAUDE.md, settings e MCP próprios) para uma pasta temporária, roda `/kit:init` com respostas pré-aprovadas via `claude -p --plugin-dir` e confere: o hash SHA-256 de `CLAUDE.md`, `.mcp.json`, `.claude/settings.local.json`, skills, agents, rules e hooks é o mesmo depois do init; o `.claude/settings.json` só ganhou itens (`merge-json.sh --check` contra o original), com backup idêntico ao original, o plugin habilitado e `Skill(kit:fix)` em deny; nenhum arquivo removido; nenhum commit; `docs/claude-adoption.md` cobrindo todas as peças e sugerindo `Skill(kit:fix)` em deny (com o motivo), aviso mudo e falha aberta marcados; `kit.json` com `key_parity`, `coupled_changes` e a lista de bloqueio convertida em `protected_paths` com mensagem. Leva alguns minutos e consome uma sessão do Claude Code. Roda com `--setting-sources project,local` para não disparar hooks pessoais do `~/.claude`.

O `run-guards-live-test.sh` exige Claude Code ≥ 2.1.295. Ele apaga o script de um guarda numa cópia do plugin e confere no disco que o comando (Bash) ou a escrita (Write) que criaria um arquivo-sonda não aconteceu. O controle, com o script presente, cria a sonda. A contraprova, com o script ausente e sem `onFailure`, também cria, o que mostra que o bloqueio vem do campo.

O `run-plan-live-test.sh` copia `tests/plan/repo/` com uma SPEC de `tests/plan/specs/` e roda `/kit:plan` via `claude -p`. Com a SPEC de lacuna técnica (último login), confere o formato do PLAN.md (seções na ordem, cada tarefa com `files`/`behavior`/`action`/`verify`/`done`, cada wave com `Paralelo:` e checkpoint, wave final F1 a F3 sem smoke porque a fixture não tem, caixa só onde deve, `lastLoginAt` em Interfaces) e Decisões com data, origem `kit` e motivo, sem `AskUserQuestion`, com o `kit:plan-reviewer` chamado, `docs/data-model.md` atualizado, nenhum código de produção alterado e resumo curto. Com a SPEC de lacuna de produto (bloqueio sem limite de tentativas definido), confere que a skill pergunta sobre o limite e não grava o PLAN.md. Com a SPEC grande (20 operações em módulos próprios), confere que a skill pergunta a quebra em fatias (citando o `EPIC.md` que a sessão grava), com a opção de manter, e não grava PLAN.md nem EPIC.md; com a mesma SPEC e a linha `· usuário · tamanho: manter` em Decisões, grava um plano acima de 15 tarefas ou 6 waves sem perguntar e copia a linha para Decisões do PLAN.md. O `/kit:spec` com essa SPEC como briefing pergunta quebrar, manter ou reduzir e não grava SPEC.md nem EPIC.md. Como `claude -p` não tem usuário, vale a chamada ao `AskUserQuestion` ou a pergunta no texto final.

O `run-execute-live-test.sh` exige `node` e roda `/kit:execute` via `claude -p` no PLAN.md de `tests/execute/repo/`: a wave 1 tem duas tarefas paralelas com arquivos disjuntos e a wave 2 marca como paralelas duas tarefas que tocam o mesmo arquivo. Confere: um teste de aceite que o modelo não viu (`tests/execute/aceite.test.js`) passa; todas as caixas marcadas, cada tarefa com Evidência e cada checkpoint com Evidência e Revisão do `code-reviewer`; `Base:` nas duas waves; as tarefas 1 e 2 disparadas em subagents na mesma mensagem e as 3 e 4 não; a sequência registrada em Decisões; a revisão do checkpoint 1 só depois de os dois subagents voltarem; `code-reviewer` chamado ao menos 3 vezes (duas waves e F1) e `security-reviewer` na F1; nenhum commit. É a sessão mais longa dos testes ao vivo.

A fixture guarda a configuração como `_claude/`, `_CLAUDE.md` e `_mcp.json` para o próprio Claude Code não carregar as skills e o CLAUDE.md de teste quando você trabalha no repo do kit.

Para testar o plugin ao vivo sem instalar: `claude --plugin-dir ./plugins/kit`.

## Publicar uma versão

- Editar o repo `claude-kit`, push; cada máquina atualiza como no README (seção Atualizar e desinstalar). Todos os projetos recebem a mudança; nenhum arquivo é copiado entre repositórios.
- Mudar a versão em `plugin.json` a cada release ajuda a saber qual versão cada máquina usa.
- Antes do commit: `bash tests/run-tests.sh`, `claude plugin validate --strict plugins/kit` e `claude plugin validate --strict .`.
- Tag anotada `vX.Y.Z` e push de `main` e da tag.

## Observações de plataforma

- Windows nativo e sandbox: ver [Requisitos e plataformas](README.md#requisitos-e-plataformas).
- Comando `!` de skill que falha impede a skill de carregar. Todo `!` de git termina com `2>/dev/null || echo "(sem commits)"` ou `|| echo "(não é repo git)"`, e `!` não pode conter variável de ambiente (falha na checagem de permissão).
- Os scripts precisam de fim de linha LF; o `.gitattributes` do repo garante isso no clone.
