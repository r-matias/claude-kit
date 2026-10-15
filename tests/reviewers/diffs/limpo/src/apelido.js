export function validarApelido(apelido) {
  if (typeof apelido !== "string" || apelido.length < 1 || apelido.length > 30) {
    const erro = new Error("apelido deve ter de 1 a 30 caracteres");
    erro.code = "APELIDO_INVALIDO";
    throw erro;
  }
}
