# Referência do kit

Detalhe completo de configuração e comportamento. Para instalar e usar, comece pelo [README](../README.md).

## O contrato `.claude/kit.json`

```json
{
  "commands": {
    "build": "dotnet build --nologo -v q",
    "test": "dotnet test --nologo",
    "test_related": "dotnet test --nologo --filter {files}",
    "lint": { "run": "npx eslint {files}", "files": ["**/*.{ts,tsx}"] },
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
  "verify_on_stop": ["build", "test_related", "lint"],
  "source_globs": ["**/*.cs", "**/*.ts"],
  "coupled_changes": [
    { "when": ["src/views/**", "src/widgets/**"],
      "require": ["manual/**"],
      "level": "block",
      "message": "Telas mudaram; atualize o manual para refletir as telas atuais.",
      "hint": "o manual de cada tela fica em manual/<tela>.md" },
    { "when": ["api/src/**"], "require": ["web/src/pages/**"],
      "level": "warn", "message": "Se o formato da resposta mudou, ajuste os fetch do site." },
    { "when": ["src/**/*.cs"], "require": ["tests/**"],
      "level": "warn", "message": "Código mudou; se o comportamento mudou, o teste muda junto." }
  ],
  "diff_deny": [
    { "pattern": "@ts-ignore|@ts-nocheck|eslint-disable", "files": ["**/*.{ts,tsx}"], "level": "block",
      "message": "Supressão nova. Corrija a causa; se for inevitável, justifique em .claude/kit-skip." }
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
  "map": { "stale_after_commits": 50, "unit_max_files": 150, "unit_max_loc": 20000, "max_agents": 30 },
  "ui": { "globs": ["web/src/**/*.{tsx,css}"], "dev": "npm --prefix web run dev", "url": "http://localhost:5173",
    "routes": ["/", "/login"], "viewports": ["360x800", "768x1024", "1280x800", "1920x1080"] }
}
```

- Comandos rodam com `bash -c` na pasta que contém o `.claude/` do `kit.json`.
- `smoke` é opcional e só o `/kit:execute` usa, no último passo da wave final do plano.
- `{files}` vira a lista de caminhos relativos, cada um entre aspas simples.
- O valor de um comando é texto ou um objeto `{ "run": "<comando>", "files": [<globs>] }`. Na forma objeto, o gate só roda o comando quando algum alterado casa `files`, e `{files}` recebe só esses; os globs de `files` valem no lugar de `source_globs` para ele. Serve para o lint de uma linguagem num repositório com duas. Skills e agents que rodam um comando do `kit.json` usam o `run`.
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
- `setup.sh guards` aponta cada entrada ignorada ou sem glob, cada grupo desconhecido, campo com tipo errado (`protected_paths`, `source_globs`, `verify_on_stop`, `repos`, `plan_dirs`, `coupled_changes`, `key_parity` e `diff_deny` são listas; `commands` é objeto, e cada valor é texto ou objeto com `run` e `files` em lista), chave de `verify_on_stop` sem comando em `commands`, `verify_on_stop` sem `source_globs` (citando os comandos sem `files`, que são os que não rodam), regra de `diff_deny` sem `pattern`, com `pattern` que não é ERE válido, `files` fora de lista ou `level` fora de `block`/`warn`, e entrada de `repos` que não é repositório git. `kit.json` que não é JSON válido sai com 2.
- `kit.json` ilegível (JSON inválido) ou com `protected_paths`/`guards` de tipo errado: o `guard-files` nega toda escrita nessa pasta, menos no próprio `.claude/kit.json`; o `verify-gate` acusa a pasta como falha; o `session-context` avisa ao abrir a sessão.

### Planos ativos

O `session-context` e o `pre-compact` mostram até 3 planos ativos com a contagem "feitas/total" e as tarefas pendentes do mais recente. Plano ativo é um `docs/specs/**/PLAN.md` (na raiz da sessão ou em qualquer repositório dela), ou um `.md` dos diretórios de `plan_dirs`, modificado nos últimos 14 dias e com tarefa `- [ ]` pendente. Com `"inject_plan_on_prompt": true`, a linha de planos ativos entra também em cada mensagem (UserPromptSubmit); custa contexto a cada turno, então fica desligado por padrão.

### Checks de domínio (opcionais)

Avaliados pelo `verify-gate` sobre os arquivos alterados (diff contra HEAD + não rastreados). Projeto que não declara as chaves não é afetado.

- **`coupled_changes`**: cada regra tem um `level`.
  - `"block"` (padrão): no Stop, se algum arquivo alterado casa um glob de `when` e nenhum casa `require`, o gate bloqueia com `message`, a lista dos arquivos que dispararam a regra e o `hint`, se houver.
  - `"warn"`: o `verify-gate` ignora a regra. Na edição (PostToolUse) de um arquivo que casa `when`, o `advise.sh` injeta no contexto do Claude `[kit] <message> | verificar: <require> | editado: <arquivo> | dica: <hint>`, como fato e não como ordem. Não bloqueia nada e aparece uma vez por arquivo por sessão. Arquivo editado que também casa `require` (o próprio par) não avisa: a regra "código mudou sem teste" (`when` no código, `require` nos testes) funciona mesmo com o teste ao lado do código.
- **`key_parity`**: só roda se algum dos `files` mudou. Achata as chaves aninhadas com `.` e lista cada chave ausente e em quais arquivos (`home.welcome falta em en.json, es.json`). Arquivo listado inexistente ou JSON inválido também é falha. Quando dois arquivos têm o mesmo nome (`pt/common.json`, `en/common.json`), o rótulo é o caminho declarado.
- **`diff_deny`**: padrões proibidos nas linhas adicionadas no turno. Cada regra tem `pattern` (ERE, conferido com `grep -E` só sobre o texto da linha, então `^` e `$` valem para o código), `files` (globs; sem `files`, vale para todo alterado), `message` e `level`.
  - Linhas adicionadas: diff contra o início do turno (o HEAD gravado no UserPromptSubmit pela sessão; sem a marca, o HEAD), então linha commitada durante o turno conta e linha que já estava no commit de base não. O que está sem commit continua contando nos turnos seguintes, e arquivo não rastreado conta inteiro, mesmo sem ter sido tocado no turno. Binário e o próprio `.claude/kit.json` ficam de fora.
  - `"block"` (padrão): no Stop, o gate bloqueia com `message` e até 20 linhas `arquivo:linha: trecho`, mais a contagem do resto. `pattern` inválido também é falha.
  - `"warn"`: o gate ignora. Na edição de um arquivo que casa `files`, o `advise.sh` injeta `[kit] <message> | editado: <arquivo> | linhas novas: <n, n>` quando o padrão está numa linha nova; as mesmas linhas (pelo texto, mesmo que mudem de número) não repetem na sessão.
  - Padrões de partida por stack (supressão de lint e de tipo, teste pulado ou focado) em [`stacks.md`](../plugins/kit/skills/init/stacks.md).
- **Válvula de escape**: `.claude/kit-skip` com uma linha de justificativa libera `coupled_changes` e `diff_deny` (não libera `key_parity` nem os comandos). Quando o gate passa, o arquivo é apagado e a justificativa vai para a seção "Registro de kit-skip" de `docs/claude-adoption.md`, ou para `.claude/kit-skip.log` se aquele não existir. Se outra checagem falhar no mesmo turno, o `kit-skip` é mantido até o gate passar. Arquivo vazio não libera. A liberação vale para aquele turno: enquanto a mudança estiver sem commit, a regra volta a disparar nos turnos seguintes, até o commit ou a correção.
- **Ordem**: comandos de `verify_on_stop`, depois `key_parity`, `coupled_changes` e `diff_deny`. Todas as falhas do turno saem numa única mensagem numerada.

### Workspace com vários repositórios

Numa pasta-mãe com repositórios filhos independentes (ex.: `workspace/` com `app/` e `web/`, cada um com seu `.git`), abra a sessão na pasta-mãe. Os hooks descobrem os repositórios:
- o repositório do próprio `cwd`, se houver;
- os filhos: diretórios com `.git` (pasta ou arquivo) até 3 níveis, ignorando `node_modules`, `target`, `dist`, `build`, `vendor`, `.venv` e o que o `.gitignore` do pai ignorar;
- ou só os listados em `"repos": ["app", "web"]` no `kit.json` da pasta-mãe, que tem prioridade sobre a descoberta.

A descoberta tem cache por sessão em `$TMPDIR`, invalidado quando o `kit.json` da pasta-mãe muda. O `verify-gate` refaz a descoberta a cada Stop, então repositório criado durante a sessão entra na verificação. Entrada de `repos` sem `.git` é ignorada, com aviso no `session-context` e no `setup.sh guards`. Os arquivos de cache e de aviso do `advise` com mais de um dia são apagados no SessionStart.

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
| `done` | `false` | Fim de turno liberado pelo `verify-gate` com a verificação verde (gate passou ou não havia o que verificar, inclusive na segunda passada com `stop_hook_active`): `✅ <projeto> (<branch>): concluído em <duração>`. Nunca quando o gate bloqueia, quando a segunda passada termina vermelha, nem no `SubagentStop` |
| `done_min_seconds` | 60 | Turno mais curto não notifica. O início vem de `.claude/state/turn-start`, gravado no UserPromptSubmit (mtime = início, conteúdo = `session_id`; de outra sessão, não notifica) |
| `sound` | `false` | Som do sistema: toast com som no Windows, `soundName` no macOS, `canberra-gtk-play`/`paplay` no Linux |
| `push.ntfy_topic_env` | `KIT_NTFY_TOPIC` | Nome da variável de ambiente com o tópico do ntfy (ou a URL `https://servidor/topico`). Só com `push` presente e a variável definida |
| `push.discord_webhook_env` | `KIT_DISCORD_WEBHOOK` | Nome da variável com a URL `https://` do webhook do Discord, enviada sem menções |

O valor do tópico e do webhook nunca fica no `kit.json`, só o nome da variável. Destino inválido (tópico com caractere fora de letras, números, `_` e `-`, URL do ntfy sem tópico, webhook sem `https://`) não é enviado e gera `push ignorado: <motivo>` com o nome da variável, nunca o valor: no stdout com `KIT_NOTIFY_DRY_RUN=1`, no stderr fora dele. Barra no fim da URL do ntfy é ignorada.

### `spec` e `plan`

Limites de tamanho, todos opcionais:

| Chave | Padrão | Efeito |
| --- | --- | --- |
| `spec.max_scope_items` | 8 | Itens de Escopo acima disso: o `/kit:spec` não grava uma SPEC única e pergunta |
| `spec.max_files` | 25 | Arquivos afetados (contados pelo `kit:investigator`) acima disso: idem |
| `plan.max_tasks` | 15 | Tarefas numeradas acima disso: o `/kit:plan` não grava e pergunta |
| `plan.max_waves` | 6 | Waves (sem a wave final) acima disso: idem |

Mais de 2 repositórios tocados também conta como acima do limite no `/kit:spec`. A pergunta é única, com três opções: quebrar em fatias agora (recomendada, com as fatias já sugeridas), manter numa só ou reduzir escopo. Na quebra, você não roda o `/kit:epic`: a própria skill lê o `SKILL.md` dele e segue os passos de gravação (`EPIC.md` e uma SPEC por fatia) na mesma sessão, sem nova entrevista. Manter grava e registra em Decisões `- <data> · usuário · tamanho: manter ... — acima do limite`; o `/kit:plan` e o `kit:plan-reviewer` (regra M8) aceitam essa linha na SPEC.md ou no PLAN.md.

### `ui`

Só em projeto com tela. Ausente, nenhum passo de interface roda; `false` registra que o `/kit:init` propôs e o usuário recusou.

| Chave | Padrão | Efeito |
| --- | --- | --- |
| `globs` | obrigatória | Arquivos de tela, componente e estilo. Tarefa, wave ou plano que toca um deles conta como de interface |
| `dev` | sem | Comando que sobe o app. A captura só o roda se `url` não responde, e derruba o que subiu |
| `url` | sem | Endereço do app. Sem `dev`, o app precisa já estar rodando |
| `routes` | `["/"]` | Rotas capturadas quando a SPEC não lista telas |
| `viewports` | `360x800`, `768x1024`, `1280x800`, `1920x1080` | Tamanhos das imagens, `<largura>x<altura>`. A sondagem percorre mais larguras entre eles |
| `screenshot` | sem | Comando do projeto que grava a imagem da tela em `{out}` (aceita `{url}`, `{width}` e `{height}`). Com ele a captura é só esse comando, sem navegador e sem sondagem. Para tela que não abre em navegador |

`setup.sh guards` aponta `ui` que não é objeto nem `false`, `ui` sem `globs`, lista ou texto com tipo errado, `viewports` fora de `<largura>x<altura>`, `url` sem `http://` ou `https://`, `dev` sem `url` e `screenshot` sem `{out}`.

### `map`

Limites do `/kit:map`, todos opcionais, lidos do `kit.json` da pasta da sessão:

| Chave | Padrão | Efeito |
| --- | --- | --- |
| `stale_after_commits` | 50 | Acima disso, o `session-context` avisa que o `docs/codemap.md` está atrasado e sugere `/kit:map --update` |
| `unit_max_files` | 150 | Unidade com mais arquivos é subdividida |
| `unit_max_loc` | 20000 | Unidade com mais linhas é subdividida |
| `max_agents` | 30 | Acima disso, o `/kit:map` pergunta antes de lançar, com o custo estimado |
| `primary` | o repositório da pasta, ou o primeiro de `repos` | Repositório onde fica o `docs/codemap.md` |

## Init, setup e map

O kit nunca grava o settings do usuário (`~/.claude/settings.json` ou o de `CLAUDE_CONFIG_DIR`), em nenhum fluxo, e só lê dele os alertas que já existem (`setup.sh alerts`). O `/kit:setup` só verifica (`setup.sh check`/`status`: Claude Code mínimo, `git`, `bash`, `jq`, `bwrap`/`socat` no Linux/WSL2, plataforma, aviso de sandbox e o marketplace `claude-kit` registrado). O `/kit:init` é a porta de entrada; em pasta vazia ele primeiro cria o esqueleto do projeto ([Modo do zero](#modo-do-zero)). Ele roda `scripts/setup.sh status` e põe o comando de instalação de cada dependência que falta na confirmação. Depois configura o projeto (novo, adotar ou reparo), detecta o plugin LSP com `setup.sh lsp` (oficial, menos Node/TS, que usa o `ts-lsp@claude-kit` com teto de memória; ver README, seção "LSP de TypeScript com teto de memória") em projeto com tela propõe o `ui` e a rule `.claude/rules/kit-ui.md`, que o reparo recria ou atualiza quando o `ui.sh status` diz `rule: ausente` ou `rule: desatualizada` ([Interface](#interface)), e junta tudo numa confirmação única (`AskUserQuestion` com a gravação, os grupos de permissão em `multiSelect` e as decisões que são do usuário). Habilitar o kit num projeto é o equivalente à instalação `--scope project`: `enabledPlugins` e `extraKnownMarketplaces` no `.claude/settings.json` do projeto.

**Grupos de permissão** (`templates/project-permissions.json`). `setup.sh groups` lista os grupos desta plataforma (`<id><TAB><rótulo> — <descrição>`): `segredos` (Read de `.env`, `.env.local`, `.env.*.local`, `.env.test`, `.env.production`, `.env.development`, `.env.staging`, `**/*.pem`, `**/*.key`, `**/secrets/**`, `~/.ssh/**`, `~/.aws/**`, `~/.kube/**`, `~/.git-credentials`, `~/.npmrc`, `~/.config/gh/**`, `~/.docker/config.json`; nomes explícitos, nunca `.env.*`, que bloquearia a leitura de `.env*.example` sem exceção possível em deny; com o grupo marcado, o `guard-bash` nega a leitura dos mesmos nomes pelo shell), `git-destrutivo` (`push --force`/`-f`, `reset --hard`, `clean -fdx`), `push` (ask de `git push`), `curl-wget` (deny; só oferecido sem uso detectado pelo `inventory.sh --net` nem no `commands.smoke`), `powershell` (só Windows nativo) e `sandbox` (só macOS e Linux/WSL2 com `bwrap` e `socat`: `enabled`, `failIfUnavailable: true`, credenciais negadas e ask de `dangerouslyDisableSandbox`). `setup.sh permissions <id,id,...> <proposta>` acrescenta à proposta só os grupos marcados, pelo mesmo merge aditivo (`-` é nenhum; grupo fora da plataforma vira `fora: <id>`; id desconhecido sai com 2). A escolha fica em `permissions.groups` do `kit.json`; no reparo, `setup.sh permissions --kit .claude/kit.json <proposta>` usa só esses ids, então grupo desmarcado antes não volta (sem a chave, exit 3 e o init pergunta).

**Guards** (`guards` no `kit.json`, conferidos por `setup.sh guards [kit.json]`). `allow_write`: caminhos ou globs liberados para escrita mesmo casando `protected_paths`. Glob largo (`*`, `**`, `**/*`, `.env*`, `*.env` e só curingas) é ignorado no init, no reparo e no próprio `guard-files`, que diz na mensagem de bloqueio qual entrada ignorou. Segredo de verdade não tem exceção: `.env`, `.env.<qualquer>` sem sufixo de exemplo, `*.pem`, `*.key`, `keys/` e `secrets/` continuam bloqueados mesmo listados, e o `setup.sh guards` devolve `ignorado: ... — segredo não tem exceção`. `deny_write`: caminhos extras bloqueados (também arquivo novo), string ou `{ "glob", "message" }`; vence `allow_write`. Nome terminado em `.example`, `.sample`, `.template` ou `.dist` (ex.: `.env.test.example`) não é segredo. O bloqueio por `protected_paths` termina com "Se este arquivo não é segredo, adicione o caminho em guards.allow_write no .claude/kit.json." Com o "sim", grava, instala, roda cada comando de `verify_on_stop` e, com mais de 300 arquivos de código (contados pelo `map-partition.sh`) ou mais de um repositório, segue o fluxo do `/kit:map` sem perguntar. Com `.claude/kit.json` já presente, entra em modo reparo: valida `kit.json`, comandos, settings e `.gitignore`, soma o que falta pela mesma confirmação e roda o `/kit:map --update` quando `map-partition.sh --status` aponta atraso. O relatório final tem no máximo ~10 linhas (feito, verificado, avisos, planos parados há mais de 14 dias pelo `setup.sh plans`) e termina em `Pronto. Próximo: /kit:spec <ideia>`.

**Merge aditivo dos settings** (`scripts/merge-json.sh`). `--preview` mostra o diff e as linhas `conflito:`; `--apply` grava. Objetos são mesclados chave a chave, arrays por união sem duplicar, chave ausente entra, valor existente sempre vence e a chave `hooks` da proposta é ignorada. Regra nova de `permissions.deny` que sombrearia uma regra de `allow` ou `ask` do mesmo arquivo (mesma ferramenta e o padrão do deny casa com o padrão existente: `Bash(curl *)` cobre `Bash(curl *x.com*)`; a sintaxe antiga `curl:*` vale como `curl *`) não entra, porque deny vence e o merge mudaria o comportamento; sai a linha `conflito: deny <regra> não aplicado — sombrearia <regra existente> em <allow|ask>`. O `--check` também acusa deny novo que sombreia regra de antes. Regras de `allow`/`ask` com `curl`/`wget` (projeto, local ou usuário, só lidas) também contam no `inventory.sh --net`, e o grupo `curl-wget` não é oferecido. Antes de gravar, backup em `<arquivo>.bak-kit-<AAAA-MM-DD>` (já existindo, com a hora no nome); se o resultado perderia ou trocaria algo (`--check`), nada é gravado. `settings.local.json` é recusado.

### `/kit:map`

1. **Partição** (`scripts/map-partition.sh`, sem LLM): `git ls-files` de cada repositório da sessão, filtrado por `source_globs` e sem `node_modules/`, `vendor/`, `dist/`, `build/`, `target/`, gerados, lockfiles, binários, `protected_paths`, `.env*`, `secrets/`, `keys/` e o próprio `.claude/`. Unidade inicial é o pacote (pasta com manifesto) ou a pasta de topo; acima do limite, subdivide pelas subpastas (pasta só com arquivos diretos vira fatias); vizinhas pequenas com a mesma pasta-mãe são agrupadas até o limite. Saída JSON com `repo`, `unit`, `paths[]` (a maior pasta que só tem arquivos daquela unidade, ou o arquivo), `file_count`, `loc` e `manifests`. `--path` limita a uma área; `--since [<repo>=]<commit>` marca `changed` nas unidades com arquivo alterado (commits e working tree); `--status` diz se o codemap está ausente, em dia ou atrasado.
2. **Mapeadores**: um `kit:mapper` por unidade, em ondas de até 8 na mesma mensagem. O agent só tem Read, Grep e Glob e devolve um schema fixo de até 60 linhas (responsabilidade, entradas, interfaces, dependências, convenções, armadilhas, testes, confiança), cada afirmação com `arquivo:linha`.
3. **Transversais**: `kit:mapper` no modo integração (contratos entre unidades e repositórios, com divergências e evidência dos dois lados) e no modo fluxos (3 a 5 fluxos ponta a ponta).
4. **Verificação**: `kit:map-verifier`, que não produziu o mapa, abre ~5 afirmações por unidade e todas as transversais. Reprovada sai; unidade com mais de 30% de reprovação é remapeada uma vez.
5. **Escrita**, sem pedir aprovação (fica no git): `.claude/rules/map-<unidade>.md` (frontmatter `paths:`, até 40 linhas) no repositório da unidade, `docs/codemap.md` (até 150 linhas) no repositório principal e `.claude/rules/kit-codemap.md` sem `paths:` (carrega sempre, aponta para o codemap) em cada repositório; o `CLAUDE.md` não é tocado. Todo arquivo gerado leva `<!-- kit:map v1 · <data> · <commit> -->`; blocos entre `<!-- manual -->` e `<!-- /manual -->` são preservados; rule sem esse cabeçalho nunca é sobrescrita (o kit grava `map-<unidade>.kit.md` e avisa).

O total de agents é unidades + 2 transversais + um verificador a cada 8 unidades. O `--update` lê o commit do cabeçalho, passa ao script com `--since` e remapeia só as unidades alteradas, novas ou com `paths` diferentes; refaz os transversais só se interfaces ou dependências mudaram. Os investigadores de `/kit:plan`, `/kit:fix` e `/kit:hunt` leem o `docs/codemap.md` antes de explorar e confiam no código quando divergem.

## Plan e execute

O `/kit:plan` não pede revisão do plano. Lacuna técnica (nome de campo, parâmetro, flag, pasta, biblioteca já prevista) ele decide pelo padrão mais simples coerente com os docs, registra em "Decisões" do PLAN.md com data, origem e motivo e atualiza o doc de referência quando houver. Ele só pergunta em decisão de produto (o que o usuário vê, regra de negócio), escopo fora da SPEC ou decisão cara de reverter (schema público, contrato de API, dependência nova). Plano acima de `plan.max_tasks` (15) ou `plan.max_waves` (6) não é gravado sem a escolha do usuário (ver [`spec` e `plan`](#spec-e-plan)). Antes de entregar, o `kit:plan-reviewer` confere o plano contra a SPEC e a skill corrige o que ele apontar; você recebe um resumo de até 5 linhas.

### Severidade dos revisores

O `kit:spec-reviewer`, o `kit:plan-reviewer`, o `kit:code-reviewer`, o `kit:security-reviewer` e o `kit:ui-reviewer` não classificam no julgamento: cada regra tem um id com severidade fixa, todo achado cita o id (`BLOCKER [B1] — tarefa 3, wave 1 — ...`) e herda a severidade dele. É proibido rebaixar; na dúvida entre dois ids vale o mais grave; MINOR (`[-]`) é só o que não casa com nenhum id (redação, organização, melhoria opcional). A última linha da resposta é `aprovado` ou `reprovado` (qualquer BLOCKER ou MAJOR). O `/kit:plan` e o `/kit:execute` corrigem todo BLOCKER e MAJOR e chamam de novo até `aprovado`.

| Revisor | BLOCKER | MAJOR |
| --- | --- | --- |
| `spec-reviewer` | B1 Objetivo ausente ou sem problema e resultado · B2 item de Escopo ou caso de borda com duas leituras para o usuário · B3 Verificação ponta a ponta ausente ou não observável · B4 contradição interna · B5 contrato que conflita com o código sem dizer que muda | M1 cria o que o código já tem · M2 escopo especulativo · M3 otimização sem gargalo citado · M4 termo do projeto sem definição · M5 pré-requisito não declarado · M6 SPEC trata como existente o que não existe · M7 lógica fora da camada do padrão · M8 caso de borda de uso normal ausente · M9 Objetivo promete o que o Escopo não entrega nem exclui · M10 feature com tela sem a seção Telas ou sem vazio, carregando ou erro alcançável · M11 tela sem ação principal ou fluxo, ou sem dizer como fica na tela pequena |
| `plan-reviewer` | B1 tarefa usa algo da mesma wave ou de wave posterior · B2 tarefas de `Paralelo:` com arquivo em comum · B3 Escopo, caso de borda, estado de tela ou Verificação ponta a ponta sem truth · B4 decisão de produto, fora da SPEC ou cara de reverter com origem `kit` · B5 migração ou alteração de dados persistentes sem backup ou rollback na própria tarefa · B6 `verify` com chave fora do `kit.json` · B7 Interfaces divergem da SPEC · B8 caixa `- [ ]` fora de tarefa, checkpoint ou wave final | M1 truth sem teste ou artifact fora de `files` · M2 caso de borda sem behavior/teste · M3 behavior só manual quando dá para automatizar · M4 molde `arquivo:linha` inexistente · M5 tarefa grande demais · M6 tarefa sem um dos campos ou `done` não testável · M7 doc de referência ou `coupled_changes` afetado sem tarefa · M8 plano acima de `plan.max_tasks`/`max_waves` sem Decisão do usuário · M9 tarefa de tela sem behavior de estado ou sem o molde existente em `action` |
| `code-reviewer` | B1 requisito da tarefa/SPEC não implementado · B2 segredo exposto ou entrada não validada em fronteira · B3 teste quebrado, removido ou enfraquecido · B4 mudança fora do escopo que altera comportamento · B5 contrato de Interfaces alterado sem registro em Decisões | M1 caso de borda sem teste · M2 erro engolido ou sem tratamento · M3 arquivo acoplado (`coupled_changes`/`key_parity`) não atualizado · M4 `done` marcado sem evidência · M5 duplica o que já existe (com o `arquivo:linha` do original) · M6 supressão nova sem justificativa na mesma linha · M7 teste que não falharia sem a implementação · M8 dependência nova fora do plano e da SPEC |
| `security-reviewer` | B1 injeção com entrada externa · B2 path traversal ou SSRF · B3 operação sem checagem de permissão ou IDOR · B4 segredo no código | M1 dado sensível em log ou resposta · M2 stack trace exposto · M3 validação de entrada incompleta sem caminho de injeção |
| `ui-reviewer` | B1 tela, estado ou passo da seção Telas ausente · B2 layout quebrado em algum tamanho · B3 controle sem nome acessível ou só de mouse | M1 contraste · M2 alvo de toque · M3 valor solto onde há token ou componente · M4 tela que destoa das existentes · M5 hierarquia e ação principal · M6 retorno ausente · M7 tela pequena mal resolvida · M8 estrutura (alt, rótulo, títulos, `lang`, viewport, foco) · M9 erro de console, requisição ou rota |

O `tests/run-reviewers-live-test.sh` calibra os revisores com uma SPEC (contradição, módulo reinventado e cache sem gargalo: `B4`, `M1`, `M3`), um plano e um diff com defeitos plantados (precisam sair com o id certo e `reprovado`), um diff com os defeitos de qualidade do `code-reviewer` (utilitário duplicado, supressão sem justificativa, teste sobre o próprio mock e dependência nova: `M5` a `M8`) e um plano e um diff limpos (precisam sair `aprovado`); o plano limpo com `plan.max_tasks` baixo precisa sair com `MAJOR [M8]`, e com a Decisão `tamanho: manter` do usuário, `aprovado`. O mesmo teste confere o `kit:drift-checker`: a feature implementada fiel à SPEC sai `sem divergência`, e com o limite do apelido trocado sai `DIVERGÊNCIA [D2]`. E o `kit:ui-reviewer`, com capturas de verdade de uma tela com defeitos plantados (`B2`, `B3`, `M1`) e de uma tela limpa, e a SPEC de tela sem estados (`M10`).

O `kit:spec-reviewer` começa parafraseando o que a SPEC propõe e como o sistema funciona segundo ela; se não consegue parafrasear o Objetivo, é B1. Ele lê o CLAUDE.md e o código (Read, Grep, Glob), mas não a conversa: o leitor sem contexto é da entrevista, não do projeto. M1 e M7 só valem com o `arquivo:linha` do que já existe. Lacuna técnica que o `/kit:plan` decide sozinho (unidade de contagem, trim, formato interno, erro de arquivo local) é no máximo MINOR: o revisor julga se a SPEC basta para planejar sem adivinhar a intenção do usuário, não se é perfeita. Achado cuja correção é escolha de produto sai marcado `(decisão de produto)`, e o `/kit:spec` pergunta ao usuário em vez de decidir.

### Drift

O `/kit:drift` confere só SPECs com `PLAN.md` sem nenhuma caixa `- [ ]` (ou a SPEC passada no argumento) e chama um `kit:drift-checker` por SPEC, até 8 por mensagem. O checker (Read, Grep, Glob) lista as promessas da SPEC e das `Interfaces` do plano, acha onde cada uma está no código e reporta só o que diverge: D1 item de Escopo ou caso de borda sem implementação · D2 comportamento diferente · D3 contrato diferente (assinatura, rota, schema, nome exportado, código de erro) · D4 valor fixo onde a SPEC pede regra ou configuração · D5 item de Fora de escopo implementado. Cada divergência diz `corrigir: spec` (há Decisão ou SPEC mais nova que justifica) ou `corrigir: código`. A última linha é `divergente` ou `sem divergência`. A skill grava `docs/specs/DRIFT.md` (substituído a cada execução, com data e commit) e não corrige nada.
O PLAN.md ([template](../plugins/kit/skills/plan/template.md)) é derivado de trás para frente: `must_haves` no topo (truths verificáveis, artifacts com o que cada arquivo provê, tests com o que cada teste cobre), depois `Interfaces` com assinaturas, rotas, schemas e códigos de erro exatos. As tarefas ficam agrupadas em waves por dependência, com a linha `Paralelo:` dizendo quais podem rodar ao mesmo tempo, e cada uma tem `files`, `behavior` (cada linha vira teste), `action` (com o molde `arquivo:linha`), `verify` (chave do `kit.json`) e `done` (assertiva testável). Toda wave termina num checkpoint. A wave final é fixa: revisão pelo `kit:code-reviewer` e pelo `kit:security-reviewer`, correção de BLOCKER/MAJOR com nova revisão, verificação ponta a ponta da SPEC e `smoke` se o `kit.json` tiver. Só tarefas, checkpoints e passos da wave final levam caixa `- [ ]`, que é o que os hooks contam como progresso.
O `/kit:execute` segue as waves e só marca `[x]` com o `done` comprovado. No início de cada wave grava `Base: <hash>` no PLAN.md (`scripts/wave-base.sh`: uma árvore git do estado da pasta, sem commit e sem mexer no index; cada chamada deixa alguns objetos inalcançáveis no `.git`, que o `git gc` automático recolhe). Antes de disparar as tarefas da linha `Paralelo:`, confere que os `files` são disjuntos: se forem, delega cada uma a um subagent `general-purpose`, todas na mesma mensagem, com o bloco fixo de `skills/execute/subagent-rules.md` no prompt (ler com Read, buscar com Grep/Glob, Bash só para git e comandos do `kit.json`, um comando por chamada sem `&&`, `;` ou `|`, sem `cd <repo>;`, nenhum comando com placeholder); se houver interseção, roda em sequência e registra em Decisões. O checkpoint só começa quando todas voltaram: re-roda os `verify` da wave, confere os `done`, chama o `kit:code-reviewer` sobre o diff da wave (`git diff <base> <agora>`) e corrige BLOCKER/MAJOR com nova revisão, e avalia o contexto: acima de ~70%, para e recomenda `/compact` seguido de `/kit:execute`, que retoma da próxima caixa. Plano no formato antigo (sem waves) roda tarefa a tarefa.
O `/kit:execute` segue a mesma regra para decisões que surgem na execução e também para antes de ação irreversível (deploy, push, chamada a serviço externo real, migração em banco real).

## Interface

Vale em projeto com `ui.globs` no `kit.json`. O `/kit:init` propõe a chave quando o `ui.sh status` acha arquivo de interface.

### `ui.sh status`

Uma linha por item, só leitura:

- `ui: <N> arquivos de interface (<ext> <n>, ...)`, `ui globs:` e `ui pastas:`, pelas extensões de `templates/ui-markers.txt` (fora `node_modules`, `dist`, `build`, `vendor`, testes e stories);
- `ui design:` com biblioteca de componentes, tema e tokens achados pelo nome do arquivo (só em arquivo de estilo, de código de tela, JSON ou YAML; teste e story não contam) ou pelas dependências do `package.json`;
- `node:` e `navegador:`, o que a captura do kit precisa (`node` 16 ou mais novo e Chrome, Edge, Chromium ou o Chromium do Playwright);
- `captura: comando | kit | nenhuma`;
- `rule:`, só com `ui.globs` no `kit.json`, o estado da `.claude/rules/kit-ui.md`: `ok`, `ausente`, `desatualizada — <motivo>` (cabeçalho `kit:ui` de versão menor que a do template, bloco de regras diferente do `ui-rules.md` atual, ou `paths:` sem um glob de `ui.globs`) ou `do projeto` (arquivo sem o cabeçalho do kit). É o que o modo reparo do `/kit:init` usa para criar ou atualizar a rule.

O `ui.sh` não lê nem grava settings, do usuário ou do projeto.

### `ui.sh capture`

```text
ui.sh capture [--kit <kit.json>] [--name <nome>] [--routes <a,b>] [--probe-only] [--tiles N]
              [--steps <json | arquivo.json>] [--attach <http://host:porta> [--match <trecho da url>]]
              [--out <pasta>]
```

`--name` vira a pasta da captura: começa por letra ou número. Rota é um caminho do app ou um endereço `http(s)`.

1. **App.** Se `ui.url` responde, usa como está. Se a porta já está em uso mas demora a responder, espera por ela (até `KIT_UI_WAIT_S`) sem subir outro app. Senão roda `ui.dev` com `bash -c` na raiz do projeto, espera até 120 s pelo endereço (`KIT_UI_WAIT_S`) e, no fim, derruba o que subiu. Comando que termina antes de responder, ou endereço que não responde, sai com 4 e as últimas linhas do log.
2. **Navegador.** Chromium headless com perfil temporário, controlado por pipe (sem porta aberta). No Linux, se não inicia, tenta de novo com `--no-sandbox`. `KIT_UI_BROWSER` aponta outro executável. Comando sem resposta do navegador em 60 s (`KIT_UI_REPLY_S`) interrompe aquela tela, e a próxima abre em aba nova.
3. **Tamanhos.** Em cada tamanho de `ui.viewports` a página é recarregada, passa pela sondagem completa e é fotografada; página mais alta que a tela sai em até 3 partes (`--tiles`, no máximo 6), e o que ficou de fora vira aviso. Em app com o corpo fixo, as partes rolam o contêiner que ocupa a maior parte da tela. Abaixo de 768px a emulação é de celular.
4. **Larguras.** Depois percorre, sem recarregar, as larguras padrão (320, 360, 390, 414, 480, 600, 768, 820, 1024, 1280, 1366, 1440, 1536 e 1920) e, para cada ponto de quebra de largura do CSS da página, um pixel antes, o ponto e um depois. Em cada uma mede rolagem horizontal e alvo de toque. Rolagem horizontal vista no redimensionamento é conferida recarregando a página em cada largura suspeita (até 90s por tela); a que some com a recarga sai do relatório. Com `overflow-x` oculto no `html` ou no `body` a página não rola: elemento que começa dentro da tela e passa da borda sai como `conferir [B2] corte-horizontal`, e o que fica inteiro fora da tela (menu fechado) não conta.
5. **Tema escuro.** Se o CSS tem `prefers-color-scheme: dark`, o menor e o maior tamanho são abertos de novo no escuro, com imagem e medição de contraste. Sem a media query, a captura procura nos seletores do CSS o tema ligado por classe ou atributo (`.dark`, `.dark-mode`, `.dark-theme`, `.theme-dark`, `[data-theme=dark]`, `[data-bs-theme=dark]`, `[data-mode=dark]` e os de MUI, Mantine e Joy), aplica no `html` e no `body` e mede: como quem ligou o tema foi a captura, o contraste sai como `conferir`, e o resumo diz por onde ligou. `.dark` grudada em outra classe (`.cartao.dark`) é variante de componente e não conta. O resto da captura força o tema claro, para o resultado não depender da máquina.
6. **Saída.** Imagens e `report.json` em `.claude/state/ui/<nome>/` (pasta que o `/kit:init` põe no `.gitignore`) e um resumo em texto. Exit 0 sem achado, 1 com achado, 2 uso ou `ui` inválido, 3 sem meio de captura (sem `node`, sem navegador), 4 app não respondeu, 5 captura incompleta. Tela que não foi sondada por inteiro (tempo esgotado, sondagem que falhou, erro no meio da captura) sai com `incomplete` no `report.json` e a linha `incompleta:` no resumo, e conta em `totals.incomplete`; o relatório das outras telas sai do mesmo jeito. Rota que redireciona ganha `final_url` e um aviso; diálogo (`alert`, `confirm`) aberto na carga é fechado e vira aviso. Rotas diferentes que dariam o mesmo nome de arquivo ganham sufixo (`-2`). App que já responde em `ui.url`, ou que só ocupa a porta e demora a responder, é usado como está e nunca é derrubado; com `--out`, só saem da pasta os arquivos que o `report.json` anterior lista.

**Passos (`--steps`).** Tela atrás de login, clique ou campo preenchido é capturada com os passos que levam até ela, em JSON na linha de comando ou num arquivo. Uma lista de passos é refeita depois de cada carga da rota (em cada tamanho, na conferência de rolagem e no tema escuro); o objeto `{ "setup": [...], "steps": [...] }` acrescenta o preparo, que roda uma vez antes da primeira rota (login, dado de teste).

| Passo | O que faz |
| --- | --- |
| `{"goto": "<rota>"}` | Abre a rota (caminho do app ou endereço `http(s)`) |
| `{"click": "<seletor>"}` | Clica no centro do elemento, com eventos de mouse de verdade |
| `{"fill": "<seletor>", "value": "<texto>"}` | Preenche campo, `select` ou `contenteditable` e dispara `input` e `change`; seletor de `<label>` leva ao campo dela |
| `{"press": "<tecla>"}` | Uma letra ou `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `Space`, `Home`, `End`, `PageUp`, `PageDown` e as setas (`ArrowUp`...) |
| `{"hover": "<seletor>"}` | Leva o mouse até o elemento |
| `{"wait": "<seletor>"}` ou `{"wait": <ms>}` | Espera o elemento aparecer, ou um tempo |
| `{"js": "<código>"}` | Roda o código na página (aceita `await`) |

Seletor é CSS ou `text=<texto visível>`: entre os elementos com aquele texto vale primeiro o que serve para a ação (controle clicável em `click`, campo ou rótulo em `fill`). Cada passo espera o elemento por até 10 s (`"timeout": <ms>`, no máximo 60 s) e, depois de agir, espera navegação, rede e desenho assentarem. `${NOME}` em `value` é trocado pela variável de ambiente `NOME`; sem ela a captura sai com 2, o valor só é digitado em página da mesma origem de `ui.url` e nunca aparece no resumo nem no `report.json`. Passo que falha deixa a tela `incompleta` com o número do passo e grava a imagem `<tela>-falha-<tamanho>-1.png` (`preparo-falha-...` se foi no preparo, que deixa todas as telas incompletas). O `report.json` ganha `steps: { setup, steps }`, e a tela, `final_url` quando os passos terminam em outro endereço. `--steps` não combina com `--attach` nem com `ui.screenshot`.

Com `ui.screenshot`, a captura é o comando do projeto, uma vez por rota (e por tamanho, se ele usa `{width}` ou `{height}`), sem sondagem. `{out}`, `{url}` e `{route}` entram no comando já entre aspas simples, com ou sem aspas em volta no `kit.json`; os mesmos valores vão nas variáveis `KIT_UI_OUT`, `KIT_UI_URL`, `KIT_UI_ROUTE`, `KIT_UI_WIDTH` e `KIT_UI_HEIGHT`, para o comando que precisa deles no meio de outro texto. Com `--attach`, o script conecta numa página já aberta de um navegador Chromium com porta de depuração (`--remote-debugging-port`), não recarrega e faz a mesma varredura; pede Node 22 ou mais novo.

Se o projeto tem `axe-core` em `node_modules`, as regras dele rodam no menor e no maior tamanho e entram no relatório como `axe:<regra>`: as de nome acessível e de uso pelo teclado com o id B3, as outras com M8.

### Sondagem

Cada linha é `achado` (medição certa) ou `conferir` (suspeita que o revisor confirma), com o id da regra do `kit:ui-reviewer` e a faixa de larguras em que aparece.

| Regra | Id | Nível | O que mede |
| --- | --- | --- | --- |
| `rolagem-horizontal` | B2 | achado | Documento mais largo que a tela (WCAG 1.4.10), com os elementos que passam da borda |
| `corte-horizontal` | B2 | conferir | `html` ou `body` com `overflow-x` oculto e elemento que começa dentro da tela e passa da borda |
| `sem-nome` | B3 | achado | Botão, link ou campo sem nome acessível |
| `sem-teclado` | B3 | achado | `div`, `span`, `li`, `td` ou `img` com `onclick`, sem papel nem `tabindex` |
| `contraste` | M1 | achado; conferir se o elemento é posicionado ou se há imagem na área do texto | Texto abaixo de 4.5:1, ou 3:1 em texto grande, sobre fundo de cor sólida |
| `alvo-pequeno` | M2 | achado | Controle menor que 24×24px a menos de 24px de outro (WCAG 2.5.8) |
| `texto-pequeno` | M7 | conferir | Fonte abaixo de 12px |
| `so-placeholder`, `sem-alt`, `sem-lang`, `sem-titulo`, `sem-viewport`, `zoom-bloqueado` | M8 | achado | Campo só com placeholder, imagem sem `alt`, `<html>` sem `lang`, `<title>` vazio, `meta viewport` ausente ou que impede zoom |
| `titulos` | M8 | conferir | Página sem `h1` ou com nível de título pulado |
| `console`, `requisicao`, `nao-carregou` | M9 | achado | Erro no console, resposta 400 ou mais, rota que não abre |

Fundo com imagem ou gradiente, opacidade e sombra de texto ficam fora da medição de contraste: é o revisor que olha.

### `/kit:execute`

Com `ui.globs`, a skill lê `skills/execute/ui.md`. Tarefa com arquivo de interface segue o bloco de `skills/execute/ui-rules.md`, que também vai no prompt do subagent. No checkpoint de wave com tela, antes do `verify` e da revisão, roda `ui.sh capture --probe-only` e corrige todo `achado`, para os dois verem o código já corrigido. Na wave final faz a captura completa antes de tirar o diff da F1 e chama o `kit:ui-reviewer` com a SPEC, o plano, os arquivos de interface alterados e a pasta de cada captura. Estado atrás de login ou clique é capturado com `--steps`, um `--name` por estado; o que os passos não alcançam fica para a revisão pelo código e o resumo diz qual.

## Hooks

| Script | Evento | O que faz |
| --- | --- | --- |
| `guard-bash.sh` | PreToolUse `Bash` | Nega `rm -rf` fora do projeto, no próprio projeto ou em `/`, `~`, `..`; alvo não resolvível (variável em qualquer ponto do caminho, `$()`, crase, `xargs`, alvo relativo depois de `cd` para destino não resolvível); glob que apaga o projeto (`*`, `./*`, `*/`, `?*`, `sub/../*`, `<projeto>/*`). Acompanha `cd`/`pushd` dentro do comando e resolve alvos relativos contra a pasta corrente depois deles; caminho Windows (`C:\x`, `E:\\`) vira `C:/x` antes de resolver; no Git Bash, `/c/x` e as montagens (`/tmp`) viram o caminho Windows (`cygpath -m`); `..` é resolvido em bash puro, sem `realpath`. Basta `-r` (com ou sem `-f`) para a checagem de alvo; `rm -r` dentro do projeto continua liberado. Comando que começa por expansão (`$X -rf /`, `$(command -v rm) -rf /`) passa pela mesma checagem. `find` com `-delete` ou `-exec`/`-execdir`/`-ok` com `rm` só é liberado com todos os caminhos iniciais dentro do projeto (`~`, variável e caminho não resolvível negam). Procura o comando depois de palavras-chave (`if`, `then`, `do`, `!`...) e de prefixos (`sudo -u`, `env VAR=x`, `nice -n`, `timeout`, `command`, `exec`, `xargs`). Nega também `git push --force`/`-f`/`+refspec`/`--mirror`/`--delete`/`-d`/`:<ref>`; `git reset --hard`; `git clean -f` com ou sem `-d`/`-x` (dry-run liberado); `git stash drop`/`clear`; `git branch -D` (ou `-d` com `--force`); `git reflog expire`/`delete`; `git gc --prune=now`/`all`; `DROP DATABASE/TABLE/SCHEMA`, `TRUNCATE` SQL, conferidos trecho a trecho (texto passado a `git`, `grep`, `egrep`, `fgrep`, `rg`, `ag` ou `ack` não conta; mensagem de commit em várias linhas citando o SQL ainda pode ser negada); `curl`/`wget` com pipe para shell (inclusive `\| sudo bash`, `\| env bash`, `\| /usr/bin/env sh`, `\| tee f \| sh`) e `sh -c`/`eval` de `$(curl)` ou crase; `chmod -R 777`; `mkfs`; `dd of=/dev/*` (exceto `/dev/null`). Analisa o resto de `cmd`/`cmd.exe` com `/c`, `//c`, `/k` e de `powershell`/`pwsh` com `-c`/`-Command`/`-CommandWithArgs` (no `powershell.exe`, também o primeiro posicional; `/c` colado, como `cmd /c"rd ..."`, conta; nomes do cmd e do PowerShell, e `rm`, `git` e `cd`, sem distinção de maiúsculas): `rd`, `rmdir`, `del`, `erase` com `/s` (inclusive colado, `/s/q`) e `Remove-Item`, `ri`, `rm`, `rmdir`, `rd`, `del`, `erase` com `-Recurse` (ou prefixo, como `-r`) passam pela mesma checagem de alvo do `rm -rf` (posicional, lista com vírgula, `-Path`, `-LiteralPath`, `-Path:x`; `%VAR%` e drive de provedor como `HKCU:` contam como não resolvíveis); remoção recursiva sem alvo (itens vindos do pipeline) nega; `Set-Location`, `sl`, `chdir` e `-WorkingDirectory` tornam alvos relativos não resolvíveis; `git` pelas regras de git; `format <unidade>:`, `Format-Volume`, `Clear-Disk`, `Remove-Partition` e `Initialize-Disk` negam; `iwr`, `irm`, `Invoke-WebRequest`, `Invoke-RestMethod`, `DownloadString`, `curl` ou `wget` com pipe para `iex`/`Invoke-Expression`, ou `iex` aplicado a eles, nega como `curl \| sh`; `-EncodedCommand` (`-e`, `-ec`, `-enc`...) nega, porque o conteúdo é opaco; `-File` fica fora. Pede confirmação (`ask`, negação em `bypassPermissions`) para código inline de interpretador (`python`/`python3`/`py -c`, `node`/`bun -e`/`--eval`/`-p`, `deno eval`, `perl -e`/`-E`, `ruby -e`, `php -r`; a opção vale antes do nome do script, não depois) quando o texto do comando cita API que apaga arquivo ou dispara processo (`rmtree`, `os.remove`, `os.system`, `unlink`, `rmdir`, `rmSync`, `fs.rm(`, `rimraf`, `subprocess`, `child_process`, `execSync`, `spawnSync`, `system`, `FileUtils.rm`, `File.delete`, `shell_exec`, `popen`, `Deno.remove`, `Bun.spawn`...); sem essas palavras, passa. Escrita pelo shell passa pelas mesmas regras do `guard-files` (segredos, `guards.deny_write`, `protected_paths` com `guards.allow_write`, mesmas mensagens; arquivo que ainda não existe conta como Write de arquivo novo): alvo de `>`, `>>`, `>|`, `N>`, `&>` (inclusive colado, `>arq`; `/dev/*` e `2>&1` não contam), `tee`, `sed -i`/`--in-place`, `perl -i`, destino de `cp`, `mv`, `install` e `ln` (com `-t`, e pasta de destino recebe o nome de cada origem), origens do `mv`, `dd of=` e `truncate`. Script de `sed`/`perl` entre aspas com `;`, `|`, `&`, `()`, `{}` ou `>` não esconde o arquivo. Alvo com variável, `~`, glob ou relativo depois de `cd` não resolvível é conferido só pelo nome (`.env`, `*.pem`, `*.key`, `secrets/`, `keys/`). O `kit.json` só é lido quando o comando tem alvo de escrita ou argumento de leitura com nome de segredo. Com `segredos` em `permissions.groups` (de qualquer `kit.json` da pasta do comando para cima), nega também a leitura pelo shell dos mesmos nomes que o grupo nega no `Read` (`.env`, `.env.local`, `.env.*.local`, `.env.test`, `.env.production`, `.env.development`, `.env.staging`, `*.pem`, `*.key`, `secrets/`, e em `~` `.ssh/`, `.aws/`, `.kube/`, `.config/gh/`, `.git-credentials`, `.npmrc`, `.docker/config.json`; nome de exemplo liberado): argumentos de `cat`, `tac`, `head`, `tail`, `less`, `more`, `bat`, `nl`, `od`, `xxd`, `hexdump`, `strings`, `base64`, `cut`, `sort`, `source` e `.`; arquivos de `grep`/`rg`/`ag`, `sed` e `awk` (o padrão ou programa não conta, salvo quando veio por `-e`/`-f`; o arquivo do `-f`/`--file` conta); origens de `cp` e `scp` (`scp -i chave` não conta; `cp` com um só argumento, como `cp .env{,.bak}`, conta como origem); `curl` com `@arquivo`, `<arquivo` ou `-T`; entrada por `<` em qualquer comando (heredoc e here-string não contam). `~`, `$HOME` e `${HOME}` viram a home; glob com pasta resolvível é expandido ali (sem ocultos, como o bash); symlink confere o alvo; caminho com outra variável é conferido só pelo nome. O grupo só é lido quando um argumento casa um desses nomes; `kit.json` ilegível nega. `node --env-file .env`, `docker compose --env-file .env` e qualquer comando fora da lista seguem liberados. Pede confirmação (`ask`) para o que descarta alteração não commitada: `git checkout` com `--` e caminho, `--pathspec-from-file`, `.`, `./`, `:/`, `*`, `-f` ou `--force`; `git restore` que não seja só `--staged`; `git switch -f`/`--force`/`--discard-changes`. O pedido sai depois da análise do comando inteiro: um trecho negado no mesmo comando ganha. Em `bypassPermissions` vira negação; em `claude -p`, sem ninguém para confirmar, o Claude Code nega. Analisa o conteúdo de `sh -c`, `bash -c`, `cmd /c`, `powershell -Command`, `$()`, crases e cadeias com `&&`, `;`, `\|`. Entrada vazia ou JSON truncado e erro inesperado no script bloqueiam (exit 2). Não cobre: script gravado e depois executado (`python limpa.py`, `powershell -File x.ps1`, `python - <<EOF`), interpretador chamado por outro (`uv run python -c`, `npx node -e`), código inline com API fora da lista ou montada por texto (a confirmação é uma segunda olhada, não cobertura), `cmd /c "cd /d X & rd /s y"` (o `cd /d` do cmd é lido como o drive `/d` do Git Bash e nega por excesso), `del /s *.tmp` e `Remove-Item -Recurse *.log` relativos (negados como o `rm -rf *`), `git checkout <arquivo>` sem `--` (ambíguo com troca de branch), texto que cita comando negado dentro de crase ou de heredoc (mensagem de commit ou corpo de PR pode ser negada; o mesmo vale para `> caminho-protegido` citado entre aspas ou num heredoc e, com o grupo `segredos`, para uma leitura como `cat .env` citada entre aspas depois de `(`, `;` ou `|`), leitura de segredo pelo shell sem o grupo `segredos`, e com ele a leitura indireta (`grep -r KEY .`, `env`, script que imprime o arquivo, comando fora da lista como `python -c`, caminho montado por `$()`, glob sem o nome do segredo como `.e*`), `rm` de arquivo protegido, `mv` de pasta protegida inteira, arquivos que chegam por `xargs` ou `find -exec` (`find . -name x.cs -exec sed -i ...`), `sed -i` com separador no script dentro de `sh -c` com vários comandos (`bash -c "echo a; sed -i 's|x|y|' .env"`) e escrita feita por programa (`dotnet ef migrations add`, um script que grava arquivo). |
| `guard-files.sh` | PreToolUse `Edit\|Write\|MultiEdit\|NotebookEdit` | Normaliza o caminho antes de casar (relativo ao `cwd` do hook, `..` mesmo por pasta inexistente, `//` colapsado) e, se for symlink, checa também o alvo final. Em Windows e macOS a comparação ignora maiúsculas (`.ENV`, `x.KEY`, `Secrets/`); no Windows, espaço ou ponto no fim do nome e fluxo alternativo (`.env::$DATA`) contam como o próprio arquivo. Nega escrita em `.env` e `.env.*` (exceto nome terminado em `.example`, `.sample`, `.template` ou `.dist`, como `.env.test.example`), `*.pem`, `*.key`, `secrets/`, `keys/` (qualquer pasta com esse nome, inclusive `src/i18n/keys/`), sem exceção. Nega também `guards.deny_write` do `kit.json` (arquivo novo inclusive), e `guards.allow_write` libera o que casaria `protected_paths` (glob largo ignorado, com aviso na mensagem). Globs de `protected_paths` com `./`, `/` inicial ou `\` são normalizados. `kit.json` ilegível ou com `protected_paths`/`guards` de tipo errado nega toda escrita na pasta, menos no próprio `kit.json`. Entrada vazia ou JSON truncado e erro inesperado no script bloqueiam (exit 2). Nega Edit, e Write sobre arquivo existente, em `protected_paths` do `kit.json` mais próximo e dos `kit.json` acima dele até a pasta da sessão; Write de arquivo novo só é negado em item com `"write": "deny"`. Item com `message` usa esse texto na negação. A negação por `protected_paths` diz como liberar quando o arquivo não é segredo (`guards.allow_write`). As mesmas regras valem para a escrita pelo shell, no `guard-bash`. |
| `format.sh` | PostToolUse `Edit\|Write\|MultiEdit` | Roda o formatter do primeiro glob de `format` que casa (em Windows e macOS, ignorando maiúsculas). Falha: exit 2 com as últimas 30 linhas. |
| `advise.sh` | PostToolUse `Edit\|Write\|MultiEdit` | Regras `coupled_changes` com `level: "warn"` cujo `when` casa com o arquivo editado e cujo `require` não casa (em Windows e macOS, ignorando maiúsculas) viram `additionalContext` (JSON, porque stdout puro de PostToolUse não chega ao Claude), uma vez por arquivo por sessão. Regras `diff_deny` com `level: "warn"` cujo padrão aparece numa linha nova do arquivo (diff contra o início do turno; não rastreado inteiro) também, uma vez por conjunto de linhas. Nunca bloqueia. |
| `verify-gate.sh` | Stop | Em cada repositório da sessão, roda em ordem cada comando de `verify_on_stop` que tem arquivo alterado (diff contra HEAD + não rastreados + commitados desde o início do turno) casando `source_globs`, ou os `files` do próprio comando na forma objeto. Roda todos mesmo depois de uma falha e registra cada uma com as últimas 60 linhas, ou 30 quando há mais de uma; a mensagem inteira cabe em 9.000 caracteres (as falhas curtas saem inteiras; as longas são cortadas no meio, ficando o começo e o fim). O início do turno é o HEAD gravado pelo UserPromptSubmit em `.git/kit-turn-head` com o `session_id`; marca de outra sessão é ignorada. `{files}` recebe só arquivos que existem; comando com `{files}` e nenhum arquivo existente não roda. Chave de `verify_on_stop` sem comando em `commands` é pulada (o `session-context` avisa). O comando roda com o stdin fechado. Depois avalia `key_parity`, `coupled_changes` e `diff_deny` com `level: "block"`. Todas as falhas saem numa única mensagem com exit 2. `kit.json` ilegível vira falha da pasta. Com `stop_hook_active` (passada seguinte a um bloqueio), verifica de novo: se ainda falhar, libera o turno com a falha em `systemMessage`, sem notificação de concluído; o teto oficial de continuações seguidas por stop hook é 8, e o gate usa só uma. Comandos já verificados com sucesso no mesmo estado não rodam de novo (marca em `.git/kit-verify-*`; o estado inclui todos os alterados e não rastreados do repositório, não só os de `source_globs`). Turno liberado com a verificação verde e `notify.done`: notificação de concluído em segundo plano (`notify.sh --send`), sem atrasar o fim do turno. |
| `session-context.sh` | SessionStart (`startup\|resume\|clear\|compact\|fork`) | Injeta branch e `git status --short` de cada repositório, os planos ativos e as tarefas pendentes do mais recente. Avisa de `kit.json` inválido, chave de `verify_on_stop` sem comando, `verify_on_stop` sem `source_globs`, comando `lint` fora do `verify_on_stop` (nenhum passo do kit roda o lint; o `/kit:init` propõe como incluir) e entrada de `repos` sem `.git`. Na origem `compact`, inclui o snapshot do `pre-compact` se ele tiver menos de 2 horas. Sem `jq`, devolve JSON com a mensagem de instalação em `systemMessage` e `additionalContext`. Sem `git` ou com Claude Code abaixo de 2.1.295, avisa com o comando de correção e "rode /kit:setup". Com `docs/codemap.md` gerado pelo `/kit:map` (na raiz ou num repositório) mais de `map.stale_after_commits` commits atrás do commit do cabeçalho, sugere `/kit:map --update`; commit fora do histórico sugere `/kit:map`. |
| `session-context.sh --plan-only` | UserPromptSubmit | Só a linha de planos ativos, e só se `inject_plan_on_prompt` for `true`; caso contrário não imprime nada. Grava o HEAD de cada repositório em `.git/kit-turn-head` (`<session_id> <commit>`) para o `verify-gate`. Com `notify.done`, grava `.claude/state/turn-start` (início do turno). |
| `notify.sh` | Notification (async) | Com `notify.waiting`, `⏳ <projeto>: <mensagem>`. Toast do Windows pelo `powershell.exe` (API `Windows.UI.Notifications`, sem módulo externo; no WSL pela interop, com as variáveis no `WSLENV`), `osascript` (JXA) no macOS, `notify-send` no Linux; sem nenhum, o sino do terminal. Push por ntfy (JSON) e webhook do Discord com `curl`, se as variáveis existirem. Título e mensagem chegam ao powershell/osascript por variável de ambiente, nunca no texto do comando. Timeout curto, falha calada, sempre exit 0. `--send` é a entrega usada pelo `verify-gate`; `KIT_NOTIFY_DRY_RUN=1` imprime o que rodaria. |
| `pre-compact.sh` | PreCompact | Grava `<raiz>/.claude/state/kit-snapshot.md` com data, branch, modificados e staged (até 20 cada) de cada repositório e os planos ativos. Sempre exit 0: nunca bloqueia a compactação. O `/kit:init` acrescenta `.claude/state/` ao `.gitignore`. |

Sem `jq`, os guardas bloqueiam com `kit: jq não encontrado — instale com <comando da plataforma> e reabra o Claude Code` (exit 2). Para não virar beco sem saída, o `guard-bash` lê o JSON cru e libera só o comando exato de instalação do `jq` da plataforma (`winget install jqlang.jq`; `brew install jq`; `sudo apt install jq`, `sudo apt-get install jq`, `sudo dnf install jq` ou `sudo pacman -S jq`), sem nada antes ou depois. O `session-context` devolve a mesma mensagem em `systemMessage` (o usuário vê ao abrir a sessão) e em `additionalContext` (o Claude recebe), num JSON montado sem `jq`. Os demais hooks saem com 0 sem fazer nada.

Os guardas devolvem `permissionDecision: "deny"` com o motivo; Claude recebe o motivo e ajusta. Todo motivo de negação termina com a mesma frase (`KIT_DENY_NO_WORKAROUND` no `lib.sh`): não tentar outro comando, interpretador ou ferramenta para o mesmo efeito, explicar ao usuário e pedir que ele rode manualmente se for intencional. A confirmação (`ask`) não leva a frase. Com `onFailure: "block"` (Claude Code 2.1.295+), um guarda que não consegue rodar também bloqueia: script ausente, saída com código diferente de 0 e 2, timeout ou JSON inválido. No `Stop` o campo não tem efeito, segundo a doc oficial.

Os hooks usam a forma shell com `"shell": "bash"` explícito (`"command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/<script>.sh\""`, sem `args`). Na forma exec (`command` + `args`) o Claude Code procura `bash` no PATH, e no Windows isso falha com `Executable not found in $PATH: "bash"` quando o `Git\bin` não está no PATH; com `onFailure: "block"`, todo Bash/Edit/Write ficaria bloqueado. Na forma shell, o Windows roda o comando pelo Git Bash que o Claude Code localiza (o mesmo da ferramenta Bash; se não achar, `CLAUDE_CODE_GIT_BASH_PATH`), e o `bash` dentro da string é resolvido pelo PATH que o Git Bash monta.

## Modo do zero

Numa pasta sem manifesto, sem código-fonte e sem repositórios filhos (repositório git ou não; `README`, `LICENSE`, `.gitignore`, `.gitattributes`, `docs/` e `.claude/` não contam, então instalar o plugin antes não muda o modo), o `/kit:init <o que o app faz>` segue [`skills/init/new.md`](../plugins/kit/skills/init/new.md):

1. **Entrevista até o mínimo**, em rodadas de até 4 perguntas: tipo de app e onde roda; stack como conjunto (linguagem, framework, teste, lint e format; 2 ou 3 opções, a recomendada primeiro, e entre equivalentes vence o que o usuário domina); dados, se há estado; integrações obrigatórias. CI, deploy, escala, autenticação, telas e regras de negócio não são perguntados: não mudam o esqueleto. Termina num resumo e na pergunta "Criar o esqueleto com isso?".
2. **Esqueleto**, só depois do "Criar": `git init` se a pasta não é repositório, gerador oficial do stack quando existe, dependências pelo gerenciador de pacotes (sem número de versão escrito de memória), e só manifesto e lockfile, um ponto de entrada que roda, um teste que passa e falharia sem ele, linter e formatter, `.gitignore`, `.env.example` se há credencial e um README curto. Build, teste e lint precisam passar. Nenhuma feature e nenhum commit.
3. **Passos normais do init**, como repositório novo: `kit.json` com os comandos do esqueleto, settings, `CLAUDE.md` com o que foi decidido na entrevista, confirmação única e relatório. Sem mapa.

É a única gravação do init antes da confirmação única, e tem a própria confirmação. Em execução não interativa, o argumento precisa trazer a ideia e o stack; sem isso, nada é criado.

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
