---
name: drift
description: Confere se as SPECs já implementadas ainda batem com o código e grava docs/specs/DRIFT.md com as divergências, cada uma dizendo se o certo é corrigir a spec ou o código. Aceita uma SPEC.md ou uma pasta.
argument-hint: "[caminho de SPEC.md ou pasta]"
disable-model-invocation: true
allowed-tools: Read(${CLAUDE_PLUGIN_ROOT}/**) Bash(git rev-parse *) Edit(docs/specs/DRIFT.md) Write(docs/specs/DRIFT.md)
---

## Regras que valem a tarefa inteira
- Nunca entregue ao usuário comando com placeholder (`<...>`, `SEU_X`, `xxx`): ou o valor está configurado e o comando funciona como está, ou pergunte o valor antes (`AskUserQuestion`) e grave no lugar certo (o que não é segredo na config versionada do projeto, carregada pelo script; segredo em `.env`/`.env.test` carregado pelo script, nunca lido por você).
- Não edite código, SPEC.md nem PLAN.md. O único arquivo gravado é `docs/specs/DRIFT.md`.
- Não confira você mesmo: cada SPEC vai para um `kit:drift-checker`.

## Passos
1. Alvo: $ARGUMENTS. Sem argumento, use `docs/specs/`. Com um arquivo, só ele; com uma pasta, todas as `SPEC.md` dentro dela (inclusive as fatias de épicos).
2. **Só SPEC implementada.** Confira com Read o `PLAN.md` ao lado de cada SPEC:
   - tem PLAN.md e nenhuma caixa `- [ ]`: entra;
   - sem PLAN.md ou com caixa pendente: fica de fora e vai para a lista de puladas, com o motivo (`sem plano` ou `plano em andamento`).
   Com um arquivo indicado no argumento, ele entra mesmo sem plano concluído.
3. Chame o `kit:drift-checker`, um por SPEC, até 8 ao mesmo tempo numa única mensagem; com mais de 8, em ondas de 8. Cada chamada recebe o caminho da SPEC.md e do PLAN.md.
4. Grave `docs/specs/DRIFT.md` (substitui o anterior; o histórico fica no git):

```markdown
# Drift entre specs e código
Gerado em <data de hoje> no commit <git rev-parse --short HEAD>.

## <caminho da SPEC.md>
- [D2] <item> — <o que a SPEC diz> — <o que o código faz> (`arquivo:linha`) — corrigir: código

## <caminho da SPEC.md>
Sem divergência.

## Puladas
- `<caminho>` — plano em andamento
```

   Copie as linhas `DIVERGÊNCIA` de cada checker sem mudar o conteúdo. Resposta com `ERRO:` entra como `Não conferida: <motivo>`.
5. A resposta final é só o resumo, no máximo 5 linhas não vazias: caminho do DRIFT.md; quantas SPECs conferidas, divergentes e puladas; as divergências mais graves (até 3, preferindo D1 e D3); próximo passo: `/kit:fix` com a divergência quando o lado é `código`, e editar a SPEC quando o lado é `spec`. Não corrija nada nesta skill.
