---
name: init
description: Gera ou adota o adaptador do kit no projeto atual (.claude/kit.json, .claude/settings.json e CLAUDE.md enxuto) a partir do stack detectado. Em repositório com .claude/ existente, entra no modo adotar.
argument-hint: "[respostas pré-aprovadas, opcional]"
disable-model-invocation: true
allowed-tools: Bash(git rev-parse *) Bash(git ls-files *) Read(${CLAUDE_PLUGIN_ROOT}/**) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/inventory.sh")
---

## Estado atual
!`git rev-parse --show-toplevel 2>/dev/null || echo "(não é repo git)"`
!`git ls-files -co --exclude-standard -- .claude CLAUDE.md .mcp.json 2>/dev/null || echo "(não é repo git)"`
!`git ls-files "*.sln" "*.csproj" "*.fsproj" "package.json" "pyproject.toml" "requirements*.txt" "setup.py" "go.mod" "Cargo.toml" "pom.xml" "build.gradle" "build.gradle.kts" "Gemfile" "composer.json" "mix.exs" "deno.json" 2>/dev/null || echo "(não é repo git)"`

## Modo
- Se a lista de configuração acima trouxer qualquer coisa em `.claude/`, `CLAUDE.md` ou `.mcp.json`: **modo adotar**. Leia [adopt.md](adopt.md) agora e siga-o; ele envolve os passos abaixo.
- Caso contrário: repositório novo, siga só os passos abaixo.
- **Workspace:** se a pasta não for repositório git, mas tiver repositórios filhos (diretórios com `.git` até 3 níveis, fora de `node_modules`, `target`, `dist`, `build`, `vendor`, `.venv`), rode os passos para cada filho (cada um com seu `.claude/kit.json`) e proponha também um `.claude/kit.json` na pasta-mãe só com o que cruza repositórios: `repos` (lista explícita, opcional; sem ela os hooks descobrem os filhos) e regras `coupled_changes`/`key_parity` com caminhos relativos à pasta-mãe (`app/src/**` → `web/docs/**`). A pasta-mãe também recebe o `.claude/settings.json` que habilita o plugin, porque a sessão roda nela.

## Regras que valem a tarefa inteira
- Nada é gravado antes da confirmação explícita do usuário. Mostre o diff de cada arquivo (ou o arquivo completo, se for novo) antes.
- Nunca sobrescreva settings, hooks, skills, agents, rules ou CLAUDE.md existentes. Arquivo existente só recebe adições.
- JSON existente é mesclado chave a chave com `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-json.sh" <existente> <proposta>` (arrays por união, sem duplicar; valor existente vence e conflitos aparecem no stderr). Grave a saída só após confirmação e confira com `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-json.sh" --check <antes> <depois>` (exit 0 = só adições).
- Comandos propostos precisam existir no projeto: confira scripts do `package.json`, targets do Makefile, ferramentas já configuradas (lint, formatter, test runner). Não proponha ferramenta que o projeto não usa.
- Se `$ARGUMENTS` trouxer respostas pré-aprovadas (execução não interativa), use-as no lugar das perguntas correspondentes e não pergunte de novo. O que não foi respondido e depende de decisão fica de fora e é listado no resumo final. Remoção de peça existente nunca é pré-aprovada por argumento.
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
   - Se o arquivo já existe, a proposta passa pelo `merge-json.sh`.
6. **Propor `.gitignore`**: acrescentar `.claude/state/` (snapshot de compactação do kit), só se ainda não estiver lá.
7. **Propor `CLAUDE.md`** a partir de `templates/CLAUDE.project.md`, com no máximo ~60 linhas: só o que o código não explica (decisões de arquitetura, guardrails de domínio, convenções fora do padrão). Cada linha passa no teste "remover esta linha faria Claude errar?". Se já existir, proponha só as seções que faltam; aponte (sem apagar) o que poderia sair ou virar `.claude/rules/*.md` com `paths:`.
8. **Confirmar.** Mostre os diffs e pergunte com `AskUserQuestion`: gravar tudo, ajustar algo ou cancelar.
9. **Gravar** só o que foi aprovado. Valide o JSON (`jq . .claude/kit.json`), rode `merge-json.sh --check` em cada JSON que já existia e rode uma vez cada comando de `verify_on_stop` para provar que funciona.
10. **Próximos passos** a sugerir:
   - `/run-skill-generator` para gravar a receita de subir o app, e `/verify` para a skill de verificação do projeto.
   - O plugin LSP oficial da linguagem (ver [stacks.md](stacks.md)).
   - Revisar e commitar `.claude/`, `CLAUDE.md` e `docs/claude-adoption.md` junto com o código.
