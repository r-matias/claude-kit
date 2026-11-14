# Referência do kit

Detalhe completo de configuração e comportamento. Para instalar e usar, comece pelo [README](../README.md).

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
  "inject_plan_on_prompt": false,
  "notify": { "waiting": true, "done": true, "done_min_seconds": 60, "sound": true,
    "push": { "ntfy_topic_env": "KIT_NTFY_TOPIC", "discord_webhook_env": "KIT_DISCORD_WEBHOOK" } },
  "spec": { "max_scope_items": 8, "max_files": 25 },
  "plan": { "max_tasks": 15, "max_waves": 6 },
  "map": { "stale_after_commits": 50, "unit_max_files": 150, "unit_max_loc": 20000, "max_agents": 30 }
}
```

- Comandos rodam com `bash -c` na pasta que contém o `.claude/` do `kit.json`.
- `smoke` é opcional e só o `/kit:execute` usa, no último passo da wave final do plano.
- `{files}` vira a lista de caminhos relativos, cada um entre aspas simples.
- Globs aceitam `**`, `*`, `?` e `{a,b}`, relativos à raiz do `kit.json`. Glob sem `/` também casa pelo nome do arquivo.
- Chaves ausentes são puladas sem erro. Monorepo: um `kit.json` por pacote; os hooks usam o mais próximo do arquivo.
- Valores de partida por stack: [`plugins/kit/skills/init/stacks.md`](../plugins/kit/skills/init/stacks.md).

### `protected_paths`

Cada item é uma string (glob) ou um objeto `{ "glob", "message", "write" }`.
- `message` substitui o texto genérico da negação. Use para dizer o que fazer em vez de editar.
- `write`: `"allow"` (padrão: arquivo novo pode ser criado ali) ou `"deny"` (nem criar). Útil para binários, bancos e artefatos.
- Edit, e Write sobre arquivo existente, são sempre negados para um caminho protegido, salvo caminho em `guards.allow_write`. Strings continuam com o comportamento da v0.1.0.

### `guards` e `permissions`

```json
{
  "guards": {
    "allow_write": ["web/src/i18n/generated/README.md"],
    "deny_write": ["vendor/**", { "glob": "docs/legal/**", "message": "Texto jurídico: só o time legal altera." }]
  },
  "permissions": { "groups": ["segredos", "git-destrutivo", "push", "sandbox"] }
}
```

- `guards.allow_write`: caminho ou glob estreito que pode ser escrito mesmo casando `protected_paths` (de qualquer `kit.json` da cadeia até a pasta da sessão). Glob largo (`*`, `**`, `**/*`, `.env*`, `*.env`, só curingas) é ignorado. Segredo (`.env`, `.env.<qualquer>` sem sufixo de exemplo, `*.pem`, `*.key`, `keys/`, `secrets/`) não tem exceção.
- `guards.deny_write`: bloqueia escrita, inclusive de arquivo novo; vence `allow_write`. `message` opcional por item.
- `permissions.groups`: ids de `templates/project-permissions.json` marcados no `/kit:init`; o reparo só propõe esses.
- `setup.sh guards` aponta cada entrada ignorada ou sem glob e cada grupo desconhecido.

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

### `notify`

Ausente ou `false`, nada é notificado (`false` registra que o `/kit:init` perguntou e o usuário recusou). Dentro do objeto, chave ausente é desligada.

| Chave | Padrão | Efeito |
| --- | --- | --- |
| `waiting` | `false` | Hook Notification (`permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`): `⏳ <projeto>: <mensagem do evento>` |
| `done` | `false` | Fim de turno liberado pelo `verify-gate` (gate passou, não havia o que verificar ou segunda passada com `stop_hook_active`): `✅ <projeto> (<branch>): concluído em <duração>`. Nunca quando o gate bloqueia nem no `SubagentStop` |
| `done_min_seconds` | 60 | Turno mais curto não notifica. O início vem de `.claude/state/turn-start`, gravado no UserPromptSubmit (mtime = início, conteúdo = `session_id`; de outra sessão, não notifica) |
| `sound` | `false` | Som do sistema: toast com som no Windows, `soundName` no macOS, `canberra-gtk-play`/`paplay` no Linux |
| `push.ntfy_topic_env` | `KIT_NTFY_TOPIC` | Nome da variável de ambiente com o tópico do ntfy (ou a URL `https://servidor/topico`). Só com `push` presente e a variável definida |
| `push.discord_webhook_env` | `KIT_DISCORD_WEBHOOK` | Nome da variável com a URL `https://` do webhook do Discord, enviada sem menções |

O valor do tópico e do webhook nunca fica no `kit.json`, só o nome da variável.

### `spec` e `plan`

Limites de tamanho, todos opcionais:

| Chave | Padrão | Efeito |
| --- | --- | --- |
| `spec.max_scope_items` | 8 | Itens de Escopo acima disso: o `/kit:spec` não grava uma SPEC única e pergunta |
| `spec.max_files` | 25 | Arquivos afetados (contados pelo `kit:investigator`) acima disso: idem |
| `plan.max_tasks` | 15 | Tarefas numeradas acima disso: o `/kit:plan` não grava e pergunta |
| `plan.max_waves` | 6 | Waves (sem a wave final) acima disso: idem |

Mais de 2 repositórios tocados também conta como acima do limite no `/kit:spec`. A pergunta é única, com três opções: quebrar em fatias agora (recomendada, com as fatias já sugeridas), manter numa só ou reduzir escopo. Na quebra, você não roda o `/kit:epic`: a própria skill lê o `SKILL.md` dele e segue os passos de gravação (`EPIC.md` e uma SPEC por fatia) na mesma sessão, sem nova entrevista. Manter grava e registra em Decisões `- <data> · usuário · tamanho: manter ... — acima do limite`; o `/kit:plan` e o `kit:plan-reviewer` (regra M8) aceitam essa linha na SPEC.md ou no PLAN.md.

### `map`

Limites do `/kit:map`, todos opcionais, lidos do `kit.json` da pasta da sessão:

| Chave | Padrão | Efeito |
| --- | --- | --- |
| `stale_after_commits` | 50 | Acima disso, o `session-context` avisa que o `docs/codemap.md` está atrasado e sugere `/kit:map --update` |
| `unit_max_files` | 150 | Unidade com mais arquivos é subdividida |
| `unit_max_loc` | 20000 | Unidade com mais linhas é subdividida |
| `max_agents` | 30 | Acima disso, o `/kit:map` pergunta antes de lançar, com o custo estimado |
| `primary` | o repositório da pasta, ou o primeiro de `repos` | Repositório onde ficam o `docs/codemap.md` e o `docs/stack.md` |

## Init, setup e map

O kit nunca lê para propor nem grava o settings do usuário (`~/.claude/settings.json` ou o de `CLAUDE_CONFIG_DIR`), em nenhum fluxo. O `/kit:setup` só verifica (`setup.sh check`/`status`: Claude Code mínimo, `git`, `bash`, `jq`, `bwrap`/`socat` no Linux/WSL2, plataforma, aviso de sandbox e o marketplace `claude-kit` registrado). O `/kit:init` é a porta de entrada. Ele roda `scripts/setup.sh status` e põe o comando de instalação de cada dependência que falta na confirmação. Depois configura o projeto (novo, adotar ou reparo), detecta o plugin LSP com `setup.sh lsp` (oficial, menos Node/TS, que usa o `ts-lsp@claude-kit` com teto de memória; ver README, seção "LSP de TypeScript com teto de memória") e junta tudo numa confirmação única (`AskUserQuestion` com a gravação, os grupos de permissão em `multiSelect` e as decisões que são do usuário). Habilitar o kit num projeto é o equivalente à instalação `--scope project`: `enabledPlugins` e `extraKnownMarketplaces` no `.claude/settings.json` do projeto.

**Grupos de permissão** (`templates/project-permissions.json`). `setup.sh groups` lista os grupos desta plataforma (`<id><TAB><rótulo> — <descrição>`): `segredos` (Read de `.env`, `.env.local`, `.env.*.local`, `.env.test`, `.env.production`, `.env.development`, `.env.staging`, `**/*.pem`, `**/*.key`, `**/secrets/**`, `~/.ssh/**`, `~/.aws/**`, `~/.kube/**`, `~/.git-credentials`, `~/.npmrc`, `~/.config/gh/**`, `~/.docker/config.json`; nomes explícitos, nunca `.env.*`, que bloquearia a leitura de `.env*.example` sem exceção possível em deny), `git-destrutivo` (`push --force`/`-f`, `reset --hard`, `clean -fdx`), `push` (ask de `git push`), `curl-wget` (deny; só oferecido sem uso detectado pelo `inventory.sh --net` nem no `commands.smoke`), `powershell` (só Windows nativo) e `sandbox` (só macOS e Linux/WSL2 com `bwrap` e `socat`: `enabled`, `failIfUnavailable: true`, credenciais negadas e ask de `dangerouslyDisableSandbox`). `setup.sh permissions <id,id,...> <proposta>` acrescenta à proposta só os grupos marcados, pelo mesmo merge aditivo (`-` é nenhum; grupo fora da plataforma vira `fora: <id>`; id desconhecido sai com 2). A escolha fica em `permissions.groups` do `kit.json`; no reparo, `setup.sh permissions --kit .claude/kit.json <proposta>` usa só esses ids, então grupo desmarcado antes não volta (sem a chave, exit 3 e o init pergunta).

**Guards** (`guards` no `kit.json`, conferidos por `setup.sh guards [kit.json]`). `allow_write`: caminhos ou globs liberados para escrita mesmo casando `protected_paths`. Glob largo (`*`, `**`, `**/*`, `.env*`, `*.env` e só curingas) é ignorado no init, no reparo e no próprio `guard-files`, que diz na mensagem de bloqueio qual entrada ignorou. Segredo de verdade não tem exceção: `.env`, `.env.<qualquer>` sem sufixo de exemplo, `*.pem`, `*.key`, `keys/` e `secrets/` continuam bloqueados mesmo listados, e o `setup.sh guards` devolve `ignorado: ... — segredo não tem exceção`. `deny_write`: caminhos extras bloqueados (também arquivo novo), string ou `{ "glob", "message" }`; vence `allow_write`. Nome terminado em `.example`, `.sample`, `.template` ou `.dist` (ex.: `.env.test.example`) não é segredo. O bloqueio por `protected_paths` termina com "Se este arquivo não é segredo, adicione o caminho em guards.allow_write no .claude/kit.json." Com o "sim", grava, instala, roda cada comando de `verify_on_stop` e, com mais de 300 arquivos de código (contados pelo `map-partition.sh`) ou mais de um repositório, segue o fluxo do `/kit:map` sem perguntar. Com `.claude/kit.json` já presente, entra em modo reparo: valida `kit.json`, comandos, settings e `.gitignore`, soma o que falta pela mesma confirmação e roda o `/kit:map --update` quando `map-partition.sh --status` aponta atraso. O relatório final tem no máximo ~10 linhas (feito, verificado, avisos, planos parados há mais de 14 dias pelo `setup.sh plans`) e termina em `Pronto. Próximo: /kit:spec <ideia>`.

**Merge aditivo dos settings** (`scripts/merge-json.sh`). `--preview` mostra o diff e as linhas `conflito:`; `--apply` grava. Objetos são mesclados chave a chave, arrays por união sem duplicar, chave ausente entra, valor existente sempre vence e a chave `hooks` da proposta é ignorada. Regra nova de `permissions.deny` que sombrearia uma regra de `allow` ou `ask` do mesmo arquivo (mesma ferramenta e o padrão do deny casa com o padrão existente: `Bash(curl *)` cobre `Bash(curl *x.com*)`; a sintaxe antiga `curl:*` vale como `curl *`) não entra, porque deny vence e o merge mudaria o comportamento; sai a linha `conflito: deny <regra> não aplicado — sombrearia <regra existente> em <allow|ask>`. O `--check` também acusa deny novo que sombreia regra de antes. Regras de `allow`/`ask` com `curl`/`wget` (projeto, local ou usuário, só lidas) também contam no `inventory.sh --net`, e o grupo `curl-wget` não é oferecido. Antes de gravar, backup em `<arquivo>.bak-kit-<AAAA-MM-DD>` (já existindo, com a hora no nome); se o resultado perderia ou trocaria algo (`--check`), nada é gravado. `settings.local.json` é recusado.

### Perfil do stack

O `/kit:init` (passo 11) roda `scripts/stack-profile.sh --write`, sem LLM e sem perguntar, e grava `docs/stack.md` no repositório principal (`map.primary`, o da raiz ou o primeiro). O arquivo sai do script como está; o init não edita nem completa.

**Descoberta.** Os mesmos repositórios do `map-partition.sh` (`repos` do `kit.json` da raiz, o próprio ou os filhos) e os mesmos arquivos (`git ls-files` sem vendor, gerados, `protected_paths` e o resto da lista do mapa). Manifestos lidos: `package.json` (gerenciador por `packageManager` ou pelo lockfile mais próximo: `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, `package-lock.json`), `*.csproj`/`*.fsproj`/`*.vbproj` e `Directory.Packages.props` (versão central), `pyproject.toml` (`[project]`, `optional-dependencies`, `dependency-groups`, Poetry) e `requirements*.txt` (uv, Poetry, Pipenv, PDM ou pip pelo lockfile), `go.mod` (sem `// indirect`), `Cargo.toml` (`dependencies`, `dev-dependencies`, `build-dependencies`, `target.*`, `workspace = true`; crate local por `path` fica de fora), `pom.xml`, `build.gradle*`, `Gemfile` e `composer.json`. Repositório sem manifesto fica de fora.

**Saída** (`stack-profile.sh`, sem argumento): JSON `{root, primary, repos[{repo, commit, packages[{path, manifest, manager}], base[{kind, name, version, source}], deps[{name, ecosystem, version, declared_in[], files_src, files_test}], version_conflicts[{name, versions}]}]}`.
- **Versão:** a declarada no manifesto, reduzida a `major.minor`; framework na base, só major. Lockfile só identifica o gerenciador.
- **Contagem:** arquivos de `source_globs` que citam a dependência pela forma de import do stack, com um `git grep` por ecossistema: npm `'nome'`, `'nome/`, `"nome"`, `"nome/`; Rust `nome_com_underscore::`; .NET `using Nome` (e namespaces abaixo dele); Python `import nome` e `from nome`; Go o caminho do módulo entre aspas. Arquivo de teste: `*.test.*`, `*.spec.*`, `tests/`, `test/`, `__tests__/`, `*Tests/`, `*_test.go`, `test_*.py`. Maven, Gradle, Gemfile e Composer não têm forma de import confiável: `files_src` e `files_test` saem `null`.
- **Contagem 0** quer dizer "sem import encontrado", não "não usado": analyzers, test adapters, metapacotes, CSS e ferramentas de build não são importados.
- **Uma dependência por repositório**, com os pacotes que a declaram em `declared_in`. Versões diferentes entre pacotes do mesmo repositório entram em `version_conflicts`.

**`docs/stack.md`.** Cabeçalho `<!-- kit:init <commit> -->` (um repositório) ou `<!-- kit:init <repo>=<commit> ... -->` (vários). Uma seção por repositório (num repositório só, sem título de seção), com Base (linguagem, runtime, framework e teste, cada um com o manifesto de origem; gerenciador; pacotes), a tabela `| Dependência | Versão | Arquivos (produção) | Arquivos (teste) | Declarada em |` ordenada por produção e depois teste, só com contagem acima de 0, a linha "Sem import encontrado", a linha "Declaradas, sem contagem para este stack" e "Versões divergentes", quando houver. `docs/stack.md` sem o cabeçalho `kit:init` é do projeto e nunca é sobrescrito: `--write` sai com 3.

**Desatualizado.** `stack-profile.sh --status` imprime `atualizado`, `desatualizado: <manifestos>` ou `ausente` (exit 1 nos dois últimos): em cada repositório, `git diff --name-only <commit do cabeçalho> HEAD` filtrado pelos manifestos. Repositório com manifesto que não está no cabeçalho e commit fora do histórico também contam. O `session-context` faz a mesma conta no início da sessão e escreve `Perfil do stack desatualizado (<manifestos>): rode /kit:init para reparar`; o `pre-compact` não repete. O `setup.sh status` mostra `perfil do stack: ausente | atualizado | desatualizado (...)`. No modo reparo, o init relê os manifestos alterados, reconfere os comandos do `kit.json` contra eles e refaz o perfil.

**Quem lê.** O `kit:investigator` lê o perfil antes de explorar; no inventário de reuso, a dependência do perfil mais usada para a necessidade é a primeira candidata `usar`, com a contagem como evidência. O `/kit:plan` usa as dependências e versões do perfil em Interfaces e `action`; dependência fora do perfil é dependência nova (pergunta), e duas dependências da mesma necessidade com uso parecido, sem Decisão, são lacuna de produto. O `/kit:execute` passa aos subagents a seção do perfil do repositório tocado. Plan e execute consultam a documentação da versão do perfil quando há fonte na sessão (MCP de documentação ou web) e, sem fonte, seguem o padrão do código do projeto. O `kit:code-reviewer` aponta API de outra versão major (M6).

A tabela "Comandos de pacote" de `skills/init/stacks.md` diz, por gerenciador, como consultar as versões publicadas e a licença de um pacote.

### `/kit:map`

1. **Partição** (`scripts/map-partition.sh`, sem LLM): `git ls-files` de cada repositório da sessão, filtrado por `source_globs` e sem `node_modules/`, `vendor/`, `dist/`, `build/`, `target/`, gerados, lockfiles, binários, `protected_paths`, `.env*`, `secrets/`, `keys/` e o próprio `.claude/`. Unidade inicial é o pacote (pasta com manifesto) ou a pasta de topo; acima do limite, subdivide pelas subpastas (pasta só com arquivos diretos vira fatias); vizinhas pequenas com a mesma pasta-mãe são agrupadas até o limite. Saída JSON com `repo`, `unit`, `paths[]` (a maior pasta que só tem arquivos daquela unidade, ou o arquivo), `file_count`, `loc` e `manifests`. `--path` limita a uma área; `--since [<repo>=]<commit>` marca `changed` nas unidades com arquivo alterado (commits e working tree); `--status` diz se o codemap está ausente, em dia ou atrasado.
2. **Mapeadores**: um `kit:mapper` por unidade, em ondas de até 8 na mesma mensagem. O agent só tem Read, Grep e Glob e devolve um schema fixo de até 60 linhas (responsabilidade, entradas, interfaces, dependências, convenções, armadilhas, testes, confiança), cada afirmação com `arquivo:linha`.
3. **Transversais**: `kit:mapper` no modo integração (contratos entre unidades e repositórios, com divergências e evidência dos dois lados) e no modo fluxos (3 a 5 fluxos ponta a ponta).
4. **Verificação**: `kit:map-verifier`, que não produziu o mapa, abre ~5 afirmações por unidade e todas as transversais. Reprovada sai; unidade com mais de 30% de reprovação é remapeada uma vez.
5. **Escrita**, sem pedir aprovação (fica no git): `.claude/rules/map-<unidade>.md` (frontmatter `paths:`, até 40 linhas) no repositório da unidade, `docs/codemap.md` (até 150 linhas) no repositório principal e `.claude/rules/kit-codemap.md` sem `paths:` (carrega sempre, aponta para o codemap) em cada repositório; o `CLAUDE.md` não é tocado. Todo arquivo gerado leva `<!-- kit:map v1 · <data> · <commit> -->`; blocos entre `<!-- manual -->` e `<!-- /manual -->` são preservados; rule sem esse cabeçalho nunca é sobrescrita (o kit grava `map-<unidade>.kit.md` e avisa).

O total de agents é unidades + 2 transversais + um verificador a cada 8 unidades. O `--update` lê o commit do cabeçalho, passa ao script com `--since` e remapeia só as unidades alteradas, novas ou com `paths` diferentes; refaz os transversais só se interfaces ou dependências mudaram. Os investigadores de `/kit:plan`, `/kit:fix` e `/kit:hunt` leem o `docs/codemap.md` antes de explorar e confiam no código quando divergem.

## Plan e execute

O `/kit:plan` não pede revisão do plano. Lacuna técnica (nome de campo, parâmetro, flag, pasta, biblioteca já prevista) ele decide pelo padrão mais simples coerente com os docs, registra em "Decisões" do PLAN.md com data, origem e motivo e atualiza o doc de referência quando houver. Ele só pergunta em decisão de produto (o que o usuário vê, regra de negócio), escopo fora da SPEC ou decisão cara de reverter (schema público, contrato de API, dependência nova). Plano acima de `plan.max_tasks` (15) ou `plan.max_waves` (6) não é gravado sem a escolha do usuário (ver [`spec` e `plan`](#spec-e-plan)). Antes de entregar, o `kit:plan-reviewer` confere o plano contra a SPEC e a skill corrige o que ele apontar; você recebe um resumo de até 5 linhas.

### Reuso, abordagem e revisão interrompida

O `kit:investigator` devolve, quando pedido, o inventário de reuso: uma linha por necessidade da SPEC (descrita pelo que faz, não por um nome), com o veredito `usar` (`arquivo:linha` e símbolo de um arquivo lido), `estender: <o que acrescenta>` (os chamadores atuais continuam funcionando) ou `nenhum` (com os termos e globs buscados). O inventário é refeito a cada `/kit:spec` e `/kit:plan` a partir do código de hoje; não existe catálogo a manter. Na SPEC, as linhas `usar` e `estender` viram `- Reuso:` em "Arquivos e interfaces". No PLAN.md, a tabela inteira fica em `## Reuso`, e cada `action` cita a linha do que usa ou cria (`usar loadUsers (R1)`, `novo (R3: nenhum)`): o plano só cria o que está marcado `nenhum`. Antes das tarefas, a skill compara duas ou três abordagens e grava em `## Abordagem` a escolhida e as descartadas, cada uma com o motivo; vence a que cria menos arquivos e usa mais linhas do Reuso, salvo regra do CLAUDE.md ou item de Escopo descoberto. O `kit:plan-reviewer` refaz a busca das linhas `nenhum` (M9) e aponta código existente que dispensaria um arquivo novo ou uma wave (M10); o `kit:code-reviewer` aponta código novo que repete o que já existe fora do diff (M5). O `/kit:execute` passa a seção Reuso aos subagents e busca antes de criar o que ela não lista.

A SPEC nasce com `Revisão: pendente` abaixo do título e o PLAN.md com a mesma linha abaixo de `Spec:`; o veredito do revisor substitui a linha (`aprovado (rodada N)` ou `reprovado após 3 rodadas — <ids>`) e, enquanto a skill espera resposta do usuário, ela fica `pendente`. Uma sessão que parou entre gravar e revisar deixa a marca: o `/kit:plan` revisa a SPEC `pendente` antes de planejar, e o `/kit:execute` revisa o plano `pendente` antes de executar. SPEC e plano sem a linha (escritos à mão ou de versões anteriores) seguem como antes.

### Severidade dos revisores

O `kit:spec-reviewer`, o `kit:plan-reviewer`, o `kit:code-reviewer` e o `kit:security-reviewer` não classificam no julgamento: cada regra tem um id com severidade fixa, todo achado cita o id (`BLOCKER [B1] — tarefa 3, wave 1 — ...`) e herda a severidade dele. É proibido rebaixar; na dúvida entre dois ids vale o mais grave; MINOR (`[-]`) é só o que não casa com nenhum id (redação, organização, melhoria opcional). A última linha da resposta é `aprovado` ou `reprovado` (qualquer BLOCKER ou MAJOR). O `/kit:plan` e o `/kit:execute` corrigem todo BLOCKER e MAJOR e chamam de novo até `aprovado`.

| Revisor | BLOCKER | MAJOR |
| --- | --- | --- |
| `spec-reviewer` | B1 Objetivo ausente ou sem problema e resultado · B2 item de Escopo ou caso de borda com duas leituras para o usuário · B3 Verificação ponta a ponta ausente ou não observável · B4 contradição interna · B5 contrato que conflita com o código sem dizer que muda | M1 cria o que o código já tem · M2 escopo especulativo · M3 otimização sem gargalo citado · M4 termo do projeto sem definição · M5 pré-requisito não declarado · M6 SPEC trata como existente o que não existe · M7 lógica fora da camada do padrão · M8 caso de borda de uso normal ausente · M9 Objetivo promete o que o Escopo não entrega nem exclui |
| `plan-reviewer` | B1 tarefa usa algo da mesma wave ou de wave posterior · B2 tarefas de `Paralelo:` com arquivo em comum · B3 Escopo, caso de borda ou Verificação ponta a ponta sem truth · B4 decisão de produto, fora da SPEC ou cara de reverter com origem `kit` · B5 migração ou alteração de dados persistentes sem backup ou rollback na própria tarefa · B6 `verify` com chave fora do `kit.json` · B7 Interfaces divergem da SPEC · B8 caixa `- [ ]` fora de tarefa, checkpoint ou wave final | M1 truth sem teste ou artifact fora de `files` · M2 caso de borda sem behavior/teste · M3 behavior só manual quando dá para automatizar · M4 molde `arquivo:linha` inexistente · M5 tarefa grande demais · M6 tarefa sem um dos campos ou `done` não testável · M7 doc de referência ou `coupled_changes` afetado sem tarefa · M8 plano acima de `plan.max_tasks`/`max_waves` sem Decisão do usuário · M9 tarefa cria o que o código já tem ou o que o Reuso marca `usar`/`estender` · M10 código existente fora do plano dispensaria um arquivo novo ou uma wave |
| `code-reviewer` | B1 requisito da tarefa/SPEC não implementado · B2 segredo exposto ou entrada não validada em fronteira · B3 teste quebrado, removido ou enfraquecido · B4 mudança fora do escopo que altera comportamento · B5 contrato de Interfaces alterado sem registro em Decisões | M1 caso de borda sem teste · M2 erro engolido ou sem tratamento · M3 arquivo acoplado (`coupled_changes`/`key_parity`) não atualizado · M4 `done` marcado sem evidência · M5 código novo que repete o que já existe fora do diff ou o que o Reuso marca `usar`/`estender` · M6 API de outra versão major que a do `docs/stack.md`, ou removida, com doc, changelog ou padrão do projeto citado (sem evidência, MINOR) |
| `security-reviewer` | B1 injeção com entrada externa · B2 path traversal ou SSRF · B3 operação sem checagem de permissão ou IDOR · B4 segredo no código | M1 dado sensível em log ou resposta · M2 stack trace exposto · M3 validação de entrada incompleta sem caminho de injeção |

O `tests/run-reviewers-live-test.sh` calibra os revisores com uma SPEC (contradição, módulo reinventado e cache sem gargalo: `B4`, `M1`, `M3`), um plano e um diff com defeitos plantados (precisam sair com o id certo e `reprovado`) e um plano e um diff limpos (precisam sair `aprovado`); o plano limpo com `plan.max_tasks` baixo precisa sair com `MAJOR [M8]`, e com a Decisão `tamanho: manter` do usuário, `aprovado`. O mesmo teste confere o `kit:drift-checker`: a feature implementada fiel à SPEC sai `sem divergência`, e com o limite do apelido trocado sai `DIVERGÊNCIA [D2]`.

O `kit:spec-reviewer` começa parafraseando o que a SPEC propõe e como o sistema funciona segundo ela; se não consegue parafrasear o Objetivo, é B1. Ele lê o CLAUDE.md e o código (Read, Grep, Glob), mas não a conversa: o leitor sem contexto é da entrevista, não do projeto. M1 e M7 só valem com o `arquivo:linha` do que já existe. Lacuna técnica que o `/kit:plan` decide sozinho (unidade de contagem, trim, formato interno, erro de arquivo local) é no máximo MINOR: o revisor julga se a SPEC basta para planejar sem adivinhar a intenção do usuário, não se é perfeita. Achado cuja correção é escolha de produto sai marcado `(decisão de produto)`, e o `/kit:spec` pergunta ao usuário em vez de decidir.

### Drift

O `/kit:drift` confere só SPECs com `PLAN.md` sem nenhuma caixa `- [ ]` (ou a SPEC passada no argumento) e chama um `kit:drift-checker` por SPEC, até 8 por mensagem. O checker (Read, Grep, Glob) lista as promessas da SPEC e das `Interfaces` do plano, acha onde cada uma está no código e reporta só o que diverge: D1 item de Escopo ou caso de borda sem implementação · D2 comportamento diferente · D3 contrato diferente (assinatura, rota, schema, nome exportado, código de erro) · D4 valor fixo onde a SPEC pede regra ou configuração · D5 item de Fora de escopo implementado. Cada divergência diz `corrigir: spec` (há Decisão ou SPEC mais nova que justifica) ou `corrigir: código`. A última linha é `divergente` ou `sem divergência`. A skill grava `docs/specs/DRIFT.md` (substituído a cada execução, com data e commit) e não corrige nada.
O PLAN.md ([template](../plugins/kit/skills/plan/template.md)) é derivado de trás para frente: depois da linha `Revisão:`, `Abordagem` e `Reuso`, e então `must_haves` (truths verificáveis, artifacts com o que cada arquivo provê, tests com o que cada teste cobre), depois `Interfaces` com assinaturas, rotas, schemas e códigos de erro exatos. As tarefas ficam agrupadas em waves por dependência, com a linha `Paralelo:` dizendo quais podem rodar ao mesmo tempo, e cada uma tem `files`, `behavior` (cada linha vira teste), `action` (com o molde `arquivo:linha`), `verify` (chave do `kit.json`) e `done` (assertiva testável). Toda wave termina num checkpoint. A wave final é fixa: revisão pelo `kit:code-reviewer` e pelo `kit:security-reviewer`, correção de BLOCKER/MAJOR com nova revisão, verificação ponta a ponta da SPEC e `smoke` se o `kit.json` tiver. Só tarefas, checkpoints e passos da wave final levam caixa `- [ ]`, que é o que os hooks contam como progresso.
O `/kit:execute` segue as waves e só marca `[x]` com o `done` comprovado. No início de cada wave grava `Base: <hash>` no PLAN.md (`scripts/wave-base.sh`: uma árvore git do estado da pasta, sem commit e sem mexer no index). Antes de disparar as tarefas da linha `Paralelo:`, confere que os `files` são disjuntos: se forem, delega cada uma a um subagent `general-purpose`, todas na mesma mensagem, com o bloco fixo de `skills/execute/subagent-rules.md` no prompt (ler com Read, buscar com Grep/Glob, Bash só para git e comandos do `kit.json`, um comando por chamada sem `&&`, `;` ou `|`, sem `cd <repo>;`, nenhum comando com placeholder); se houver interseção, roda em sequência e registra em Decisões. O checkpoint só começa quando todas voltaram: re-roda os `verify` da wave, confere os `done`, chama o `kit:code-reviewer` sobre o diff da wave (`git diff <base> <agora>`) e corrige BLOCKER/MAJOR com nova revisão, e avalia o contexto: acima de ~70%, para e recomenda `/compact` seguido de `/kit:execute`, que retoma da próxima caixa. Plano no formato antigo (sem waves) roda tarefa a tarefa.
O `/kit:execute` segue a mesma regra para decisões que surgem na execução e também para antes de ação irreversível (deploy, push, chamada a serviço externo real, migração em banco real).

## Hooks

| Script | Evento | O que faz |
| --- | --- | --- |
| `guard-bash.sh` | PreToolUse `Bash` | Nega `rm -rf` fora do projeto, no próprio projeto ou em `/`, `~`, `..`; alvo não resolvível (variável em qualquer ponto do caminho, `$()`, crase, `xargs`, alvo relativo depois de `cd` para destino não resolvível); glob que apaga o projeto (`*`, `./*`, `*/`, `?*`, `sub/../*`, `<projeto>/*`). Acompanha `cd`/`pushd` dentro do comando e resolve alvos relativos contra a pasta corrente depois deles; caminho Windows (`C:\x`, `E:\\`) vira `C:/x` antes de resolver; `..` é resolvido em bash puro, sem `realpath`. Procura o comando depois de palavras-chave (`if`, `then`, `do`, `!`...) e de prefixos (`sudo -u`, `env VAR=x`, `nice -n`, `timeout`, `command`, `exec`, `xargs`). Nega também `git push --force`/`-f`/`+refspec`; `git reset --hard`; `git clean -fdx` (dry-run liberado); `DROP DATABASE/TABLE/SCHEMA`, `TRUNCATE` SQL; `curl`/`wget` com pipe para shell (inclusive `\| sudo bash`, `\| env bash`, `\| /usr/bin/env sh`, `\| tee f \| sh`) e `sh -c`/`eval` de `$(curl)` ou crase; `chmod -R 777`; `mkfs`; `dd of=/dev/*` (exceto `/dev/null`). Analisa o conteúdo de `sh -c`, `bash -c`, `$()`, crases e cadeias com `&&`, `;`, `\|`. Erro inesperado no script bloqueia (exit 2). |
| `guard-files.sh` | PreToolUse `Edit\|Write\|MultiEdit\|NotebookEdit` | Normaliza o caminho antes de casar (relativo ao `cwd` do hook, `..` mesmo por pasta inexistente, `//` colapsado) e, se for symlink, checa também o alvo final. Em Windows e macOS a comparação ignora maiúsculas (`.ENV`, `x.KEY`, `Secrets/`); no Windows, espaço ou ponto no fim do nome e fluxo alternativo (`.env::$DATA`) contam como o próprio arquivo. Nega escrita em `.env` e `.env.*` (exceto nome terminado em `.example`, `.sample`, `.template` ou `.dist`, como `.env.test.example`), `*.pem`, `*.key`, `secrets/`, sem exceção. Nega também `guards.deny_write` do `kit.json` (arquivo novo inclusive), e `guards.allow_write` libera o que casaria `protected_paths` (glob largo ignorado, com aviso na mensagem). Globs de `protected_paths` com `./`, `/` inicial ou `\` são normalizados. Erro inesperado no script bloqueia (exit 2). Nega Edit, e Write sobre arquivo existente, em `protected_paths` do `kit.json` mais próximo e dos `kit.json` acima dele até a pasta da sessão; Write de arquivo novo só é negado em item com `"write": "deny"`. Item com `message` usa esse texto na negação. A negação por `protected_paths` diz como liberar quando o arquivo não é segredo (`guards.allow_write`). |
| `format.sh` | PostToolUse `Edit\|Write` | Roda o formatter do primeiro glob de `format` que casa. Falha: exit 2 com as últimas 30 linhas. |
| `advise.sh` | PostToolUse `Edit\|Write` | Regras `coupled_changes` com `level: "warn"` cujo `when` casa com o arquivo editado viram `additionalContext` (JSON, porque stdout puro de PostToolUse não chega ao Claude). Uma vez por arquivo por sessão. Nunca bloqueia. |
| `verify-gate.sh` | Stop | Em cada repositório da sessão, se algum arquivo alterado (diff contra HEAD + não rastreados) casa `source_globs`, roda `verify_on_stop` em ordem até a primeira falha (últimas 60 linhas). Depois avalia `key_parity` e `coupled_changes` com `level: "block"`. Todas as falhas saem numa única mensagem com exit 2. Respeita `stop_hook_active`. Comandos já verificados com sucesso no mesmo estado não rodam de novo (marca em `.git/kit-verify-*`). Turno liberado com `notify.done`: notificação de concluído em segundo plano (`notify.sh --send`), sem atrasar o fim do turno. |
| `session-context.sh` | SessionStart (`startup\|resume\|compact\|fork`) | Injeta branch e `git status --short` de cada repositório, os planos ativos e as tarefas pendentes do mais recente. Na origem `compact`, inclui o snapshot do `pre-compact` se ele tiver menos de 2 horas. Sem `jq`, devolve JSON com a mensagem de instalação em `systemMessage` e `additionalContext`. Sem `git` ou com Claude Code abaixo de 2.1.295, avisa com o comando de correção e "rode /kit:setup". Com `docs/codemap.md` gerado pelo `/kit:map` (na raiz ou num repositório) mais de `map.stale_after_commits` commits atrás do commit do cabeçalho, sugere `/kit:map --update`; commit fora do histórico sugere `/kit:map`. Com `docs/stack.md` do `/kit:init` e manifesto alterado desde o commit do cabeçalho, escreve `Perfil do stack desatualizado (<manifestos>): rode /kit:init para reparar`. |
| `session-context.sh --plan-only` | UserPromptSubmit | Só a linha de planos ativos, e só se `inject_plan_on_prompt` for `true`; caso contrário não imprime nada. Com `notify.done`, grava `.claude/state/turn-start` (início do turno). |
| `notify.sh` | Notification (async) | Com `notify.waiting`, `⏳ <projeto>: <mensagem>`. Toast do Windows pelo `powershell.exe` (API `Windows.UI.Notifications`, sem módulo externo; no WSL pela interop, com as variáveis no `WSLENV`), `osascript` (JXA) no macOS, `notify-send` no Linux; sem nenhum, o sino do terminal. Push por ntfy (JSON) e webhook do Discord com `curl`, se as variáveis existirem. Título e mensagem chegam ao powershell/osascript por variável de ambiente, nunca no texto do comando. Timeout curto, falha calada, sempre exit 0. `--send` é a entrega usada pelo `verify-gate`; `KIT_NOTIFY_DRY_RUN=1` imprime o que rodaria. |
| `pre-compact.sh` | PreCompact | Grava `<raiz>/.claude/state/kit-snapshot.md` com data, branch, modificados e staged (até 20 cada) de cada repositório e os planos ativos. Sempre exit 0: nunca bloqueia a compactação. O `/kit:init` acrescenta `.claude/state/` ao `.gitignore`. |

Sem `jq`, os guardas bloqueiam com `kit: jq não encontrado — instale com <comando da plataforma> e reabra o Claude Code` (exit 2). Para não virar beco sem saída, o `guard-bash` lê o JSON cru e libera só o comando exato de instalação do `jq` da plataforma (`winget install jqlang.jq`; `brew install jq`; `sudo apt install jq`, `sudo apt-get install jq`, `sudo dnf install jq` ou `sudo pacman -S jq`), sem nada antes ou depois. O `session-context` devolve a mesma mensagem em `systemMessage` (o usuário vê ao abrir a sessão) e em `additionalContext` (o Claude recebe), num JSON montado sem `jq`. Os demais hooks saem com 0 sem fazer nada.

Os guardas devolvem `permissionDecision: "deny"` com o motivo; Claude recebe o motivo e ajusta. Com `onFailure: "block"` (Claude Code 2.1.295+), um guarda que não consegue rodar também bloqueia: script ausente, saída com código diferente de 0 e 2, timeout ou JSON inválido. No `Stop` o campo não tem efeito, segundo a doc oficial.

Os hooks usam a forma shell com `"shell": "bash"` explícito (`"command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh\""`, sem `args`). Na forma exec (`command` + `args`) o Claude Code procura `bash` no PATH, e no Windows isso falha com `Executable not found in $PATH: "bash"` quando o `Git\bin` não está no PATH; com `onFailure: "block"`, todo Bash/Edit/Write ficaria bloqueado. Na forma shell, o Windows roda o comando pelo Git Bash que o Claude Code localiza (o mesmo da ferramenta Bash; se não achar, `CLAUDE_CODE_GIT_BASH_PATH`), e o `bash` dentro da string é resolvido pelo PATH que o Git Bash monta.

## Modo adotar

Quando o repositório já tem configuração do Claude Code, o `/kit:init` não altera `CLAUDE.md`, skills, agents, commands, rules, hooks, `.mcp.json` nem `settings.local.json`; no `.claude/settings.json` só acrescenta (merge aditivo com backup). Detalhes em `plugins/kit/skills/init/adopt.md`.

1. **Inventário** com `scripts/inventory.sh`: hooks de todos os settings (projeto, local, usuário), skills, commands, agents, rules, CLAUDE.md, MCP e os arquivos que usam `curl`/`wget`.
2. **Classificação** de cada peça numa sugestão: manter no projeto, desativar a do projeto, desativar a do kit, declarar no `kit.json` (`coupled_changes`, `key_parity`, `protected_paths`), promover ao kit ou somar. Sobreposições (dois hooks bloqueando o mesmo, duas skills de review) ganham uma dona sugerida.
3. **Prova de equivalência** para sugerir desativar um hook do projeto: o mesmo cenário passa pelo hook original e pelo do kit (ou pelo `verify-gate` num worktree descartável) e precisa dar o mesmo bloqueio. Sem prova, a sugestão vira "manter".
4. **Gravação**, na confirmação única: `.claude/kit.json` com as declarações e o merge aditivo no `.claude/settings.json` (`merge-json.sh --apply`), incluindo os `permissions.deny` das sobreposições.
5. **Relatório** em `docs/claude-adoption.md`: peça, destino e prova, sobreposições com a dona e, quando é uma peça do projeto que sobra, como desligá-la, e o diff do que foi somado ao settings.

O inventário também detecta, com uma sugestão para cada item:
- **Sobreposição de skills e agents** com os do kit. Se a skill do projeto tem `disable-model-invocation: true` e a do kit não, o Claude escolhe sozinho a do kit (ex.: `kit:fix` para "corrige esse bug"). A peça do projeto é a dona, e `Skill(kit:<nome>)` ou `Agent(kit:<nome>)` entram em `permissions.deny` pelo merge aditivo.
- **Aviso possivelmente mudo**: hook PreToolUse, PostToolUse ou Stop que imprime texto no stdout sem JSON `additionalContext`; com exit 0 esse texto não chega ao Claude.
- **Falha aberta**: hook PreToolUse com `jq ... || exit 0`, que libera tudo sem jq.
- **Outros riscos**, só listados: skill com efeito colateral sem `disable-model-invocation`, `settings.local.json` versionado, regra com a sintaxe antiga `:*` e ausência de deny de leitura para segredos.

Grupo `curl-wget`: antes de oferecê-lo, o init (nos três modos) roda `inventory.sh --net`, que lista os arquivos que usam `curl` ou `wget` em `.claude/skills`, `.claude/agents`, `.claude/commands`, `.claude/hooks`, nos comandos de hook dos settings e nos scripts que eles chamam, nos scripts do `package.json`, no `Makefile` e no `justfile`. Com qualquer arquivo listado (ou `commands.smoke` usando um dos dois), o grupo não é oferecido e o relatório tem a linha `curl/wget usados por N arquivos do projeto; deny não aplicado`. Sem nenhum, ele entra na pergunta de grupos e, marcado, `Bash(curl *)` e `Bash(wget *)` entram pelo merge aditivo.

Listas de bloqueio do projeto viram `protected_paths` em forma de objeto no `kit.json`, com a mesma mensagem que o hook original mostrava; o hook continua registrado.

Regras de escrita do kit, em todo comando: nunca editar, desativar ou apagar `CLAUDE.md`, `settings.local.json`, `.mcp.json`, skills, agents, commands, rules e hooks existentes. `.claude/settings.json` recebe só merge aditivo, com backup e diff na confirmação única; o settings do usuário nunca é gravado. Nenhum comando entregue ao usuário tem placeholder (`<...>`, `SEU_X`, `xxx`): o valor é perguntado antes e gravado na config do projeto (segredo em `.env`, carregado pelo script). `CLAUDE.md` e settings ausentes podem ser criados. Arquivos do kit podem ser regravados.
