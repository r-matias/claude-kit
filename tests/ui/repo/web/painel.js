export function resumo(pedidos) {
  const hoje = pedidos.filter((p) => p.hoje).length;
  const atrasadas = pedidos.filter((p) => p.atrasada).length;
  return { hoje, atrasadas };
}

if (typeof document !== "undefined") {
  const r = resumo([{ hoje: true }, { hoje: true, atrasada: true }, { hoje: false }]);
  document.getElementById("pedidos").textContent = `${r.hoje} pedidos`;
  document.getElementById("atrasadas").textContent = r.atrasadas ? `${r.atrasadas} entrega` : "Nenhuma";
}
