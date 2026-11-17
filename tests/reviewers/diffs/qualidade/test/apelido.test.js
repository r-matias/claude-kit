import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { validarApelido } from "../src/apelido.js";

test("apelido de 1 caractere é aceito", () => {
  assert.doesNotThrow(() => validarApelido("A"));
});

test("apelido de 30 caracteres é aceito", () => {
  assert.doesNotThrow(() => validarApelido("a".repeat(30)));
});

test("apelido de 31 caracteres é recusado", () => {
  assert.throws(() => validarApelido("a".repeat(31)), { code: "APELIDO_INVALIDO" });
});

test("apelido vazio é recusado", () => {
  assert.throws(() => validarApelido(""), { code: "APELIDO_INVALIDO" });
});

test("validarApelido é chamado com o apelido", () => {
  const validar = mock.fn();
  validar("Aninha");
  assert.equal(validar.mock.callCount(), 1);
  assert.deepEqual(validar.mock.calls[0].arguments, ["Aninha"]);
});
