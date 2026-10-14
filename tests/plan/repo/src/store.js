import { readFileSync, writeFileSync } from "node:fs";

const FILE = new URL("../data/users.json", import.meta.url);

export function loadUsers() {
  return JSON.parse(readFileSync(FILE, "utf8"));
}

export function saveUsers(users) {
  writeFileSync(FILE, JSON.stringify(users, null, 2) + "\n");
}
