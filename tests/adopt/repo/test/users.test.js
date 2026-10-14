import { test } from "node:test";
import assert from "node:assert/strict";
import { getUser } from "../src/api/users.js";

test("getUser devolve null quando nao existe", () => {
  assert.equal(getUser({ users: [] }, 1), null);
});
