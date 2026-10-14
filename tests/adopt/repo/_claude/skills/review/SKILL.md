---
name: review
description: Revisa o diff atual antes do commit. Use quando terminar uma mudança ou antes de abrir PR.
---

1. Rode `git diff` e leia os arquivos alterados.
2. Confira se todo texto visível usa `t("...")` com chave de strings.
3. Confira se a API nunca devolve o objeto de usuário inteiro (sem campo `password`).
4. Rode `npm test`.
5. Liste problemas como: arquivo:linha — problema — sugestão.
