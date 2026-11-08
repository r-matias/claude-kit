import { lerUsuarios, gravarUsuarios } from "./store.js";
import { validarApelido } from "./apelido.js";

export function buscarUsuario(id) {
  return lerUsuarios().find((u) => u.id === id) ?? null;
}

export function definirApelido(id, apelido) {
  validarApelido(apelido);
  const lista = lerUsuarios();
  const usuario = lista.find((u) => u.id === id);
  if (!usuario) {
    const erro = new Error(`usuário ${id} não encontrado`);
    erro.code = "USUARIO_NAO_ENCONTRADO";
    throw erro;
  }
  usuario.apelido = apelido;
  gravarUsuarios(lista);
  return usuario;
}
