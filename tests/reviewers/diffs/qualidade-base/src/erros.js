export function erroComCodigo(mensagem, code) {
  const erro = new Error(mensagem);
  erro.code = code;
  return erro;
}
