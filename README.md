# claude-kit

Plugin pessoal do Claude Code com o núcleo independente de stack: skills de fluxo, subagents e hooks. Cada projeto só declara os comandos do seu stack em `.claude/kit.json`; nada do núcleo muda entre .NET, Node, Python, Go ou outro.

O desenho completo (princípios, camadas, permissões, riscos, modo adotar e checks de domínio) vem dos documentos de especificação do kit (guia e Aditivo 01), mantidos fora deste repositório.

## Estrutura

```text
claude-kit/
├── .claude-plugin/marketplace.json     # este repo é o marketplace
├── plugins/kit/
│   ├── .claude-plugin/plugin.json
│   ├── skills/{init,spec,plan,execute,epic,fix,hunt}/SKILL.md
│   ├── skills/init/{adopt.md,stacks.md}  # modo adotar e referência de stacks
│   ├── agents/{investigator,code-reviewer,security-reviewer,test-writer}.md
│   ├── hooks/hooks.json
│   ├── scripts/{lib.sh,guard-bash.sh,guard-files.sh,format.sh,verify-gate.sh,session-context.sh}
│   ├── scripts/{inventory.sh,merge-json.sh}   # apoio do /kit:init, não são hooks
│   └── templates/{kit.example.json,project-settings.json,CLAUDE.project.md}
├── templates/user-settings.json        # camada 1, aplicada à mão em ~/.claude
└── tests/
    ├── run-tests.sh                    # fixtures dos hooks + scripts de apoio + checagens estáticas
    ├── run-adopt-test.sh               # aceite ao vivo do modo adotar (usa claude -p)
    ├── fixtures/*.json
    ├── sample/                         # projeto mínimo com kit.json de comandos true/false
    └── adopt/repo/                     # repo com .claude/ próprio (guardado como _claude/, _CLAUDE.md, _mcp.json)
```

## Requisitos

- `bash`, `jq` e `git` (no Windows, Git Bash + `jq` no PATH). Sem `jq`, os guardas (`guard-bash`, `guard-files`) bloqueiam toda chamada com "kit: jq não encontrado; instale o jq"; os hooks de qualidade (`format`, `verify-gate`, `session-context`) saem com 0 sem fazer nada.
- **Windows nativo não tem sandbox.** O `templates/user-settings.json` usa `sandbox.failIfUnavailable: true`, e com isso o Claude Code se recusa a iniciar no Windows nativo. Escolha um dos dois:
  - usar o WSL2 (recomendado: mantém o sandbox); ou
  - remover `failIfUnavailable` da cópia em `~/.claude/settings.json` e aceitar rodar sem sandbox. Nesse caso, as regras de `permissions.deny` e os guardas do kit continuam valendo, mas não há isolamento de disco e rede.

## Como usar

O plugin é instalado uma vez por máquina; em cada repositório ele só é ligado por uma linha versionada no `.claude/settings.json`, e o único arquivo de stack é o `kit.json`.

**Uma vez só**

1. Criar o repositório privado `claude-kit` no GitHub com este conteúdo.

**Uma vez por máquina**

2. `/plugin marketplace add <seu-usuario>/claude-kit` e `/plugin install kit@claude-kit` (repositório privado: o `git` da máquina precisa ter acesso ao GitHub).
3. Copiar `templates/user-settings.json` para `~/.claude/settings.json` (mesclando com o que já existir).

**Em cada repositório novo**

4. Abrir o Claude Code no repo e rodar `/kit:init`. Ele detecta o stack e propõe `kit.json`, `.claude/settings.json` (liga o plugin, allow-list, domínios) e um CLAUDE.md curto. Se o repo já tem `.claude/`, `CLAUDE.md` ou `.mcp.json`, entra no [modo adotar](#modo-adotar).
5. Revisar, ajustar e commitar. Quem clonar o repo, ou você em outra máquina, recebe a indicação do marketplace e do plugin pelo settings versionado.

**No dia a dia**

- Feature: `/kit:spec` → `/clear` → `/kit:plan` → `/kit:execute`
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
    "typecheck": "npx tsc --noEmit -p frontend"
  },
  "format": {
    "**/*.cs": "dotnet format --include {files}",
    "**/*.{ts,html,scss}": "npx prettier --write {files}"
  },
  "protected_paths": ["**/Migrations/**", "**/*.generated.*"],
  "verify_on_stop": ["build", "test_related"],
  "source_globs": ["**/*.cs", "**/*.ts"],
  "coupled_changes": [
    { "when": ["src/views/**", "src/widgets/**"],
      "require": ["manual/**"],
      "message": "Telas mudaram; atualize o manual para refletir as telas atuais." }
  ],
  "key_parity": [
    { "files": ["strings/pt.json", "strings/en.json", "strings/es.json"],
      "message": "Textos precisam existir nas 3 línguas." }
  ]
}
```

- Comandos rodam com `bash -c` na pasta que contém o `.claude/` do `kit.json`.
- `{files}` vira a lista de caminhos relativos, cada um entre aspas simples.
- Globs aceitam `**`, `*`, `?` e `{a,b}`, relativos à raiz do `kit.json`. Glob sem `/` também casa pelo nome do arquivo.
- Chaves ausentes são puladas sem erro. Monorepo: um `kit.json` por pacote; os hooks usam o mais próximo do arquivo.
- Valores de partida por stack: `plugins/kit/skills/init/stacks.md`.

### Checks de domínio (opcionais)

Avaliados pelo `verify-gate` sobre os arquivos alterados (diff contra HEAD + não rastreados). Projeto que não declara as chaves não é afetado.

- **`coupled_changes`**: se algum arquivo alterado casa um glob de `when` e nenhum casa `require`, o gate bloqueia com `message` e a lista dos arquivos que dispararam a regra.
- **`key_parity`**: só roda se algum dos `files` mudou. Achata as chaves aninhadas com `.` e lista cada chave ausente e em quais arquivos (`home.welcome falta em en.json, es.json`). Arquivo listado inexistente ou JSON inválido também é falha. Quando dois arquivos têm o mesmo nome (`pt/common.json`, `en/common.json`), o rótulo é o caminho declarado.
- **Válvula de escape**: `.claude/kit-skip` com uma linha de justificativa libera `coupled_changes` (não libera `key_parity` nem os comandos). Quando o gate passa, o arquivo é apagado e a justificativa vai para a seção "Registro de kit-skip" de `docs/claude-adoption.md`, ou para `.claude/kit-skip.log` se aquele não existir. Se outra checagem falhar no mesmo turno, o `kit-skip` é mantido até o gate passar. Arquivo vazio não libera.
- **Ordem**: comandos de `verify_on_stop`, depois `key_parity`, depois `coupled_changes`. Todas as falhas do turno saem numa única mensagem numerada.

## Modo adotar

Quando o repositório já tem configuração do Claude Code, o `/kit:init` entra somando: nada existente é apagado ou sobrescrito sozinho, e uma peça só é removida depois que o equivalente do kit provar que faz o mesmo e você confirmar. Detalhes em `plugins/kit/skills/init/adopt.md`.

1. **Inventário** com `scripts/inventory.sh`: hooks de todos os settings (projeto, local, usuário), skills, commands, agents, rules, CLAUDE.md e MCP.
2. **Classificação** de cada peça: manter no projeto, substituir pelo kit, virar declaração no `kit.json` (`coupled_changes`/`key_parity`), promover ao kit ou somar. Sobreposições (dois hooks bloqueando o mesmo, duas skills de review) ganham uma peça dona.
3. **Prova de equivalência** antes de remover: o mesmo cenário passa pelo hook original e pelo do kit (ou pelo `verify-gate` num worktree descartável) e precisa dar o mesmo bloqueio.
4. **Adições** com merge chave a chave via `scripts/merge-json.sh` (arrays por união, valor existente vence, conflitos reportados) e conferência com `merge-json.sh --check` (só adições).
5. **Remoção** só com confirmação explícita na conversa, um commit por peça. Respostas pré-aprovadas no argumento (`/kit:init <respostas>`) valem para adições, nunca para remoções.
6. **Relatório** em `docs/claude-adoption.md`: peça, destino, prova e status.

Regras de escrita do init, inclusive em repo novo: mesclar JSON chave a chave, nunca sobrescrever settings, hooks, skills, agents ou CLAUDE.md existentes, mostrar o diff e só gravar após confirmação.

## Hooks

| Script | Evento | O que faz |
| --- | --- | --- |
| `guard-bash.sh` | PreToolUse `Bash` | Nega `rm -rf` fora do projeto ou em `/`, `~`, `..`, variáveis não resolvíveis; `git push --force`/`-f`/`+refspec`; `git reset --hard`; `git clean -fdx` (dry-run liberado); `DROP DATABASE/TABLE/SCHEMA`, `TRUNCATE` SQL; `curl`/`wget` com pipe para shell; `chmod -R 777`; `mkfs`; `dd of=/dev/*` (exceto `/dev/null`). Analisa também o conteúdo de `sh -c`, `bash -c`, `$()` e cadeias com `&&`, `;`, `\|`. |
| `guard-files.sh` | PreToolUse `Edit\|Write` | Nega escrita em `.env*` (exceto `.env.example/.sample/.template/.dist`), `*.pem`, `*.key`, `secrets/`. Nega Edit, e Write sobre arquivo existente, em `protected_paths`; Write de arquivo novo é liberado. |
| `format.sh` | PostToolUse `Edit\|Write` | Roda o formatter do primeiro glob de `format` que casa. Falha: exit 2 com as últimas 30 linhas. |
| `verify-gate.sh` | Stop | Se algum arquivo alterado (diff contra HEAD + não rastreados) casa `source_globs`, roda `verify_on_stop` em ordem até a primeira falha (últimas 60 linhas). Depois avalia `key_parity` e `coupled_changes`. Todas as falhas saem numa única mensagem com exit 2. Respeita `stop_hook_active`. Comandos já verificados com sucesso no mesmo estado não rodam de novo (marca em `.git/kit-verify-*`). |
| `session-context.sh` | SessionStart | Injeta branch, `git status --short` e as tarefas pendentes do `PLAN.md` mais recente em `docs/specs/`. |

Os guardas devolvem `permissionDecision: "deny"` com o motivo; Claude recebe o motivo e ajusta. `onFailure: "block"` nos guardas só tem efeito no Claude Code v2.1.295+; em versões anteriores o campo é ignorado e os guardas continuam funcionando.

## Testes

```bash
bash tests/run-tests.sh            # todos
bash tests/run-tests.sh "rm -rf"   # filtra por nome do caso
KIT_TEST_DEBUG=1 bash tests/run-tests.sh "<caso>"   # mostra input, stdout e stderr
```

Cada caso monta um workspace novo a partir de `tests/sample/` (repo git com `kit.json` de comandos `true`/`false`), grava os arquivos de base (`files`), faz commit, aplica as mudanças do turno (`change`, `edit`), passa o JSON do hook pelo script e confere decisão, exit code, stderr (conteúdo e ordem) e arquivos depois do gate (`after`). Fixtures podem declarar `defaults` mesclados em cada caso. Também testa `merge-json.sh` e `inventory.sh`, checa que nenhum script referencia comando de stack, que todos os JSON são válidos e roda `claude plugin validate` no plugin e no marketplace.

```bash
bash tests/run-adopt-test.sh [--keep]   # aceite ao vivo do modo adotar
bash tests/run-skills-live-test.sh      # skills carregam em repo sem commits e fora de repo git
```

Copia `tests/adopt/repo/` (que tem hooks, skills, agent, rule, CLAUDE.md e MCP próprios) para uma pasta temporária, roda `/kit:init` com respostas pré-aprovadas via `claude -p --plugin-dir` e confere: nenhum arquivo removido, nenhum commit criado, JSON existentes só com adições (`merge-json.sh --check`), demais arquivos sem linhas removidas, `docs/claude-adoption.md` cobrindo todas as peças, `kit.json` com `key_parity` e `coupled_changes`, plugin habilitado e hook original ainda registrado. Leva alguns minutos e consome uma sessão do Claude Code. Roda com `--setting-sources project,local` para não disparar hooks pessoais do `~/.claude`.

A fixture guarda a configuração como `_claude/`, `_CLAUDE.md` e `_mcp.json` para o próprio Claude Code não carregar as skills e o CLAUDE.md de teste quando você trabalha no repo do kit.

Para testar o plugin ao vivo sem instalar: `claude --plugin-dir ./plugins/kit`.

## Observações de plataforma

- Windows nativo e sandbox: ver [Requisitos](#requisitos).
- Comando `!` de skill que falha impede a skill de carregar. Todo `!` de git termina com `2>/dev/null || echo "(sem commits)"` ou `|| echo "(não é repo git)"`, e `!` não pode conter variável de ambiente (falha na checagem de permissão).
- Os scripts precisam de fim de linha LF; o `.gitattributes` do repo garante isso no clone.
