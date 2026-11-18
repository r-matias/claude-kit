import test from "node:test";
import assert from "node:assert/strict";
import { resumo } from "../web/painel.js";

test("resumo conta pedidos de hoje e entregas atrasadas", () => {
  assert.deepEqual(resumo([{ hoje: true }, { hoje: true, atrasada: true }, { hoje: false }]), { hoje: 2, atrasadas: 1 });
});

test("resumo de lista vazia é zero", () => {
  assert.deepEqual(resumo([]), { hoje: 0, atrasadas: 0 });
});
