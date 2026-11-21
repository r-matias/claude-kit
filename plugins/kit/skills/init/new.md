# Modo do zero

A pasta não tem código nem manifesto. Aqui o init define o mínimo com o usuário, cria o esqueleto do projeto e só então segue os passos do SKILL.md, já com comandos reais para o `kit.json`. O usuário não roda nada entre uma coisa e outra.

Siga estas etapas em ordem; a etapa 3 são os passos do SKILL.md.

## 1. Entrevista até o mínimo

A ideia do app é o argumento do `/kit:init`. Sem argumento, peça a ideia em uma frase antes de qualquer pergunta.

Pergunte com `AskUserQuestion`, em rodadas de até 4 perguntas, com opções concretas e a recomendada primeiro. Pergunte só o que muda o esqueleto; o resto fica para a primeira `/kit:spec`. Pare assim que isto estiver definido:

- **Tipo e lugar:** o que é (CLI, serviço ou API, site, bot, app desktop ou mobile, biblioteca) e onde roda (máquina do usuário, servidor próprio, nuvem, navegador).
- **Stack, como conjunto:** linguagem, framework (se o tipo pedir), runner de teste, linter e formatter, escolhidos juntos e não peça por peça. Pergunte primeiro o que o usuário já domina ou já usa em outros projetos. Depois ofereça 2 ou 3 conjuntos que servem ao app, o recomendado primeiro, cada um com o motivo em uma linha. Entre conjuntos equivalentes, vence o que o usuário domina. As ferramentas de teste, lint e format são as da tabela de [stacks.md](stacks.md) para a linguagem; só viram pergunta se o usuário disser que tem preferência.
- **Dados:** se o app guarda estado, onde (arquivo, SQLite, Postgres, serviço externo). App sem estado: não pergunte.
- **Integrações obrigatórias** que definem biblioteca ou credencial desde o início (API externa, fila, serviço de mensagem). Segredo não é pedido aqui: vai para `.env`, fora do git.

Não pergunte sobre CI, deploy, escala, autenticação, telas ou regras de negócio: nada disso muda o esqueleto. Resposta "não sei" ou "tanto faz": use a recomendação e siga.

Feche com um resumo de até 6 linhas (app, tipo e lugar, stack, dados, integrações, nome do pacote) e uma pergunta: "Criar o esqueleto com isso?", com Criar (recomendado) / Ajustar / Cancelar. "Ajustar": aplique o ajuste e repita só o resumo e a pergunta. "Cancelar": pare sem criar nada.

Execução não interativa: o argumento precisa trazer a ideia e o stack. Sem um dos dois, não crie nada e diga em uma linha o que faltou.

## 2. Esqueleto

Só depois do "Criar". É a única gravação antes da confirmação única do SKILL.md, e fica restrita ao que está nesta etapa.

- Pasta sem repositório git: `git init`.
- Use o gerador oficial do stack quando existir (`npm create`, `dotnet new`, `cargo init`, `go mod init`, `uv init` e equivalentes), sem modo interativo e na pasta atual. Sem gerador, escreva os arquivos mínimos.
- Dependência entra pelo gerenciador de pacotes, que resolve a versão atual. Nunca escreva número de versão de memória no manifesto.
- O esqueleto tem só:
  - manifesto e lockfile;
  - um ponto de entrada que roda;
  - um teste de verdade, que passa e que falharia sem o ponto de entrada (nada de asserção vazia);
  - linter e formatter com a configuração padrão da ferramenta;
  - `.gitignore` do stack, com `.env`; `.env.example` com os nomes das variáveis, se há integração com credencial;
  - `README.md` de até 10 linhas: o que é o app e como rodar, testar e conferir o lint.
- Nenhuma feature do app: a primeira entra pela `/kit:spec`.
- Rode uma vez o build (se o stack tem), o teste e o lint. Os três precisam passar antes da etapa 3; se o gerador trouxe algo que falha, corrija o esqueleto.
- Não faça commit: o kit nunca commita.

## 3. Passos do SKILL.md

Siga os Passos 1 a 12 do SKILL.md como repositório novo, com estas diferenças. Se a pasta já tinha configuração do Claude Code além de `.claude/settings.json` e `.claude/settings.local.json` (`CLAUDE.md`, `.mcp.json`, skills, agents, commands, rules ou hooks), siga o [adopt.md](adopt.md), que envolve os mesmos passos; um `.claude/settings.json` que só habilita plugins recebe o merge aditivo do passo 5, como em qualquer repositório.

- **Passo 1:** os manifestos são os que você acabou de criar. As listas do "Estado atual" foram lidas antes do esqueleto e estão vazias.
- **Passo 7:** o `CLAUDE.md` leva o que foi decidido na entrevista e que o código não mostra: o que o app é, onde roda, as integrações e o motivo do stack. Mesmo limite de linhas.
- **Passo 8c:** em app com tela, o `ui` entra com o `dev` e a `url` do esqueleto que você criou, e a `.claude/rules/kit-ui.md` registra a biblioteca de componentes escolhida na entrevista. Ainda não há tela de referência: a linha fica de fora. A direção visual nasce depois, pela `/kit:design`, e a amostra que ela grava faz o papel da tela de referência até existir uma.
- **Passo 11:** não mapeie.
- **Passo 12:** o relatório começa pelo esqueleto (stack e os comandos de build, teste e lint, com `ok`) e avisa em uma linha que nada foi commitado. A última linha continua a mesma.
