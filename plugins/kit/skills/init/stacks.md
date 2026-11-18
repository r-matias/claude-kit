# Referência de stacks para /kit:init

Valores de partida. Confirme sempre contra o que o projeto realmente usa (scripts, CI, configs de lint/format).

## Comandos

| Stack | build | test | test_related | lint | typecheck | format (glob → comando) |
| --- | --- | --- | --- | --- | --- | --- |
| .NET | `dotnet build --nologo -v q` | `dotnet test --nologo` | — (filtro é por nome, não por arquivo) | `dotnet format --verify-no-changes` | — | `**/*.cs` → `dotnet format --include {files}` |
| Node/TS (npm) | `npm run build` | `npm test` | `npx vitest related --run {files}` ou `npx jest --findRelatedTests {files}` | `{ "run": "npx eslint {files}", "files": ["**/*.{ts,tsx,js,jsx}"] }` ou `npm run lint` | `npx tsc --noEmit` | `**/*.{ts,tsx,js,jsx,json,css,scss,html,md}` → `npx prettier --write {files}`; com Biome: `npx biome check --write {files}` |
| Node (pnpm/yarn/bun) | troque `npm run`/`npx` por `pnpm`/`yarn`/`bun` | | | | | |
| Python (uv) | `uv run python -m compileall -q src` | `uv run pytest -q` | `uv run pytest -q {files}` (só se os arquivos forem de teste) | `{ "run": "uv run ruff check {files}", "files": ["**/*.py"] }` | `uv run mypy .` ou `uv run pyright` | `**/*.py` → `uv run ruff check --fix {files} && uv run ruff format {files}` |
| Python (pip/poetry) | troque `uv run` por `python -m` / `poetry run` | | | | | |
| Go | `go build ./...` | `go test ./...` | — | `golangci-lint run` | `go vet ./...` | `**/*.go` → `gofmt -w {files}` |
| Rust | `cargo build -q` | `cargo test -q` | — | `cargo clippy -q -- -D warnings` | `cargo check -q` | `**/*.rs` → `rustfmt {files}` |
| Java (Maven) | `mvn -q -DskipTests compile` | `mvn -q test` | — | — | — | `**/*.java` → conforme o formatter do projeto (spotless: `mvn -q spotless:apply`) |
| Java/Kotlin (Gradle) | `./gradlew -q assemble` | `./gradlew -q test` | — | `./gradlew -q check -x test` | — | spotless/ktlint se configurado |
| Ruby | — | `bundle exec rspec` | `bundle exec rspec {files}` (só specs) | `{ "run": "bundle exec rubocop {files}", "files": ["**/*.rb"] }` | — | `**/*.rb` → `bundle exec rubocop -a {files}` |
| PHP | — | `vendor/bin/phpunit` | — | `{ "run": "vendor/bin/phpstan analyse {files}", "files": ["**/*.php"] }` | — | `**/*.php` → `vendor/bin/php-cs-fixer fix {files}` |

### Lint: no `format` e no gate

- **Forma objeto.** `{ "run": "<comando> {files}", "files": [<globs>] }` só roda no gate quando algum alterado casa `files`, e `{files}` recebe só esses. É a forma do `lint` sempre que a ferramenta aceita arquivos: num repositório com duas linguagens, o lint de uma não recebe arquivo da outra. Os globs de `files` valem no lugar de `source_globs` para esse comando.
- **Autofix no `format`** (lint corrigido a cada edição, o que sobra chega ao Claude na hora): só com ferramenta que o projeto já usa, que aceita um arquivo e roda em cerca de um segundo, e só se o `lint` do projeto passa hoje. Com dívida antiga, toda edição de arquivo antigo devolveria os achados antigos: o `format` fica só formatando. Fora do `format`: `dotnet format` (carrega o projeto), ESLint com regras que usam tipos (`parserOptions.project` ou `projectService` na config), `golangci-lint` e `clippy` (pacote ou crate inteiro). ESLint sem regras de tipo pode entrar: `npx eslint --fix {files} && npx prettier --write {files}`.
- **`lint` no `verify_on_stop`**: entra quando o projeto tem linter, de preferência na forma objeto com `{files}`. Lint sem `{files}` (projeto inteiro) só entra se passa hoje; com dívida antiga, fica fora do gate e o relatório diz em uma linha.

## Teste junto com o código (`coupled_changes` com `warn`)

Regra "código mudou sem teste": `when` com o código de produção, `require` com os testes, `level: "warn"`. Avisa na edição, uma vez por arquivo por sessão, e não bloqueia: refatoração e mudança sem comportamento novo não precisam de teste novo. Editar um arquivo que casa `require` não avisa, então glob de código que também cobre os testes (testes ao lado do código) funciona. Use a pasta e o padrão de nome de teste que o projeto já usa; sem pasta de testes nem padrão claro, não proponha.

| Stack | `when` | `require` |
| --- | --- | --- |
| .NET | `src/**/*.cs` | `tests/**`, `**/*.Tests/**` |
| Node/TS | `src/**/*.{ts,tsx,js,jsx}` | `**/*.{test,spec}.{ts,tsx,js,jsx}`, `**/__tests__/**`, `test/**`, `tests/**` |
| Python | `src/**/*.py` (ou a pasta do pacote) | `tests/**`, `**/test_*.py`, `**/*_test.py` |
| Go | `**/*.go` | `**/*_test.go` |
| Rust | `src/**/*.rs` | `tests/**` (só se o projeto tem a pasta; teste em `mod tests` no mesmo arquivo não conta) |
| Java/Kotlin | `src/main/**` | `src/test/**` |
| Ruby | `app/**/*.rb`, `lib/**/*.rb` | `spec/**`, `test/**` |
| PHP | `src/**/*.php`, `app/**/*.php` | `tests/**` |

Mensagem sugerida: `Código mudou; se o comportamento mudou, o teste muda junto.`

## `diff_deny` (padrões de partida)

Padrões ERE checados só nas linhas adicionadas no turno. Proponha só os das linguagens do projeto, com `level: "block"` e a mensagem `Supressão nova. Corrija a causa; se for inevitável, justifique em .claude/kit-skip.` (ou `Teste pulado ou focado.` para a segunda coluna). Padrão curto e específico: regex largo bloqueia o que não devia.

| Stack | `files` | Supressão de lint ou tipo | Teste pulado ou focado |
| --- | --- | --- | --- |
| Node/TS | `**/*.{ts,tsx,js,jsx}` | `@ts-ignore\|@ts-nocheck\|eslint-disable` | `(^\|[^A-Za-z0-9_.])(it\|test\|describe)\.(only\|skip)\(` |
| Python | `**/*.py` | `#[[:space:]]*type:[[:space:]]*ignore\|#[[:space:]]*noqa\|#[[:space:]]*pyright:[[:space:]]*ignore` | `@pytest\.mark\.skip\|@unittest\.skip` |
| Go | `**/*.go` | `//[[:space:]]*nolint` | `t\.Skip\(` |
| Rust | `**/*.rs` | `#\[allow\(` | `#\[ignore\]` |
| .NET | `**/*.cs` | `#pragma warning disable\|SuppressMessage` | `\[(Fact\|Theory)[^]]*Skip[[:space:]]*=\|\[Ignore[](]` |
| Java/Kotlin | `**/*.{java,kt}` | `@SuppressWarnings\|@Suppress\(` | `@(Disabled\|Ignore)([^A-Za-z0-9_]\|$)` |
| Ruby | `**/*.rb` | `rubocop:disable` | `^[[:space:]]*(xit\|xdescribe\|fit\|fdescribe)[[:space:]]` |
| PHP | `**/*.php` | `@phpstan-ignore\|@psalm-suppress` | `markTestSkipped` |

Na tabela, `\|` é o `|` do padrão (escapado só por causa da tabela). No JSON, cada `\` vira `\\`: `"pattern": "@ts-ignore|@ts-nocheck|eslint-disable"`, `"pattern": "t\\.Skip\\("`.

Anotação de teste com homônimo no código de produção (o `@Ignore` do Room, em Android): na regra de teste pulado, troque `files` pelas pastas de teste do projeto (`**/src/test/**`, `**/src/androidTest/**`).

## Interface (`ui`)

Só em projeto com tela. `dev` é o comando que o projeto já usa para subir o app em desenvolvimento e `url` é o endereço em que ele responde; confira a porta na configuração do projeto antes de propor. Framework fora da tabela: leia o script de desenvolvimento do manifesto.

| Framework | `dev` | `url` de partida |
| --- | --- | --- |
| Vite (React, Vue, Svelte, SvelteKit) | `npm run dev` | `http://localhost:5173` |
| Next.js, Nuxt, Remix, Create React App | `npm run dev` (CRA: `npm start`) | `http://localhost:3000` |
| Angular | `npm start` | `http://localhost:4200` |
| Astro | `npm run dev` | `http://localhost:4321` |
| ASP.NET (Razor, Blazor) | `dotnet run --project <projeto web>` | o `applicationUrl` de `Properties/launchSettings.json` |
| Django | `python manage.py runserver` | `http://127.0.0.1:8000` |
| Rails | `bin/rails server` | `http://localhost:3000` |
| Laravel | `php artisan serve` | `http://127.0.0.1:8000` |
| HTML estático | o servidor estático que o projeto já usa | o endereço dele |

- `globs`: os arquivos de tela, componente e estilo. O `ui.sh status` propõe pelas extensões; tela escrita em arquivo de código (`.js`, `.py`, `.dart`, `.kt`, `.swift`) entra pela pasta, como `src/views/**/*.js`.
- `routes`: rotas que abrem sem login. Tela atrás de login ou clique não entra aqui: o `/kit:execute` a captura com os passos que levam até ela (`--steps`).
- `screenshot`: só para tela que não abre em navegador. É o comando do projeto que grava a imagem da tela em `{out}` (também aceita `{url}`, `{route}`, `{width}` e `{height}`), como o do simulador ou do emulador. `{out}`, `{url}` e `{route}` já entram entre aspas; comando que precisa deles no meio de outro texto usa `$KIT_UI_OUT`, `$KIT_UI_URL` e `$KIT_UI_ROUTE`.
- A captura do kit não usa nenhuma ferramenta do stack: precisa de `node` 16 ou mais novo e de um navegador Chromium instalado (Chrome, Edge, Chromium ou o do Playwright). Se o projeto tem `axe-core` em `node_modules`, a sondagem roda as regras dele junto.

## Ask (instalação e migração)

| Stack | ask |
| --- | --- |
| .NET | `Bash(dotnet add package *)`, `Bash(dotnet ef database update *)`, `Bash(dotnet ef migrations remove *)` |
| Node | `Bash(npm install *)`, `Bash(npm i *)`, `Bash(pnpm add *)`, `Bash(yarn add *)`, migração do ORM (`Bash(npx prisma migrate *)`, `Bash(npx knex migrate *)`) |
| Python | `Bash(uv add *)`, `Bash(pip install *)`, `Bash(poetry add *)`, `Bash(alembic upgrade *)`, `Bash(python manage.py migrate *)` |
| Go | `Bash(go get *)`, ferramenta de migração (`Bash(migrate *)`, `Bash(goose *)`) |
| Rust | `Bash(cargo add *)`, `Bash(sqlx migrate *)`, `Bash(diesel migration *)` |
| Java | dependência entra por edição do pom/gradle; migração: `Bash(mvn flyway:migrate *)`, `Bash(./gradlew flywayMigrate *)` |
| Ruby | `Bash(bundle add *)`, `Bash(bin/rails db:migrate *)` |
| PHP | `Bash(composer require *)`, `Bash(php artisan migrate *)` |

## protected_paths comuns

| Stack | Caminhos |
| --- | --- |
| .NET (EF Core) | `**/Migrations/**` |
| Node | `**/prisma/migrations/**`, `**/*.generated.*`, `**/dist/**` |
| Python | `**/migrations/versions/**` (alembic), `**/migrations/0*.py` (Django) |
| Go | `**/*.pb.go`, `**/*_gen.go`, `**/migrations/**` |
| Rust | `**/migrations/**` |
| Ruby | `db/schema.rb`, `db/migrate/**` |

## source_globs

| Stack | Globs |
| --- | --- |
| .NET | `**/*.cs`, `**/*.csproj`, `**/*.razor` |
| Node/TS | `**/*.{ts,tsx,js,jsx,mjs,cjs}`, `**/package.json` |
| Python | `**/*.py`, `pyproject.toml` |
| Go | `**/*.go`, `go.mod` |
| Rust | `**/*.rs`, `Cargo.toml` |
| Java/Kotlin | `**/*.{java,kt}`, `pom.xml`, `**/*.gradle*` |
| Ruby | `**/*.rb` |
| PHP | `**/*.php` |

## allowedDomains (registry)

| Stack | Domínios |
| --- | --- |
| .NET | `api.nuget.org` |
| Node | `registry.npmjs.org` (yarn: `registry.yarnpkg.com`) |
| Python | `pypi.org`, `files.pythonhosted.org` |
| Go | `proxy.golang.org`, `sum.golang.org` |
| Rust | `crates.io`, `index.crates.io`, `static.crates.io` |
| Java | `repo.maven.apache.org`, `plugins.gradle.org`, `services.gradle.org` |
| Ruby | `rubygems.org`, `index.rubygems.org` |
| PHP | `repo.packagist.org` |

## Plugin LSP

Marketplace `claude-plugins-official` (já conhecido pelo Claude Code), menos Node/TS: o `ts-lsp@claude-kit` sobe o mesmo `typescript-language-server`, mas com o heap do tsserver limitado a 3072 MB e reinício quando a árvore do servidor passa de `KIT_TS_LSP_MAX_MB` (padrão 6144). O `typescript-lsp` oficial não tem teto e já chegou a dezenas de GB numa sessão longa. O `setup.sh lsp` detecta pelos manifestos, confere o binário e devolve o comando de instalação; esta tabela é a mesma do script.

| Stack | Manifesto | Plugin (`enabledPlugins`) | Binário | Instalação |
| --- | --- | --- | --- | --- |
| .NET | `*.sln`, `*.csproj` | `csharp-lsp@claude-plugins-official` | `csharp-ls` | `dotnet tool install --global csharp-ls` |
| Node/TS | `package.json`, `tsconfig.json` | `ts-lsp@claude-kit` | `typescript-language-server` | `npm install -g typescript-language-server typescript` |
| Python | `pyproject.toml`, `requirements*.txt`, `setup.py`, `Pipfile` | `pyright-lsp@claude-plugins-official` | `pyright-langserver` | `npm install -g pyright` |
| Go | `go.mod` | `gopls-lsp@claude-plugins-official` | `gopls` | `go install golang.org/x/tools/gopls@latest` |
| Rust | `Cargo.toml` | `rust-analyzer-lsp@claude-plugins-official` | `rust-analyzer` | `rustup component add rust-analyzer` |
| Java | `*.java` | `jdtls-lsp@claude-plugins-official` | `jdtls` | macOS: `brew install jdtls`; outras: sem instalação automática |
| Kotlin | `*.kt` | `kotlin-lsp@claude-plugins-official` | `kotlin-lsp` | macOS: `brew install JetBrains/utils/kotlin-lsp`; outras: sem instalação automática |
| Ruby | `Gemfile` | `ruby-lsp@claude-plugins-official` | `ruby-lsp` | `gem install ruby-lsp` |
| PHP | `composer.json` | `php-lsp@claude-plugins-official` | `intelephense` | `npm install -g intelephense` |
| Swift | `Package.swift` | `swift-lsp@claude-plugins-official` | `sourcekit-lsp` | vem com o Xcode ou o toolchain Swift |
