import test from "node:test";
import assert from "node:assert/strict";
import { formatarData, ordenarAvisos } from "../web/avisos.js";

const avisos = [
  { titulo: "b", data: "2026-03-07", texto: "" },
  { titulo: "a", data: "2026-03-12", texto: "x" },
  { titulo: "c", data: "2026-02-28", texto: "" },
];

test("ordenarAvisos devolve do mais novo para o mais antigo", () => {
  assert.deepEqual(ordenarAvisos(avisos).map((a) => a.titulo), ["a", "b", "c"]);
});

test("ordenarAvisos não altera a lista recebida", () => {
  const copia = [...avisos];
  ordenarAvisos(avisos);
  assert.deepEqual(avisos, copia);
});

test("ordenarAvisos de lista vazia devolve lista vazia", () => {
  assert.deepEqual(ordenarAvisos([]), []);
});

test("formatarData troca AAAA-MM-DD por DD/MM/AAAA", () => {
  assert.equal(formatarData("2026-03-07"), "07/03/2026");
});
