# Arquivos gerados pelo /kit:map

## Cabeçalho
Todo arquivo gerado tem a linha `<!-- kit:map v1 · <AAAA-MM-DD> · <commit> -->`, com a data de hoje e o hash completo de `HEAD` do repositório onde o arquivo fica (vem de `repos[].commit` do script). No `docs/codemap.md` é a primeira linha; numa rule, a primeira linha depois do frontmatter. O `session-context` lê esse commit para avisar quando o mapa fica para trás, e o `--update` para saber o que mudou.

Arquivo com esse cabeçalho é do kit e pode ser reescrito ou apagado pelo `/kit:map`. Arquivo sem ele nunca é tocado: o kit não altera configuração do Claude Code que não criou (`CLAUDE.md`, settings, skills, agents, commands, rules e hooks).

## Blocos manuais
Texto entre `<!-- manual -->` e `<!-- /manual -->` é do usuário. Ao reescrever um arquivo gerado, copie cada bloco manual, intacto, para a mesma seção do arquivo novo (ou para o fim, se a seção sumiu).

## Conflito de nome
Se `.claude/rules/map-<unidade>.md` já existe sem o cabeçalho `kit:map`, grave em `.claude/rules/map-<unidade>.kit.md` e avise no resumo. O mesmo vale para `.claude/rules/kit-codemap.md` (grave `kit-codemap.kit.md`) e para um `docs/codemap.md` sem cabeçalho (grave `docs/codemap.kit.md`).

## Rule por unidade: `.claude/rules/map-<unidade>.md`
No repositório da unidade, no máximo 40 linhas. `paths` são os da unidade, relativos ao repositório, entre aspas.

```markdown
---
paths:
  - "src/api/**"
  - "src/shared/http.ts"
---
<!-- kit:map v1 · 2026-10-14 · <commit> -->
# <unidade>

<Responsabilidade em 1 a 3 frases.> Visão geral: [codemap](<caminho relativo até docs/codemap.md>).

## Entrada e interfaces
- `arquivo:linha` — ...

## Dependências
- ... — `arquivo:linha`

## Convenções
- ... — `arquivo:linha`

## Armadilhas
- ... — `arquivo:linha`

## Testes
...

Confiança: alta | média | baixa — <o que não foi verificado>
```

Para caber em 40 linhas, corte primeiro convenções e dependências de entrada, nunca armadilhas. Seção vazia sai.

## `docs/codemap.md`
No repositório principal, no máximo 150 linhas. Repositório principal: `map.primary` do `kit.json` da pasta da sessão; sem ele, o repositório da própria pasta, ou o primeiro de `repos`.

```markdown
<!-- kit:map v1 · 2026-10-14 · <commit> -->
# Mapa do código

<Visão geral em até 5 linhas: o que o sistema faz e como as partes se encaixam.>

## Unidades
| Unidade | Repo | Paths | Responsabilidade | Rule |
| --- | --- | --- | --- | --- |
| api | . | `src/api/**` | ... | [map-api](../.claude/rules/map-api.md) |

## Integrações
- produtor → consumidor: contrato — `a:linha` ↔ `b:linha`

## Fluxos
### <fluxo>
1. ... — `arquivo:linha`

## Divergências
- ... — `a:linha` ↔ `b:linha`

## Verificação
<data> · <aprovadas>/<total> afirmações aprovadas · unidades com confiança baixa: ...
```

Em vários repositórios, a coluna Repo diz onde está cada unidade e o link da rule é relativo (`../../web/.claude/rules/map-web-api.md`); a rule de cada repositório aponta para o codemap do principal pelo caminho relativo entre as pastas, que vale quando os repositórios ficam lado a lado como na pasta da sessão. Para ficar em 150 linhas, resuma as integrações e mantenha só os fluxos principais; a tabela de unidades nunca é cortada.

## Ponteiro: `.claude/rules/kit-codemap.md`
O kit não edita o `CLAUDE.md`. Em cada repositório mapeado, crie (ou regrave, se tiver o cabeçalho `kit:map`) `.claude/rules/kit-codemap.md` **sem** frontmatter `paths:`, para carregar em toda sessão, com o cabeçalho e 2 a 3 linhas:

```markdown
<!-- kit:map v1 · 2026-10-14 · <commit> -->
Mapa da arquitetura em [docs/codemap.md](../../docs/codemap.md), gerado por /kit:map; cada área tem sua rule `map-<unidade>.md`, carregada ao mexer nela.
Quando o mapa divergir do código, o código vence. Mapa atrasado: /kit:map --update.
```

Em vários repositórios, o link aponta para o codemap do repositório principal pelo caminho relativo entre as pastas.
