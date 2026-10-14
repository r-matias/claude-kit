# Modo adotar

O repositório já tem configuração do Claude Code. O kit entra somando: nada existente é apagado ou sobrescrito sozinho, e uma peça só é removida depois que o equivalente do kit provar que faz o mesmo e o usuário confirmar.

Siga estas etapas e, dentro da etapa 4, os passos do SKILL.md.

## 1. Inventário

Rode `bash "<raiz-do-plugin>/scripts/inventory.sh"`. Ele lista hooks de todos os settings (projeto, local e usuário), skills, commands, agents, rules, CLAUDE.md e servidores MCP.

Para cada peça, leia o conteúdo (script do hook, corpo da skill/agent) e registre:
- **o que faz ou verifica**, em uma frase;
- **quando dispara** (evento + matcher, invocação manual/automática, `paths:` da rule).

Hooks e settings de `~/.claude` são da camada de usuário: entram no inventário para detectar sobreposição, mas o init nunca os altera.

A seção "Riscos e sobreposições" do inventário já traz detecções prontas. Cada linha vira uma entrada na tabela do relatório, com a recomendação e o motivo:

| Marca | O que significa | Recomendação padrão |
| --- | --- | --- |
| `[sobreposição] skill` | Skill do projeto com o mesmo propósito de uma skill do kit. Se a do projeto tem `disable-model-invocation: true` e a do kit não, o Claude escolhe sozinho a do kit para pedidos como "corrige esse bug". | A skill do projeto é a dona: propor `Skill(kit:<nome>)` em `permissions.deny` do `.claude/settings.json` do projeto, explicando o motivo. |
| `[sobreposição] agent` | Agent do projeto com o mesmo papel de um agent do kit. | O agent do projeto é o dono: propor `Agent(kit:<nome>)` em `permissions.deny`. |
| `[aviso possivelmente mudo]` | Hook PreToolUse, PostToolUse ou Stop que imprime texto no stdout sem JSON `additionalContext`; com exit 0 o texto não chega ao Claude. | Migrar para `coupled_changes` com `level: "warn"` ou trocar a saída do script para JSON `additionalContext`. |
| `[falha aberta]` | Hook PreToolUse que faz `jq ... \|\| exit 0`: sem jq, a guarda libera tudo. | Substituir pelo `guard-files` com `protected_paths` (mensagem por item) ou trocar para exit 2. |
| `[efeito colateral]` | Skill de deploy, release, backup, push, migração ou publicação sem `disable-model-invocation: true`. | Listar; sugerir o campo, sem alterar. |
| `[settings.local.json versionado]`, `[sintaxe antiga]`, `[sem deny de segredos]` | Configuração pessoal no git, regra `Tool(x:*)` e ausência de `Read(...)` em deny para `.env`, chaves e `secrets/`. | Listar, sem alterar. |

Listas de bloqueio do projeto (hook que nega edição de caminhos com uma mensagem) viram itens de `protected_paths` em forma de objeto, com a mesma mensagem que o hook original mostrava: `{ "glob": "<caminho>/**", "message": "<texto do hook>" }`. Use `"write": "deny"` quando o hook também impede criar arquivos ali.

## 2. Classificação

Cada peça recebe um destino:

| Destino | Quando | Exemplo |
| --- | --- | --- |
| Manter no projeto | Regra de domínio que não dá para expressar de forma genérica | Checagem que exige ler o conteúdo do manual |
| Substituir pelo kit | O kit faz o mesmo ou mais | Hook próprio que bloqueia `rm -rf` → `guard-bash` |
| Virar declaração no `kit.json` | Cabe em `coupled_changes` ou `key_parity` | Tela mudou sem manual; i18n faltando em uma língua |
| Promover ao kit | Genérico e útil em outros projetos, mas o kit ainda não tem | Vira nova feature do plugin, implementada e testada no repo do kit, não aqui |
| Somar | Ambos agregam algo diferente | Skill de review do projeto passa a chamar `kit:code-reviewer` + seus itens específicos |

Equivalentes do kit para comparar:
- Hooks: `guard-bash` (comandos destrutivos), `guard-files` (segredos, `protected_paths` com mensagem por item), `format` (formatter por glob), `advise` (avisos `coupled_changes` com `level: "warn"` na edição), `verify-gate` (build/teste, `key_parity`, `coupled_changes` no Stop, em todos os repositórios da sessão), `session-context` e `pre-compact` (branch, alterados, planos ativos, snapshot na compactação). Comportamento exato no README do kit.
- Skills: `spec`, `plan`, `execute`, `epic`, `fix`, `hunt`.
- Agents: `investigator`, `code-reviewer`, `security-reviewer`, `test-writer`.

**Sobreposições a resolver:** dois hooks bloqueando a mesma coisa (mensagens duplicadas, tempo extra) e duas skills ou agents de review com escopos parecidos (Claude escolhe um de forma imprevisível). Uma peça vira dona; a outra sai (após prova e confirmação) ou passa a chamá-la.

Mostre a tabela de classificação ao usuário e peça confirmação dos destinos com `AskUserQuestion` antes de seguir.

## 3. Prova de equivalência

Obrigatória para toda peça classificada como "Substituir pelo kit" ou "Virar declaração no `kit.json`", antes de qualquer remoção. A prova roda o mesmo cenário nos dois lados e mostra o mesmo bloqueio ou aviso.

- **Hook de PreToolUse** (ex.: bloqueio de `rm -rf`): monte o JSON de entrada e passe pelos dois scripts.

  ```bash
  IN='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"},"cwd":"'"$PWD"'"}'
  printf '%s' "$IN" | bash .claude/hooks/<hook-do-projeto>.sh; echo "exit=$?"
  printf '%s' "$IN" | bash "<raiz-do-plugin>/scripts/guard-bash.sh"; echo "exit=$?"
  ```

  Equivalente = os dois bloqueiam (exit 2, ou JSON com `permissionDecision: "deny"`). Repita para cada caso que o hook original cobre, inclusive um caso que deve passar.
- **Hook ou agent virando `coupled_changes`/`key_parity`**: prove num worktree descartável, sem tocar na árvore de trabalho.

  ```bash
  git worktree add --detach ../<repo>-kit-proof HEAD
  # copiar o kit.json proposto para ../<repo>-kit-proof/.claude/kit.json e fazer a mudança que dispara a regra
  printf '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"%s"}' "$(cd ../<repo>-kit-proof && pwd)" | bash "<raiz-do-plugin>/scripts/verify-gate.sh"; echo "exit=$?"
  git worktree remove --force ../<repo>-kit-proof
  ```

  Equivalente = exit 2 com a mensagem da regra no cenário que o original pegava, e exit 0 no cenário corrigido.
- **Skill ou agent substituído**: liste os itens que o original verifica e aponte onde cada um está coberto no equivalente do kit. Item sem cobertura muda o destino para "Somar" ou "Manter".

Prova que falha muda o destino da peça; nunca remova com prova falhando.

## 4. Adições

Siga os passos do SKILL.md (kit.json, settings, CLAUDE.md) com as regras de escrita: merge chave a chave via `merge-json.sh`, nada sobrescrito, diff mostrado e gravação só após confirmação. Peças classificadas como "Virar declaração" alimentam `coupled_changes` e `key_parity` do `kit.json`. Peças "Somar" recebem só linhas novas (ex.: um passo que chama `kit:code-reviewer`), mostradas como diff.

## 5. Remoção

Só para peças "Substituir pelo kit" ou "Virar declaração" com prova aprovada:
- pergunte com `AskUserQuestion`, uma peça por vez, mostrando a prova;
- removida a peça, faça **um commit separado por peça**, contendo só essa remoção (arquivo do hook/skill e a entrada correspondente no settings), fácil de reverter com `git revert`;
- sem confirmação explícita nesta conversa, a peça fica, com status "aguardando confirmação" no relatório.

## 6. Relatório

Grave `docs/claude-adoption.md` (se já existir, só acrescente):

```markdown
# Adoção do kit

Data: <AAAA-MM-DD> · Versão do kit: <version do plugin.json>

## Peças
| Peça | Tipo | Origem | O que faz | Quando dispara | Destino | Prova | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| no-rm-rf.sh | hook | .claude/settings.json | bloqueia rm -rf | PreToolUse Bash | Substituir pelo kit (guard-bash) | `rm -rf /tmp/x`: ambos exit 2/deny | aguardando confirmação |

## Sobreposições resolvidas
- <peça A> × <peça B>: dona = <...>; a outra <sai | passa a chamar>.

## Riscos detectados
| Marca | Peça | Motivo | Recomendação | Status |
| --- | --- | --- | --- | --- |
| sobreposição | skill fix | a do projeto tem disable-model-invocation: true e a do kit não; o Claude escolheria kit:fix sozinho | `Skill(kit:fix)` em permissions.deny | proposto |

## Promover ao kit
- <peça>: <o que faria no kit e por que é genérica>

## Registro de kit-skip
```

A seção "Registro de kit-skip" fica vazia; o `verify-gate` acrescenta ali cada justificativa usada.
