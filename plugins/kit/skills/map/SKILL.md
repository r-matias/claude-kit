---
name: map
description: Mapeia a arquitetura do codebase com vários subagents em paralelo e grava .claude/rules/map-<unidade>.md por área, .claude/rules/kit-codemap.md e docs/codemap.md, cada afirmação com evidência arquivo:linha conferida por um verificador. Aceita uma área ou --update.
argument-hint: "[<caminho> | --update]"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh" *) Bash(git rev-parse *) Bash(git diff *) Bash(git log *) Read(${CLAUDE_PLUGIN_ROOT}/**)
---

## Estado atual
!`git rev-parse --show-toplevel 2>/dev/null || echo "(não é repo git)"`
!`git log -1 --format=%H 2>/dev/null || echo "(sem commits)"`

## Regras que valem a tarefa inteira
- Argumento: $ARGUMENTS. Vazio: mapeia tudo. `--update`: só o que mudou desde o último mapa. Outro valor: caminho de uma área, relativo à pasta da sessão.
- Os mapeadores e o verificador são `kit:mapper` e `kit:map-verifier`: somente leitura, sem Bash, sem rede. Você também não roda build, teste nem comando do projeto nesta skill.
- Nunca leia nem cite `.env*`, `secrets/`, `keys/`, chaves ou `protected_paths`. Env var entra pelo nome.
- Toda afirmação gravada tem evidência `arquivo:linha`. O que o verificador reprova sai.
- Escreva direto, sem pedir aprovação: só arquivos do kit (com o cabeçalho `kit:map`), tudo no git e reversível. Nunca commite.
- Nunca altere `CLAUDE.md`, settings, skills, agents, commands, hooks nem rules que o kit não criou.
- Formato dos arquivos gerados, cabeçalho, blocos manuais e conflitos: [output.md](output.md). Leia antes da fase 4.
- Script: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/map-partition.sh"`, rodado na pasta da sessão.

## Fase 0 — Particionar
1. Monte os argumentos do script:
   - Área: `--path <caminho>`.
   - `--update`: leia o cabeçalho `<!-- kit:map v1 · <data> · <commit> -->` do `docs/codemap.md` e das `.claude/rules/map-*.md` de cada repositório. Passe `--since <commit>` (um repositório) ou `--since <repo>=<commit>` por repositório. Sem codemap ou sem cabeçalho, avise e faça o mapa completo.
2. Rode o script e leia o JSON (`units`, `totals`, `limits`, `repos`). Sem unidades: diga que não há código para mapear e pare.
3. Em `--update`, as unidades afetadas são as com `changed: true`, as novas (sem rule gerada) e as que mudaram de `paths`. Nenhuma afetada: diga que o mapa está em dia e pare.
4. Imprima o plano e siga sem perguntar: tabela `repo | unidade | arquivos | linhas` (só as que serão mapeadas), total de agents (`totals.agents`, ou em `--update` o número de afetadas mais verificação e, se preciso, a fase 2) e ondas de até `limits.parallel`.
5. Só pergunte se o total passar de `limits.max_agents`. Use `AskUserQuestion` com o custo estimado (ordem de grandeza: ~50 mil tokens por agent, mais o tempo de `ceil(unidades / parallel)` ondas) e as opções: seguir com tudo, mapear uma área (`/kit:map <caminho>`), aumentar `map.unit_max_files`/`map.unit_max_loc` no `kit.json` (menos agents, cada um maior) ou cancelar.

## Fase 1 — Mapeadores
6. Para cada unidade, um `kit:mapper` no modo unidade. O prompt leva: repositório e caminho dele, nome da unidade, `paths`, `manifests`, `file_count`, `loc`, os `protected_paths` do `kit.json` e, se existir, o conteúdo atual da rule da unidade e o `docs/codemap.md` como ponto de partida. Dispare em ondas de até `limits.parallel` subagents, todos da onda na mesma mensagem; espere a onda voltar antes da próxima.
7. Guarde cada resumo. Resumo fora do schema ou sem evidência: peça uma vez ao mesmo tipo de agent que refaça; se falhar de novo, siga com o que veio e marque confiança baixa.

## Fase 2 — Transversais
8. Na mesma mensagem, dois `kit:mapper`: um no modo integração e outro no modo fluxos, cada um com todos os resumos da fase 1 (em `--update`, os novos mais as rules atuais das unidades não afetadas).
9. Em `--update`, pule a fase 2 se nenhuma unidade afetada mudou Interfaces públicas ou Dependências em relação à rule anterior; mantenha essas seções do codemap.

## Fase 3 — Verificação
10. Monte a lista numerada de afirmações: ~5 por unidade (prefira interfaces, dependências e armadilhas) e todas as da fase 2. Entregue a um `kit:map-verifier` (um a cada `limits.parallel` unidades; vários na mesma mensagem). Passe também os `protected_paths`.
11. Remova toda afirmação reprovada e corrija as linhas que o verificador ajustou.
12. Unidade com mais de 30% de reprovação na amostra: remapeie uma vez (novo `kit:mapper` com as afirmações reprovadas e o motivo de cada uma) e verifique de novo uma amostra. Se continuar acima de 30%, grave só o que foi aprovado e marque a unidade com confiança baixa.

## Fase 4 — Escrita
13. Grave os arquivos conforme [output.md](output.md): `.claude/rules/map-<unidade>.md` por unidade (no repositório da unidade), `docs/codemap.md` no repositório principal e `.claude/rules/kit-codemap.md` (sem `paths:`) em cada repositório mapeado. Em `--update` ou com área, reescreva só as rules afetadas e atualize no codemap só as linhas e seções delas.
14. Em mapa completo ou `--update`, apague as `.claude/rules/map-*.md` com cabeçalho `kit:map` cujas unidades deixaram de existir. Nunca apague arquivo sem esse cabeçalho.
15. Resumo final, curto:
    - arquivos criados, alterados e removidos;
    - verificação: aprovadas/removidas por unidade e unidades remapeadas;
    - divergências de contrato encontradas;
    - unidades com confiança baixa;
    - próximo passo: revisar e commitar `.claude/rules/map-*.md`, `.claude/rules/kit-codemap.md` e `docs/codemap.md`.
