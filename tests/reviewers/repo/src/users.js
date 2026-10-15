import { lerUsuarios } from "./store.js";

export function buscarUsuario(id) {
  return lerUsuarios().find((u) => u.id === id) ?? null;
}
