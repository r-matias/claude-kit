import { copyFileSync } from "node:fs";
import { lerUsuarios, gravarUsuarios } from "../src/store.js";

const arquivo = process.env.USERS_FILE ?? "data/users.json";

if (process.argv.includes("--rollback")) {
  copyFileSync(`${arquivo}.bak`, arquivo);
} else {
  copyFileSync(arquivo, `${arquivo}.bak`);
  const lista = lerUsuarios().map((u) => ("apelido" in u ? u : { ...u, apelido: "" }));
  try {
    gravarUsuarios(lista);
  } catch (erro) {
    copyFileSync(`${arquivo}.bak`, arquivo);
    throw erro;
  }
}
