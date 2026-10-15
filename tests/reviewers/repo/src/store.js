import { readFileSync, writeFileSync } from "node:fs";

const arquivo = () => process.env.USERS_FILE ?? "data/users.json";

export function lerUsuarios() {
  return JSON.parse(readFileSync(arquivo(), "utf8"));
}

export function gravarUsuarios(lista) {
  writeFileSync(arquivo(), JSON.stringify(lista, null, 2) + "\n");
}
