---
paths:
  - "src/api/**"
---
- Funções da API recebem `db` por parâmetro; nunca importe um cliente global.
- Retorne `null` para "não encontrado"; não lance exceção.
