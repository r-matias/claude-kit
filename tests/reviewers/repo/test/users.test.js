import { test } from "node:test";
import assert from "node:assert/strict";
import { buscarUsuario } from "../src/users.js";

test("buscarUsuario encontra pelo id", () => {
  assert.equal(buscarUsuario(1).nome, "Ana");
});

test("buscarUsuario devolve null para id inexistente", () => {
  assert.equal(buscarUsuario(99), null);
});
