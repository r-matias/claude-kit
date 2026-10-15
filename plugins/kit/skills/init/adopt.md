# Modo adotar

O repositório já tem configuração do Claude Code. O kit só soma: `CLAUDE.md`, `.claude/settings.local.json`, `.mcp.json`, skills, agents, commands, rules e hooks do projeto ficam intactos. O `.claude/settings.json` só recebe o merge aditivo do passo 5 do SKILL.md (com backup e dentro da confirmação única). O que o kit não pode fazer sozinho (desligar um hook do projeto, por exemplo) fica registrado em `docs/claude-adoption.md`.

Siga estas etapas e, dentro da etapa 4, os passos do SKILL.md.

## 1. Inventário

Rode `bash "<raiz-do-plugin>/scripts/inventory.sh"`. Ele lista hooks de todos os settings (projeto, local e usuário), skills, commands, agents, rules, CLAUDE.md e servidores MCP.

Para cada peça, leia o conteúdo (script do hook, corpo da skill/agent) e registre:
- **o que faz ou verifica**, em uma frase;
- **quando dispara** (evento + matcher, invocação manual/automática, `paths:` da rule).

Hooks e settings de `~/.claude` são da camada de usuário: entram no inventário para detectar sobreposição e também não são alterados.

A seção "Riscos e sobreposições" do inventário já traz detecções prontas. Cada linha vira uma entrada na tabela do relatório, com a sugestão e o motivo:

| Marca | O que significa | Sugestão padrão |
| --- | --- | --- |
| `[sobreposição] skill` | Skill do projeto com o mesmo propósito de uma skill do kit. Se a do projeto tem `disable-model-invocation: true` e a do kit não, o Claude escolhe sozinho a do kit para pedidos como "corrige esse bug". | A skill do projeto é a dona: `Skill(kit:<nome>)` em `permissions.deny` (entra no merge aditivo do `.claude/settings.json`), com o motivo no relatório de adoção. |
| `[sobreposição] agent` | Agent do projeto com o mesmo papel de um agent do kit. | O agent do projeto é o dono: `Agent(kit:<nome>)` em `permissions.deny` (merge aditivo). |
| `[aviso possivelmente mudo]` | Hook PreToolUse, PostToolUse ou Stop que imprime texto no stdout sem JSON `additionalContext`; com exit 0 o texto não chega ao Claude. | Declarar o acoplamento em `coupled_changes` com `level: "warn"` no `kit.json` e sugerir que o usuário desligue o hook, ou que troque a saída do script para JSON `additionalContext`. |
| `[falha aberta]` | Hook PreToolUse que faz `jq ... \|\| exit 0`: sem jq, a guarda libera tudo. | Declarar os caminhos em `protected_paths` (mensagem por item) e sugerir que o usuário desligue o hook ou troque para exit 2. |
| `[efeito colateral]` | Skill de deploy, release, backup, push, migração ou publicação sem `disable-model-invocation: true`. | Listar; sugerir o campo. |
| `[settings.local.json versionado]`, `[sintaxe antiga]`, `[sem deny de segredos]` | Configuração pessoal no git, regra `Tool(x:*)` e ausência de `Read(...)` em deny para `.env`, chaves e `secrets/`. | Listar. |

Listas de bloqueio do projeto (hook que nega edição de caminhos com uma mensagem) viram itens de `protected_paths` em forma de objeto no `kit.json`, com a mesma mensagem que o hook original mostrava: `{ "glob": "<caminho>/**", "message": "<texto do hook>" }`. Use `"write": "deny"` quando o hook também impede criar arquivos ali. O hook do projeto continua como está.

## 2. Classificação

Cada peça recebe um destino; nenhum muda o arquivo da peça:

| Sugestão | Quando | Exemplo |
| --- | --- | --- |
| Manter no projeto | Regra de domínio que não dá para expressar de forma genérica | Checagem que exige ler o conteúdo do manual |
| Desativar a do projeto | O kit faz o mesmo ou mais | Hook próprio que bloqueia `rm -rf` → `guard-bash`; o relatório diz qual entrada do settings o usuário remove |
| Desativar a do kit | A peça do projeto é a dona | Skill de fix do projeto → `Skill(kit:fix)` em deny, gravado pelo merge aditivo |
| Declarar no `kit.json` | Cabe em `coupled_changes`, `key_parity` ou `protected_paths` | Tela mudou sem manual; i18n faltando em uma língua. O `kit.json` é do kit e recebe a declaração; o hook original fica |
| Promover ao kit | Genérico e útil em outros projetos, mas o kit ainda não tem | Vira nova feature do plugin, implementada e testada no repo do kit, não aqui |
| Somar | Ambos agregam algo diferente | Sugerir que a skill de review do projeto chame `kit:code-reviewer`; o usuário edita se quiser |

Equivalentes do kit para comparar:
- Hooks: `guard-bash` (comandos destrutivos), `guard-files` (segredos, `protected_paths` com mensagem por item), `format` (formatter por glob), `advise` (avisos `coupled_changes` com `level: "warn"` na edição), `verify-gate` (build/teste, `key_parity`, `coupled_changes` no Stop, em todos os repositórios da sessão), `session-context` e `pre-compact` (branch, alterados, planos ativos, snapshot na compactação). Comportamento exato no README do kit.
- Skills: `spec`, `plan`, `execute`, `epic`, `fix`, `hunt`, `map`.
- Agents: `investigator`, `code-reviewer`, `plan-reviewer`, `security-reviewer`, `test-writer`, `mapper`, `map-verifier`.

**Sobreposições:** dois hooks bloqueando a mesma coisa (mensagens duplicadas, tempo extra) e duas skills ou agents de review com escopos parecidos (Claude escolhe um de forma imprevisível). Quando a dona é a peça do projeto, o kit se desliga pelo deny do merge aditivo. Quando a dona é o kit, a peça do projeto fica como está e `docs/claude-adoption.md` registra qual é e como desligá-la.

## 3. Prova de equivalência

Obrigatória para toda sugestão "Desativar a do projeto" ou "Declarar no `kit.json`" no lugar de um hook: sem prova, a sugestão vira "Manter no projeto". A prova roda o mesmo cenário nos dois lados, sem alterar nada, e mostra o mesmo bloqueio ou aviso.

- **Hook de PreToolUse** (ex.: bloqueio de `rm -rf`): monte o JSON de entrada e passe pelos dois scripts.

  ```bash
  IN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"},"cwd":"'"$PWD"'"}'
  printf '%s' "$IN" | bash .claude/hooks/<hook-do-projeto>.sh; echo "exit=$?"
  printf '%s' "$IN" | bash "<raiz-do-plugin>/scripts/guard-bash.sh"; echo "exit=$?"
  ```

  Equivalente = os dois bloqueiam (exit 2, ou JSON com `permissionDecision: "deny"`). Repita para cada caso que o hook original cobre, inclusive um caso que deve passar.
- **Hook ou agent virando `coupled_changes`/`key_parity`**: prove num worktree descartável, sem tocar na árvore de trabalho. O worktree fica dentro do repositório, em `.kit-proof/`: o sandbox só libera escrita na pasta do projeto, e `../` ficaria fora dele. Enquanto existir, `.kit-proof/` aparece como não rastreado; não edite o `.gitignore` por isso, só remova o worktree no fim e confira que `git status` voltou ao que era. Se mesmo assim o sandbox recusar a criação, pule a prova, marque a linha como "não provado (sandbox)" e siga.

  ```bash
  git worktree add --detach .kit-proof HEAD
  # copiar o kit.json proposto para .kit-proof/.claude/kit.json e fazer a mudança que dispara a regra
  printf '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"%s"}' "$(cd .kit-proof && pwd)" | bash "<raiz-do-plugin>/scripts/verify-gate.sh"; echo "exit=$?"
  git worktree remove --force .kit-proof
  ```

  Equivalente = exit 2 com a mensagem da regra no cenário que o original pegava, e exit 0 no cenário corrigido.
- **Skill ou agent**: liste os itens que o original verifica e aponte onde cada um está coberto no equivalente do kit. Item sem cobertura muda a sugestão para "Somar" ou "Manter".

## 4. Adições

Siga os passos do SKILL.md com as regras de escrita: arquivos novos ou do kit (`.claude/kit.json`, `docs/claude-adoption.md`), merge aditivo no `.claude/settings.json` (`merge-json.sh --preview` na confirmação, `--apply` depois), tudo na confirmação única. Declarações (`coupled_changes`, `key_parity`, `protected_paths`) vão para o `kit.json`. O que tocaria `CLAUDE.md`, skills, agents, rules ou hooks existentes só fica registrado em `docs/claude-adoption.md`.

## 5. Relatório

Grave `docs/claude-adoption.md` (arquivo do kit; se já existir, acrescente uma seção nova com a data):

```markdown
# Adoção do kit

Data: <AAAA-MM-DD> · Versão do kit: <version do plugin.json>

O kit não alterou `CLAUDE.md`, skills, agents, rules, hooks nem `settings.local.json`. No `.claude/settings.json` só acrescentou (backup em `.claude/settings.json.bak-kit-<data>`).

## Peças
| Peça | Tipo | Origem | O que faz | Quando dispara | Sugestão | Prova |
| --- | --- | --- | --- | --- | --- | --- |
| no-rm-rf.sh | hook | .claude/settings.json | bloqueia rm -rf | PreToolUse Bash | Desativar a do projeto (guard-bash cobre): remover a entrada PreToolUse do settings | `rm -rf /tmp/x`: ambos exit 2/deny |

## Sobreposições
- <peça A> × <peça B>: dona sugerida = <...>; para desativar a outra: <como>.

## Riscos detectados
| Marca | Peça | Motivo | Sugestão |
| --- | --- | --- | --- |
| sobreposição | skill fix | a do projeto tem disable-model-invocation: true e a do kit não; o Claude escolheria kit:fix sozinho | `Skill(kit:fix)` em permissions.deny (gravado no .claude/settings.json) |

## Acrescentado ao settings
- `.claude/settings.json`: <resumo do que somou> (diff abaixo); conflitos mantidos: <chave: valor do usuário>; não aplicado: <deny que sombrearia uma regra de allow/ask>

## Promover ao kit
- <peça>: <o que faria no kit e por que é genérica>

## Registro de kit-skip
```

A seção "Registro de kit-skip" fica vazia; o `verify-gate` acrescenta ali cada justificativa usada.
