import { loadUsers } from "./store.js";

export function getUserById(id) {
  const user = loadUsers().find((u) => u.id === id);
  if (!user) return { status: 404, body: { error: "não encontrado" } };
  return { status: 200, body: { id: user.id, email: user.email, name: user.name } };
}
