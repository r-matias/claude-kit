import { test } from "node:test";
import assert from "node:assert/strict";
import { hashPassword } from "../src/auth.js";

test("hashPassword é determinístico", () => {
  assert.equal(hashPassword("x"), hashPassword("x"));
});
