# Changelog

O que mudou em cada versão, do ponto de vista de quem usa o kit. Depois de atualizar, rode `/kit:init` de novo em cada projeto (modo reparo) para ele propor o que a versão trouxe para o `kit.json`.

Versões anteriores à 0.9.3 estão nas tags do repositório.

## 0.9.5

### Entrou

- **Projeto do zero pelo `/kit:init`.** Numa pasta vazia, `/kit:init <o que o app faz>` pergunta só o que muda o esqueleto (tipo de app e onde roda, stack como conjunto, dados, integrações obrigatórias), cria o projeto mínimo com teste e lint passando e segue com a configuração normal. Não cria nenhuma feature e não commita.

### Corrigido

- **Guarda de escrita lento no Windows.** O `guard-files` criava alguns processos por entrada de `protected_paths`, e no Git Bash cada processo custa dezenas de milissegundos. Com 16 entradas levava cerca de 6 s por edição; com a máquina ocupada passava do limite de 10 s do hook e toda edição era bloqueada. Agora a entrada e cada `kit.json` são lidos uma vez e o casamento por regra não cria processo: cerca de 0,6 s, quase sem crescer com a lista.
- Os outros hooks de cada chamada (`guard-bash`, `format`, `advise`) também criam menos processos.

## 0.9.4

### Entrou

- **Aviso de lint fora do gate.** No início da sessão, projeto com comando `lint` que não está em `verify_on_stop` recebe um aviso: nenhum passo do kit roda o lint nesse caso.

### Mudou

- O aviso de `diff_deny` com `level: "warn"` não repete quando a linha só muda de número.
- `/kit:fix`, `/kit:hunt` e o `investigator` sabem que o comando do `kit.json` pode vir na forma objeto.

### Corrigido

- macOS (bash 3.2): arquivo com apóstrofo no nome quebrava o `{files}` do gate e do `format`.
- `/kit:map` com a pasta atrás de um symlink (`/var` no macOS) não reconhecia o repositório principal.
- A suíte de testes passa no macOS.

## 0.9.3

### Entrou

- **`diff_deny`.** Padrões proibidos nas linhas adicionadas no turno: supressão de lint e de tipo, teste pulado ou focado. Código antigo não conta. `level: "block"` barra no fim do turno; `"warn"` vira aviso na edição. O `/kit:init` propõe os padrões de partida do stack.
- **Comando na forma objeto.** `{ "run": "<comando> {files}", "files": [<globs>] }`: o gate só roda o comando quando algum arquivo alterado casa `files`, e só esses vão para `{files}`. Serve para o lint de uma linguagem num repositório com mais de uma.
- **Lint no gate.** O `/kit:init` propõe `lint` no `verify_on_stop` quando o projeto tem linter, de preferência por arquivo, e o `format` com correção de lint onde a ferramenta é rápida.
- **Regra de código sem teste.** `coupled_changes` com `level: "warn"`: ao editar código de produção sem tocar em teste, o Claude recebe um lembrete.
- **Revisor de código: M5 a M8.** Código novo que duplica o que já existe, supressão nova sem justificativa, teste que não falharia sem a implementação e dependência não prevista no plano.

### Mudou

- O gate roda todos os comandos de `verify_on_stop`, mesmo depois de uma falha, e entrega as falhas numa mensagem só. Antes parava na primeira.
- A mensagem do gate cabe em 9.000 caracteres: falhas curtas saem inteiras e as longas são cortadas no meio.
- O revisor de código não roda mais build, lint nem teste; isso fica com o gate e com o checkpoint do `/kit:execute`. Projeto que tinha `lint` só em `commands` precisa do `/kit:init` em modo reparo para o lint entrar no gate.
- `setup.sh guards` confere a forma de `commands` e de `diff_deny`.

### Corrigido

- Comando do gate que lia a entrada padrão impedia os comandos seguintes de rodar.
