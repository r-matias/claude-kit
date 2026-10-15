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
│   ├── scripts/setup.sh                 # apoio do /kit:setup e do /kit:init: dependências, plataforma e settings do usuário
│   ├── scripts/map-partition.sh         # apoio do /kit:map e do /kit:init: unidades de mapeamento e estado do codemap
│   ├── scripts/wave-base.sh             # apoio do /kit:execute: base do diff de cada wave
│   ├── templates/{kit.example.json,project-settings.json,CLAUDE.project.md}
│   └── templates/user-settings.json     # camada 1: vira ~/.claude/settings.json (ou a sugestão ao lado) pelo /kit:setup
├── README.md                           # para quem usa o kit
├── CONTRIBUTING.md                     # para quem mantém o kit
├── docs/design.md                      # princípios, camadas e decisões
├── docs/reference.md                   # kit.json completo, hooks, plan/execute, modo adotar
└── tests/
    ├── run-tests.sh                    # fixtures dos hooks + scripts de apoio + checagens estáticas
    ├── run-adopt-test.sh               # aceite ao vivo do modo adotar (usa claude -p)
    ├── run-skills-live-test.sh         # aceite ao vivo do carregamento das skills e do deny de skill/agent
    ├── run-guards-live-test.sh         # aceite ao vivo do onFailure: guarda ausente bloqueia
    ├── run-plan-live-test.sh           # aceite ao vivo do /kit:plan: decide lacuna técnica, pergunta lacuna de produto
    ├── run-execute-live-test.sh        # aceite ao vivo do /kit:execute: waves, paralelo, checkpoint com revisão
    ├── fixtures/*.json
    ├── sample/                         # projeto mínimo com kit.json de comandos true/false
    ├── plan/{repo,specs}/              # projeto mínimo e SPECs com lacuna técnica e de produto
    ├── execute/                        # projeto com PLAN.md de 2 waves e teste de aceite independente
    └── adopt/repo/                     # repo com .claude/ próprio (guardado como _claude/, _CLAUDE.md, _mcp.json)
```

## Testes

```bash
bash tests/run-tests.sh            # todos
bash tests/run-tests.sh "rm -rf"   # filtra por nome do caso
KIT_TEST_DEBUG=1 bash tests/run-tests.sh "<caso>"   # mostra input, stdout e stderr
bash tests/run-tests.sh --awk mawk # roda com o mawk (awk do Debian/Ubuntu) no lugar do awk; pula se nao houver
```

Os scripts usam só awk POSIX. Em especial, não escreva `X[k] = (k in X) ? ... : ...`: no mawk o lado esquerdo cria a chave antes do teste. Use `if (k in X) ...; else ...`.

Cada caso monta um workspace novo a partir de `tests/sample/` (repo git com `kit.json` de comandos `true`/`false`), grava os arquivos de base (`files`), faz commit, aplica as mudanças do turno (`change`, `edit`, `touch` para envelhecer arquivos), passa o JSON do hook pelo script e confere decisão, motivo (`reason`), exit code, stdout e stderr (conteúdo e ordem), JSON de saída (`json_check`), execução repetida (`repeat_empty`) e arquivos depois do hook (`after`). Com `workspace.repos`, o caso roda numa pasta-mãe sem git com repositórios filhos. Cada caso tem `session_id` e `TMPDIR` próprios. Fixtures podem declarar `defaults` mesclados em cada caso. Também testa `merge-json.sh` (inclusive `--additions`), `inventory.sh`, `map-partition.sh` (repo pequeno, monorepo com workspaces, vários repositórios, unidade gigante subdividida e pasta fatiada, caminhos protegidos e segredos ignorados, `--since`, `--path` e `--status`), `wave-base.sh` (diff da wave com arquivo alterado e novo, sem ignorado, index e commits intactos) e `setup.sh` (`status` pronto e com regra faltando, settings inexistente criado, settings existente intacto com sugestão só do que somaria e apply recusado, Windows nativo e WSL2 simulados por um `uname` falso, `jq` ausente com o comando de cada plataforma, Claude Code antigo), o aviso do `session-context` sem `jq` e sem `git` e com codemap atrasado (`__HEAD0__` nos arquivos da fixture vira o hash do commit inicial e `commits: N` cria commits depois dele), a ordem de seções e campos do template do PLAN.md e que só tarefas, checkpoints e passos da wave final têm caixa, confere que todo hook do `hooks.json` está em forma shell e, no Windows, roda cada um pelo `bash.exe` do Git com um PATH sem nenhum `bash` (o caso que quebrava a forma exec), checa que nenhum script referencia comando de stack, que todos os JSON são válidos e roda `claude plugin validate` no plugin e no marketplace.

```bash
bash tests/run-adopt-test.sh [--keep]   # aceite ao vivo do modo adotar
bash tests/run-skills-live-test.sh      # skills carregam sem commits e fora de repo git; deny de skill/agent do kit
bash tests/run-guards-live-test.sh      # guarda ausente bloqueia (onFailure), com controle e contraprova
bash tests/run-plan-live-test.sh [--keep]   # /kit:plan decide lacuna técnica e pergunta lacuna de produto
bash tests/run-execute-live-test.sh [--keep]   # /kit:execute: paralelo disjunto, serialização, checkpoint com revisão
```

Copia `tests/adopt/repo/` (que tem hooks, skills, agent, rule, CLAUDE.md, settings e MCP próprios) para uma pasta temporária, roda `/kit:init` com respostas pré-aprovadas via `claude -p --plugin-dir` e confere: o hash SHA-256 de todo arquivo de configuração do Claude Code que já existia (`CLAUDE.md`, `.mcp.json`, `.claude/settings*.json`, skills, agents, rules e hooks) é o mesmo depois do init; nenhum arquivo removido; nenhum commit; `.claude/kit-settings.suggested.json` com o plugin habilitado e `Skill(kit:fix)` em deny; `docs/claude-adoption.md` cobrindo todas as peças e sugerindo `Skill(kit:fix)` em deny (com o motivo), aviso mudo e falha aberta marcados; `kit.json` com `key_parity`, `coupled_changes` e a lista de bloqueio convertida em `protected_paths` com mensagem. Leva alguns minutos e consome uma sessão do Claude Code. Roda com `--setting-sources project,local` para não disparar hooks pessoais do `~/.claude`.

O `run-guards-live-test.sh` exige Claude Code ≥ 2.1.295. Ele apaga o script de um guarda numa cópia do plugin e confere no disco que o comando (Bash) ou a escrita (Write) que criaria um arquivo-sonda não aconteceu. O controle, com o script presente, cria a sonda. A contraprova, com o script ausente e sem `onFailure`, também cria, o que mostra que o bloqueio vem do campo.

O `run-plan-live-test.sh` copia `tests/plan/repo/` com uma SPEC de `tests/plan/specs/` e roda `/kit:plan` via `claude -p`. Com a SPEC de lacuna técnica (último login), confere o formato do PLAN.md (seções na ordem, cada tarefa com `files`/`behavior`/`action`/`verify`/`done`, cada wave com `Paralelo:` e checkpoint, wave final F1 a F3 sem smoke porque a fixture não tem, caixa só onde deve, `lastLoginAt` em Interfaces) e Decisões com data, origem `kit` e motivo, sem `AskUserQuestion`, com o `kit:plan-reviewer` chamado, `docs/data-model.md` atualizado, nenhum código de produção alterado e resumo curto. Com a SPEC de lacuna de produto (bloqueio sem limite de tentativas definido), confere que a skill pergunta sobre o limite e não grava o PLAN.md. Como `claude -p` não tem usuário, vale a chamada ao `AskUserQuestion` ou a pergunta no texto final.

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
