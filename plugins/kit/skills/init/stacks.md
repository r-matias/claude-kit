# Referência de stacks para /kit:init

Valores de partida. Confirme sempre contra o que o projeto realmente usa (scripts, CI, configs de lint/format).

## Comandos

| Stack | build | test | test_related | lint | typecheck | format (glob → comando) |
| --- | --- | --- | --- | --- | --- | --- |
| .NET | `dotnet build --nologo -v q` | `dotnet test --nologo` | — (filtro é por nome, não por arquivo) | `dotnet format --verify-no-changes` | — | `**/*.cs` → `dotnet format --include {files}` |
| Node/TS (npm) | `npm run build` | `npm test` | `npx vitest related --run {files}` ou `npx jest --findRelatedTests {files}` | `npm run lint` | `npx tsc --noEmit` | `**/*.{ts,tsx,js,jsx,json,css,scss,html,md}` → `npx prettier --write {files}` |
| Node (pnpm/yarn/bun) | troque `npm run`/`npx` por `pnpm`/`yarn`/`bun` | | | | | |
| Python (uv) | `uv run python -m compileall -q src` | `uv run pytest -q` | `uv run pytest -q {files}` (só se os arquivos forem de teste) | `uv run ruff check .` | `uv run mypy .` ou `uv run pyright` | `**/*.py` → `uv run ruff format {files}` |
| Python (pip/poetry) | troque `uv run` por `python -m` / `poetry run` | | | | | |
| Go | `go build ./...` | `go test ./...` | — | `golangci-lint run` | `go vet ./...` | `**/*.go` → `gofmt -w {files}` |
| Rust | `cargo build -q` | `cargo test -q` | — | `cargo clippy -q -- -D warnings` | `cargo check -q` | `**/*.rs` → `rustfmt {files}` |
| Java (Maven) | `mvn -q -DskipTests compile` | `mvn -q test` | — | — | — | `**/*.java` → conforme o formatter do projeto (spotless: `mvn -q spotless:apply`) |
| Java/Kotlin (Gradle) | `./gradlew -q assemble` | `./gradlew -q test` | — | `./gradlew -q check -x test` | — | spotless/ktlint se configurado |
| Ruby | — | `bundle exec rspec` | `bundle exec rspec {files}` (só specs) | `bundle exec rubocop` | — | `**/*.rb` → `bundle exec rubocop -a {files}` |
| PHP | — | `vendor/bin/phpunit` | — | `vendor/bin/phpstan analyse` | — | `**/*.php` → `vendor/bin/php-cs-fixer fix {files}` |

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

## Plugin LSP oficial

Marketplace `claude-plugins-official` (já conhecido pelo Claude Code). O `setup.sh lsp` detecta pelos manifestos, confere o binário e devolve o comando de instalação; esta tabela é a mesma do script.

| Stack | Manifesto | Plugin (`enabledPlugins`) | Binário | Instalação |
| --- | --- | --- | --- | --- |
| .NET | `*.sln`, `*.csproj` | `csharp-lsp@claude-plugins-official` | `csharp-ls` | `dotnet tool install --global csharp-ls` |
| Node/TS | `package.json`, `tsconfig.json` | `typescript-lsp@claude-plugins-official` | `typescript-language-server` | `npm install -g typescript-language-server typescript` |
| Python | `pyproject.toml`, `requirements*.txt`, `setup.py`, `Pipfile` | `pyright-lsp@claude-plugins-official` | `pyright-langserver` | `npm install -g pyright` |
| Go | `go.mod` | `gopls-lsp@claude-plugins-official` | `gopls` | `go install golang.org/x/tools/gopls@latest` |
| Rust | `Cargo.toml` | `rust-analyzer-lsp@claude-plugins-official` | `rust-analyzer` | `rustup component add rust-analyzer` |
| Java | `*.java` | `jdtls-lsp@claude-plugins-official` | `jdtls` | macOS: `brew install jdtls`; outras: sem instalação automática |
| Kotlin | `*.kt` | `kotlin-lsp@claude-plugins-official` | `kotlin-lsp` | macOS: `brew install JetBrains/utils/kotlin-lsp`; outras: sem instalação automática |
| Ruby | `Gemfile` | `ruby-lsp@claude-plugins-official` | `ruby-lsp` | `gem install ruby-lsp` |
| PHP | `composer.json` | `php-lsp@claude-plugins-official` | `intelephense` | `npm install -g intelephense` |
| Swift | `Package.swift` | `swift-lsp@claude-plugins-official` | `sourcekit-lsp` | vem com o Xcode ou o toolchain Swift |
