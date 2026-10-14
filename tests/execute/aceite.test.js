import { test } from "node:test";
import assert from "node:assert/strict";
import { soma, dobro, media } from "../src/numeros.js";
import { maiusculas } from "../src/texto.js";

test("aceite", () => {
  assert.equal(soma(2, 3), 5);
  assert.equal(soma(-1, 1), 0);
  assert.equal(maiusculas("abc"), "ABC");
  assert.equal(maiusculas(""), "");
  assert.equal(dobro(4), 8);
  assert.equal(media([1, 2, 3]), 2);
  assert.equal(media([]), 0);
});
