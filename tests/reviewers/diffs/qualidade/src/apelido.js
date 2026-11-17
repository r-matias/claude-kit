// eslint-disable-next-line complexity
export function validarApelido(apelido) {
  if (typeof apelido !== "string" || apelido.length < 1 || apelido.length > 30) {
    throw criarErro("apelido deve ter de 1 a 30 caracteres", "APELIDO_INVALIDO");
  }
}

function criarErro(mensagem, code) {
  const erro = new Error(mensagem);
  erro.code = code;
  return erro;
}
