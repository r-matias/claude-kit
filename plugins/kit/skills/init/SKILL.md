---
name: init
description: Porta de entrada do kit. Prepara a máquina se faltar algo do /kit:setup, cria o adaptador do projeto (.claude/kit.json e, se faltarem, .claude/settings.json e CLAUDE.md) sem alterar a configuração existente e, em projeto grande ou com vários repositórios, mapeia o código com o /kit:map. Rodado de novo, entra em modo reparo.
argument-hint: "[respostas pré-aprovadas, opcional]"
disable-model-invocation: true
allowed-tools: Bash(git rev-parse *) Bash(git ls-files *) Read(${CLAUDE_PLUGIN_ROOT}/**) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/inventory.sh") Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh" *)
---

## Estado atual
!`git rev-parse --show-toplevel 2>/dev/null || echo "(não é repo git)"`
!`git ls-files -co --exclude-standard -- .claude CLAUDE.md .mcp.json 2>/dev/null || echo "(não é repo git)"`
!`git ls-files "*.sln" "*.csproj" "*.fsproj" "package.json" "pyproject.toml" "requirements*.txt" "setup.py" "go.mod" "Cargo.toml" "pom.xml" "build.gradle" "build.gradle.kts" "Gemfile" "composer.json" "mix.exs" "deno.json" 2>/dev/null || echo "(não é repo git)"`

## Ordem
O init é a porta de entrada: o usuário não precisa conhecer `/kit:setup` nem `/kit:map`. Faça nesta ordem:
1. **Máquina.** Rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" status`. Exit 0: siga. Exit 1: leia `${CLAUDE_PLUGIN_ROOT}/skills/setup/SKILL.md` e execute os passos dele aqui, com as mesmas confirmações; depois rode `status` de novo. Se o setup parou por dependência faltando, pare o init também e diga o que instalar. Linhas `aviso` não param. Com respostas pré-aprovadas em `$ARGUMENTS`, o settings do usuário só é gravado se elas autorizarem o setup; senão, liste o que falta no resumo e siga com o projeto.
2. **Projeto.** O modo abaixo (novo, adotar ou reparo) e os Passos.
3. **Mapa.** Passo 10.

## Modo
- Se `.claude/kit.json` já existe: **modo reparo** (seção abaixo).
- Se a lista de configuração acima trouxer qualquer coisa em `.claude/`, `CLAUDE.md` ou `.mcp.json`: **modo adotar**. Leia [adopt.md](adopt.md) agora e siga-o; ele envolve os passos abaixo.
- Caso contrário: repositório novo, siga só os passos abaixo.
- **Workspace:** se a pasta não for repositório git, mas tiver repositórios filhos (diretórios com `.git` até 3 níveis, fora de `node_modules`, `target`, `dist`, `build`, `vendor`, `.venv`), rode os passos para cada filho (cada um com seu `.claude/kit.json`) e proponha também um `.claude/kit.json` na pasta-mãe só com o que cruza repositórios: `repos` (lista explícita, opcional; sem ela os hooks descobrem os filhos) e regras `coupled_changes`/`key_parity` com caminhos relativos à pasta-mãe (`app/src/**` → `web/docs/**`). A pasta-mãe também recebe o `.claude/settings.json` que habilita o plugin, porque a sessão roda nela.

## Modo reparo
Projeto já configurado pelo kit. Não refaça a entrevista; confira e proponha só o que falta, pelas mesmas regras de escrita (arquivo de Claude Code existente nunca é alterado):
- `.claude/kit.json`: JSON válido (`jq . .claude/kit.json`), chaves conhecidas (as de `templates/kit.example.json`), cada chave de `verify_on_stop` presente em `commands`, cada comando ainda existente no projeto (script do manifesto, target, ferramenta configurada).
- `.claude/settings.json`: plugin habilitado (`enabledPlugins` e `extraKnownMarketplaces` do kit) e um `Bash(<prefixo> *)` em `permissions.allow` por comando. O que faltar vai para `.claude/kit-settings.suggested.json` (passo 5), nunca para o settings.
- `.gitignore` com `.claude/state/` (se faltar, sugestão no relatório).
- Rode uma vez cada comando de `verify_on_stop` e relate o resultado.
- Mapa: rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh" --status`. Desatualizado: siga o `/kit:map` com `--update` (como no passo 10). Ausente: aplique a regra do passo 10.
- Resumo: o que estava certo, o que foi corrigido nos arquivos do kit, as sugestões geradas e o que ficou pendente.

## Regras que valem a tarefa inteira
- **O kit só soma, nunca altera a configuração do projeto.** Arquivo de Claude Code que já existe não é editado, mesclado, renomeado, desativado nem apagado: `CLAUDE.md`, `.claude/settings.json`, `.claude/settings.local.json`, `.mcp.json`, `.claude/skills/`, `.claude/agents/`, `.claude/commands/`, `.claude/rules/` e hooks. O kit só cria arquivos novos dele.
- Arquivos do kit podem ser regravados: `.claude/kit.json`, `.claude/kit-settings.suggested.json`, `docs/claude-adoption.md` e os do `/kit:map` (`.claude/rules/map-*.md`, `.claude/rules/kit-codemap.md`, `docs/codemap.md`, com o cabeçalho `kit:map`).
- `CLAUDE.md` e `.claude/settings.json` ausentes podem ser criados. Existentes: o que o kit acrescentaria vira sugestão (passos 5 e 7) e aparece no relatório final; o usuário aplica se quiser.
- Sobreposição com o kit (hook, skill ou agent do projeto que faz o mesmo) só é relatada no fim, com a sugestão de qual desativar e como. Nunca edite nem desative a peça do projeto.
- Nada é gravado antes da confirmação explícita do usuário. Mostre o arquivo novo (ou o diff, se for arquivo do kit que já existia) antes.
- Comandos propostos precisam existir no projeto: confira scripts do `package.json`, targets do Makefile, ferramentas já configuradas (lint, formatter, test runner). Não proponha ferramenta que o projeto não usa.
- Se `$ARGUMENTS` trouxer respostas pré-aprovadas (execução não interativa), use-as no lugar das perguntas correspondentes e não pergunte de novo. O que não foi respondido e depende de decisão fica de fora e é listado no resumo final. Nenhum argumento autoriza alterar arquivo existente.
- Raiz do plugin, chamada de `<raiz-do-plugin>` em [adopt.md](adopt.md): `${CLAUDE_PLUGIN_ROOT}`
- Templates em `${CLAUDE_PLUGIN_ROOT}/templates/`. Tabela de stacks em [stacks.md](stacks.md).

## Passos
1. **Detectar stacks.** Use a lista de manifestos acima (inclui subpastas de monorepo). Para cada manifesto, leia o suficiente para saber runner de teste, linter, formatter e se há migrações de banco. Leia também Makefile, `justfile`, `Taskfile.yml` e CI (`.github/workflows/*`) se existirem: o CI costuma ter os comandos reais.
2. **Monorepo.** Se houver pacotes com stacks diferentes em subpastas, pergunte se prefere um `kit.json` na raiz (comandos com `--prefix`/`cd`) ou um por pacote (os hooks usam o mais próximo do arquivo editado).
3. **Propor `.claude/kit.json`** a partir de `templates/kit.example.json` e de [stacks.md](stacks.md):
   - `commands`: `build`, `test`, `test_related` (com `{files}` só se o runner aceitar caminhos), `lint`, `typecheck` e, se o projeto tiver um teste rápido do sistema rodando (script de smoke, health check), `smoke`. Chave sem comando real fica de fora.
   - `format`: um glob por formatter já configurado no projeto.
   - `protected_paths`: migrações, código gerado, lockfiles se fizer sentido. Quando houver o que fazer em vez de editar, use a forma objeto com mensagem: `{ "glob": "<gerado>/**", "message": "Gerado por <comando>. Edite em <fonte> e rode <comando>." }`; `"write": "deny"` para binários, bancos locais e artefatos que nem devem ser criados.
   - `plan_dirs`: se o projeto já guarda planos fora de `docs/specs/` (ex.: `.claude/plans`), liste os diretórios para o plano ativo aparecer no contexto. `inject_plan_on_prompt: true` só se o usuário pedir: repete a linha do plano a cada mensagem e custa contexto.
   - `verify_on_stop`: o conjunto mais rápido que pega erro real (normalmente `build` ou `typecheck` + `test_related`). Avise que roda ao fim de cada turno com mudança em código.
   - `source_globs`: extensões de código-fonte do stack.
4. **Checks de domínio.** Pergunte (ou use a resposta pré-aprovada) se o projeto tem:
   - **i18n**: procure `**/i18n/*.json`, `**/locales/**/*.json`, `**/lang/*.json`. Se houver, proponha `key_parity` com os arquivos de cada conjunto e uma `message` curta.
   - **arquivos acoplados**: pares que precisam mudar juntos (telas ↔ manual, schema ↔ migração, contrato de API ↔ cliente gerado, código ↔ doc de referência). Se houver, proponha `coupled_changes` com `when`, `require` e `message` dizendo o que atualizar. Para cada par, pergunte o nível: `"level": "block"` (padrão: o turno só termina com o par alterado) ou `"level": "warn"` (só um aviso na edição, para acoplamentos do tipo "se mudou X, confira Y"). `hint` é opcional: texto extra, como o comando que regenera o par.
   - Sem resposta ou "não": não inclua as chaves.
5. **Propor `.claude/settings.json`** a partir de `templates/project-settings.json`:
   - `extraKnownMarketplaces` e `enabledPlugins` para `kit@claude-kit`. O marketplace é o repositório GitHub `r-matias/claude-kit`.
   - `permissions.allow`: um `Bash(<prefixo> *)` por comando do `kit.json`.
   - `permissions.ask`: instalação de dependência e migração de banco do stack.
   - `sandbox.network.allowedDomains`: registry do stack (ver [stacks.md](stacks.md)).
   - Se houver testes de integração com banco/Docker, explique que o sandbox os bloqueia e proponha `sandbox.excludedCommands` só com o comando exato da suíte mais uma regra `ask` para ele.
   - Arquivo inexistente: crie com a proposta.
   - Arquivo existente: não toque nele. Grave a proposta num temporário, rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-json.sh" --additions .claude/settings.json <proposta>` e grave a saída em `.claude/kit-settings.suggested.json` (só o que o kit somaria; com `{}`, não grave nada). Inclua ali também os `permissions.deny` sugeridos pelas sobreposições (ex.: `Skill(kit:fix)`). Para o relatório, gere o diff entre o settings atual e `merge-json.sh .claude/settings.json .claude/kit-settings.suggested.json`.
6. **`.gitignore`**: `.claude/state/` (snapshot de compactação do kit) precisa estar ignorado. Sem `.gitignore`, proponha criar com essa linha; com `.gitignore` que não a tem, não edite: a linha vai como sugestão no relatório.
7. **`CLAUDE.md`.** Inexistente: proponha um a partir de `templates/CLAUDE.project.md`, com no máximo ~60 linhas: só o que o código não explica (decisões de arquitetura, guardrails de domínio, convenções fora do padrão). Cada linha passa no teste "remover esta linha faria Claude errar?". Existente: não toque; as seções que faltariam e o que poderia sair ou virar `.claude/rules/*.md` com `paths:` vão como sugestão no relatório final.
8. **Confirmar.** Mostre os diffs e pergunte com `AskUserQuestion`: gravar tudo, ajustar algo ou cancelar.
9. **Gravar** só o que foi aprovado, só em arquivos novos ou do kit. Valide o JSON (`jq . .claude/kit.json`) e rode uma vez cada comando de `verify_on_stop` para provar que funciona.
10. **Mapa.** Rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh"` na pasta da sessão. Se `totals.files` passar de 300 ou `repos` tiver mais de um repositório, leia `${CLAUDE_PLUGIN_ROOT}/skills/map/SKILL.md` e execute o fluxo dele sem argumento, sem perguntar (ele mesmo só pergunta acima de `map.max_agents`, padrão 30). Caso contrário, só cite o `/kit:map` nos próximos passos.
11. **Relatório final**: arquivos criados; sugestões que o usuário aplica se quiser (diff de `.claude/kit-settings.suggested.json` contra o settings, conteúdo sugerido para o `CLAUDE.md` existente, sugestão do settings de usuário); sobreposições, cada uma com a peça que o kit sugere desativar e como (ex.: `Skill(kit:fix)` em `permissions.deny`); o que ficou pendente. Depois, os próximos passos:
   - `/run-skill-generator` para gravar a receita de subir o app, e `/verify` para a skill de verificação do projeto.
   - O plugin LSP oficial da linguagem (ver [stacks.md](stacks.md)).
   - Revisar e commitar os arquivos criados (`.claude/kit.json`, `docs/claude-adoption.md`, `docs/codemap.md`, as rules do mapa) junto com o código.
   - O fluxo de feature: `/kit:spec` → `/kit:plan` → `/kit:execute`.
