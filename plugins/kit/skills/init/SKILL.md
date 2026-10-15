---
name: init
description: Porta de entrada do kit. Prepara a máquina, cria o adaptador do projeto (.claude/kit.json e, se faltarem, .claude/settings.json e CLAUDE.md), soma ao settings existente só o que falta (com backup), liga o plugin LSP da linguagem e, em projeto grande ou com vários repositórios, mapeia o código. Tudo numa confirmação só. Rodado de novo, entra em modo reparo.
argument-hint: "[respostas pré-aprovadas, opcional]"
disable-model-invocation: true
allowed-tools: Bash(git rev-parse *) Bash(git ls-files *) Read(${CLAUDE_PLUGIN_ROOT}/**) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/inventory.sh") Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/inventory.sh" --net) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh" *) Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-json.sh" *) Bash(npm install -g typescript-language-server typescript) Bash(npm install -g pyright) Bash(npm install -g intelephense) Bash(go install golang.org/x/tools/gopls@latest) Bash(rustup component add rust-analyzer) Bash(dotnet tool install --global csharp-ls) Bash(gem install ruby-lsp) Bash(brew install jdtls) Bash(brew install JetBrains/utils/kotlin-lsp)
---

## Estado atual
!`git rev-parse --show-toplevel 2>/dev/null || echo "(não é repo git)"`
!`git ls-files -co --exclude-standard -- .claude CLAUDE.md .mcp.json 2>/dev/null || echo "(não é repo git)"`
!`git ls-files -oi --exclude-standard -- .claude CLAUDE.md .mcp.json 2>/dev/null || echo "(não é repo git)"`
!`git ls-files "*.sln" "*.csproj" "*.fsproj" "package.json" "pyproject.toml" "requirements*.txt" "setup.py" "go.mod" "Cargo.toml" "pom.xml" "build.gradle" "build.gradle.kts" "Gemfile" "composer.json" "mix.exs" "deno.json" 2>/dev/null || echo "(não é repo git)"`

## Princípio
O init faz tudo o que o kit consegue fazer, com **uma única confirmação** agrupada. O relatório final não manda o usuário fazer nada: nada de "rode X", "instale Y" ou "aplique Z". Se o kit consegue, ele faz depois do "sim"; se não consegue, vira um aviso de uma linha; se depende de escolha do usuário, vira pergunta dentro da confirmação.

## Ordem
O usuário não precisa conhecer `/kit:setup` nem `/kit:map`. Faça nesta ordem, **juntando propostas sem gravar nada** até a confirmação:
1. **Máquina.** Rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" status`. Exit 0: nada a propor. Exit 1: leia `${CLAUDE_PLUGIN_ROOT}/skills/setup/SKILL.md` e siga os passos 1 a 3 dele (dependências, plataforma, proposta do settings de usuário), sem a confirmação dele: o que ele propõe entra na confirmação única abaixo.
2. **Projeto.** O modo abaixo (novo, adotar ou reparo) e os Passos 1 a 7.
3. **LSP.** Passo 8.
4. **Confirmação única.** Passo 9.
5. **Gravar e verificar.** Passo 10.
6. **Mapa.** Passo 11.
7. **Relatório.** Passo 12.

## Modo
- Se `.claude/kit.json` já existe: **modo reparo** (seção abaixo).
- Se qualquer das duas listas de configuração acima trouxer algo em `.claude/`, `CLAUDE.md` ou `.mcp.json`: **modo adotar**. A segunda lista os arquivos ignorados pelo `.gitignore`, como `.claude/settings.local.json`, que a primeira esconde. Leia [adopt.md](adopt.md) agora e siga-o; ele envolve os passos abaixo.
- Caso contrário: repositório novo, siga só os passos abaixo.
- **Workspace:** se a pasta não for repositório git, mas tiver repositórios filhos (diretórios com `.git` até 3 níveis, fora de `node_modules`, `target`, `dist`, `build`, `vendor`, `.venv`), rode os passos para cada filho (cada um com seu `.claude/kit.json`) e proponha também um `.claude/kit.json` na pasta-mãe só com o que cruza repositórios: `repos` (lista explícita, opcional; sem ela os hooks descobrem os filhos) e regras `coupled_changes`/`key_parity` com caminhos relativos à pasta-mãe (`app/src/**` → `web/docs/**`). A pasta-mãe também recebe o `.claude/settings.json` que habilita o plugin, porque a sessão roda nela. Tudo entra na mesma confirmação.

## Modo reparo
Projeto já configurado pelo kit. Não refaça a entrevista; confira e proponha só o que falta, pelas mesmas regras de escrita:
- `.claude/kit.json`: JSON válido (`jq . .claude/kit.json`), chaves conhecidas (as de `templates/kit.example.json`, inclusive as de `map`; `repos` e `map.primary` só fazem sentido no `kit.json` da pasta-mãe), cada chave de `verify_on_stop` presente em `commands`, cada comando ainda existente no projeto (script do manifesto, target, ferramenta configurada).
- `.claude/settings.json`: plugin habilitado (`enabledPlugins` e `extraKnownMarketplaces` do kit), plugin LSP da linguagem (passo 8), um `Bash(<prefixo> *)` em `permissions.allow` por comando e o deny de `curl`/`wget` pela mesma regra do passo 5 (com `--net` listando arquivos, ele não entra e o relatório diz por quê). O que faltar entra pelo merge aditivo do passo 5.
- `.gitignore` com as linhas do passo 6.
- Mapa: rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh" --status`. Desatualizado: siga o `/kit:map` com `--update` (como no passo 11). Ausente: aplique a regra do passo 11.
- Depois, confirmação única (passo 9), gravação (passo 10) e relatório (passo 12), no mesmo formato.

## Regras que valem a tarefa inteira
- **Intocáveis:** `CLAUDE.md` existente, `.claude/settings.local.json`, `.mcp.json`, `.claude/skills/`, `.claude/agents/`, `.claude/commands/`, `.claude/rules/` (exceto as do `/kit:map`) e hooks, do projeto e do usuário. Nunca são editados, renomeados, desativados nem apagados.
- **Settings (`.claude/settings.json` e `~/.claude/settings.json`) só recebem merge aditivo**, sempre por `merge-json.sh --apply` (projeto) ou `setup.sh apply` (usuário): acrescenta itens em arrays (`allow`, `ask`, `deny`, `allowedDomains`, `excludedCommands`, ...) e chaves ausentes. Nunca remove, nunca troca valor existente, nunca mexe em `hooks`. Antes de gravar, o script faz backup em `<arquivo>.bak-kit-<data>`. Conflito (chave existe com outro valor) fica com o valor do usuário e vira uma linha no relatório, sem pedir ação. Única troca: `enabledPlugins."kit@claude-kit"` no settings de usuário, pela resposta de escopo.
- Arquivos do kit podem ser regravados: `.claude/kit.json`, `docs/claude-adoption.md` e os do `/kit:map` (`.claude/rules/map-*.md`, `.claude/rules/kit-codemap.md`, `docs/codemap.md`, com o cabeçalho `kit:map`). `CLAUDE.md` e settings ausentes podem ser criados.
- Sobreposição com o kit (hook, skill ou agent do projeto que faz o mesmo): quando a dona é a peça do projeto, o `Skill(kit:<nome>)`/`Agent(kit:<nome>)` entra em `permissions.deny` pelo merge aditivo. Hook do projeto que o kit cobre fica como está e é registrado em `docs/claude-adoption.md`.
- Nada é gravado antes da confirmação única. Única exceção: os arquivos do `/kit:map` no passo 11, que o mapa grava sem perguntar, como no `/kit:map` avulso: só arquivos do kit, com cabeçalho `kit:map`, reversíveis pelo git.
- Comandos propostos precisam existir no projeto: confira scripts do `package.json`, targets do Makefile, ferramentas já configuradas (lint, formatter, test runner). Não proponha ferramenta que o projeto não usa.
- Se `$ARGUMENTS` trouxer respostas pré-aprovadas (execução não interativa), use-as no lugar das perguntas da confirmação e não pergunte. Gravação aprovada vale para tudo o que o passo 9 mostraria, inclusive o merge aditivo nos settings; o que não foi respondido e depende de decisão fica de fora, e o relatório cita em uma linha.
- Raiz do plugin, chamada de `<raiz-do-plugin>` em [adopt.md](adopt.md): `${CLAUDE_PLUGIN_ROOT}`
- **Skills do kit lidas com Read** (setup no passo de máquina, map no passo 11): o arquivo vem cru, sem as substituições que o Claude Code faz quando a skill é chamada. Ao seguir o texto, troque `${CLAUDE_PLUGIN_ROOT}` e `${CLAUDE_SKILL_DIR}/../..` pela raiz do plugin acima, e `$ARGUMENTS` pelo argumento indicado aqui (vazio no setup e no mapa completo, `--update` no reparo). Os comandos da seção "Estado atual" daquela skill (as linhas que começam com exclamação) não rodam sozinhos: rode cada um com Bash antes de seguir.
- Templates em `${CLAUDE_PLUGIN_ROOT}/templates/`. Tabela de stacks em [stacks.md](stacks.md).

## Passos
1. **Detectar stacks.** Use a lista de manifestos acima (inclui subpastas de monorepo). Para cada manifesto, leia o suficiente para saber runner de teste, linter, formatter e se há migrações de banco. Leia também Makefile, `justfile`, `Taskfile.yml` e CI (`.github/workflows/*`) se existirem: o CI costuma ter os comandos reais.
2. **Monorepo.** Se houver pacotes com stacks diferentes em subpastas, a escolha entre um `kit.json` na raiz (comandos com `--prefix`/`cd`) ou um por pacote (os hooks usam o mais próximo do arquivo editado) vira pergunta da confirmação única, com a sua recomendação como primeira opção.
3. **Propor `.claude/kit.json`** a partir de `templates/kit.example.json` e de [stacks.md](stacks.md). O exemplo é de uma pasta-mãe com dois repositórios: num repositório único, deixe `repos` e `map.primary` de fora:
   - `commands`: `build`, `test`, `test_related` (com `{files}` só se o runner aceitar caminhos), `lint`, `typecheck` e, se o projeto tiver um teste rápido do sistema rodando (script de smoke, health check), `smoke`. Chave sem comando real fica de fora. Se o smoke depende de um dado que só o usuário sabe (URL, porta), ele vira pergunta da confirmação.
   - `format`: um glob por formatter já configurado no projeto.
   - `protected_paths`: migrações, código gerado, lockfiles se fizer sentido. Quando houver o que fazer em vez de editar, use a forma objeto com mensagem: `{ "glob": "<gerado>/**", "message": "Gerado por <comando>. Edite em <fonte> e rode <comando>." }`; `"write": "deny"` para binários, bancos locais e artefatos que nem devem ser criados.
   - `plan_dirs`: se o projeto já guarda planos fora de `docs/specs/` (ex.: `.claude/plans`), liste os diretórios para o plano ativo aparecer no contexto. `inject_plan_on_prompt: true` só se o usuário pedir: repete a linha do plano a cada mensagem e custa contexto.
   - `verify_on_stop`: o conjunto mais rápido que pega erro real (normalmente `build` ou `typecheck` + `test_related`).
   - `source_globs`: extensões de código-fonte do stack.
4. **Checks de domínio.** Detecte e proponha, sem perguntar à parte:
   - **i18n**: procure `**/i18n/*.json`, `**/locales/**/*.json`, `**/lang/*.json` e qualquer pasta com dois ou mais JSON nomeados por código de idioma (`pt.json`, `en-US.json`, `pt_BR.json`, ou subpastas `pt/`, `en/` com os mesmos nomes de arquivo), como `strings/` ou `translations/`; ignore pastas de código gerado. Se houver, proponha `key_parity` com os arquivos de cada conjunto e uma `message` curta.
   - **arquivos acoplados**: pares que precisam mudar juntos (telas ↔ manual, schema ↔ migração, contrato de API ↔ cliente gerado, código ↔ doc de referência). Se houver, proponha `coupled_changes` com `when`, `require` e `message` dizendo o que atualizar, com `"level": "block"` (padrão) ou `"level": "warn"` para acoplamentos do tipo "se mudou X, confira Y". `hint` é opcional: texto extra, como o comando que regenera o par.
   - O que for detectado aparece no diff do `kit.json` na confirmação; "Ajustar" cobre tirar ou mudar o nível.
5. **Propor `.claude/settings.json`** a partir de `templates/project-settings.json`:
   - `extraKnownMarketplaces` e `enabledPlugins` para `kit@claude-kit`. O marketplace é o repositório GitHub `r-matias/claude-kit`.
   - `enabledPlugins` do plugin LSP oficial (passo 8).
   - `permissions.allow`: um `Bash(<prefixo> *)` por comando do `kit.json`.
   - `permissions.ask`: instalação de dependência e migração de banco do stack.
   - `permissions.deny`: `Bash(curl *)` e `Bash(wget *)` (o registry do stack fica liberado em `allowedDomains`), só se o projeto não usa nenhum dos dois. Antes de propor, rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/inventory.sh" --net`: ele lista, um por linha, os arquivos que usam `curl`/`wget` em `.claude/skills`, `.claude/agents`, `.claude/commands`, `.claude/hooks`, nos comandos de hook dos settings e nos scripts que eles chamam, nos scripts do `package.json`, no `Makefile` e no `justfile`. Com qualquer linha, ou se `commands.smoke` usar `curl`/`wget`, deixe as duas regras de fora e registre no relatório a linha exata `curl/wget usados por N arquivos do projeto; deny não aplicado` (N = linhas do `--net`, mais 1 pelo smoke). Mais os `Skill(kit:<nome>)`/`Agent(kit:<nome>)` das sobreposições.
   - `sandbox.network.allowedDomains`: registry do stack (ver [stacks.md](stacks.md)).
   - Testes de integração com banco/Docker: o sandbox os bloqueia; proponha `sandbox.excludedCommands` só com o comando exato da suíte mais uma regra `ask` para ele.
   - Grave a proposta num temporário e rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-json.sh" --preview .claude/settings.json <proposta>`: mostra o arquivo novo ou o diff do merge aditivo e as linhas `conflito:`. Nada é gravado aqui.
6. **`.gitignore`**: precisa ignorar `.claude/state/` (snapshot de compactação do kit) e `.claude/*.bak-kit-*` (backups do merge). Sem `.gitignore`, proponha criar; com `.gitignore` sem essas linhas, proponha acrescentá-las no fim (só acrescenta).
7. **`CLAUDE.md`.** Inexistente: proponha um a partir de `templates/CLAUDE.project.md`, com no máximo ~60 linhas: só o que o código não explica (decisões de arquitetura, guardrails de domínio, convenções fora do padrão). Cada linha passa no teste "remover esta linha faria Claude errar?". Existente: não toque e não sugira nada.
8. **LSP.** Rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" lsp`. Cada linha `lsp <plugin> ...` vira `"<plugin>": true` em `enabledPlugins` da proposta do passo 5. `falta — instale: <comando>`: o comando entra na confirmação e roda se aprovado. `falta — sem instalação automática`: o plugin entra mesmo assim e o relatório tem um aviso de uma linha. Sem linha: linguagem sem LSP oficial, não mencione.
9. **Confirmação única.** Mostre, em sequência e sem pedir nada no meio: o settings de usuário (`setup.sh propose todos`, se o passo de máquina propôs), cada arquivo novo, o diff de cada arquivo existente (`merge-json.sh --preview`, `.gitignore`), os comandos de instalação (dependência da máquina, LSP) e as linhas `conflito:`. Depois, **uma** chamada de `AskUserQuestion` com até 4 perguntas:
   - "Gravar e instalar tudo?": Gravar tudo (recomendado) / Ajustar / Cancelar. "Ajustar": aplique o ajuste e mostre só o que mudou, com a mesma pergunta.
   - Escopo do kit, só se o settings de usuário entra: "Todos os projetos" ou "Só nos projetos que o habilitam".
   - Decisões que só o usuário pode tomar (monorepo do passo 2, URL do smoke), cada uma com a sua recomendação como primeira opção. Mais de 2: use a recomendação nas excedentes e mostre-a no diff.
10. **Gravar e verificar**, só o que foi aprovado:
   - Máquina: comandos de instalação de dependência aprovados; depois `setup.sh status` de novo. Escopo "Só nos projetos que o habilitam": rode `setup.sh propose opt-in` antes. Settings de usuário: `setup.sh apply`.
   - Arquivos novos e do kit: grave direto. `.claude/settings.json`: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-json.sh" --apply .claude/settings.json <proposta>`. `.gitignore`: acrescente as linhas no fim.
   - Comandos de instalação de LSP aprovados. Se o sandbox bloquear a instalação global, rode de novo fora do sandbox (o Claude Code pede a confirmação dele).
   - Valide o JSON (`jq . .claude/kit.json`) e rode uma vez cada comando de `verify_on_stop`.
11. **Mapa.** Rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh"` na pasta da sessão. Se `totals.files` passar de 300 ou `repos` tiver mais de um repositório, leia `${CLAUDE_PLUGIN_ROOT}/skills/map/SKILL.md` e execute o fluxo dele sem argumento, sem perguntar (ele mesmo só pergunta acima de `map.max_agents`, padrão 30). Caso contrário, não mapeie e não mencione.
12. **Relatório final**, no máximo ~10 linhas, também no modo reparo:
   - O que foi feito: arquivos criados e alterados, cada alterado com "backup em `<arquivo>.bak-kit-<data>`"; instalações feitas; mapa gerado, se houve. Modo adotar: "detalhes em `docs/claude-adoption.md`".
   - O que foi verificado: cada comando de `verify_on_stop` com `ok` ou `falhou` (e a primeira linha útil do erro).
   - Avisos de verdade, uma linha cada: Windows nativo sem sandbox, LSP sem instalação automática, dependência que não instalou, conflito mantido (`<chave>: mantido <valor do usuário>`), `curl/wget usados por N arquivos do projeto; deny não aplicado` (passo 5), decisão não respondida no modo não interativo.
   - Planos parados: rode `bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" plans` e, se houver saída, repita as linhas como estão, sem sugerir nada.
   - Última linha, sempre: `Pronto. Próximo: /kit:spec <ideia>`
   Nada de "rode", "instale", "aplique" ou "revise" fora da última linha.
