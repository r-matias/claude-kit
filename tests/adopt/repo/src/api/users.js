export function getUser(db, id) {
  return db.users.find((u) => u.id === id) ?? null;
}
