import { createHash } from "node:crypto";
import { loadUsers } from "./store.js";

export function hashPassword(password) {
  return createHash("sha256").update(password).digest("hex");
}

export function login(email, password) {
  const user = loadUsers().find((u) => u.email === email);
  if (!user || user.passwordHash !== hashPassword(password)) return { ok: false, error: "credenciais inválidas" };
  return { ok: true, userId: user.id };
}
