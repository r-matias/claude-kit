export function ordenarAvisos(lista) {
  return [...lista].sort((a, b) => b.data.localeCompare(a.data));
}

export function formatarData(data) {
  const [ano, mes, dia] = data.split("-");
  return `${dia}/${mes}/${ano}`;
}

async function buscar(modo) {
  if (modo === "vazio") return [];
  if (modo === "erro") throw new Error("dados indisponíveis");
  const resposta = await fetch("/dados/avisos.json");
  if (!resposta.ok) throw new Error(`resposta ${resposta.status}`);
  return resposta.json();
}

function linha(aviso) {
  const tr = document.createElement("tr");
  const titulo = document.createElement("td");
  titulo.textContent = aviso.titulo;
  const data = document.createElement("td");
  data.className = "quando";
  data.textContent = formatarData(aviso.data);
  const texto = document.createElement("td");
  texto.textContent = aviso.texto;
  tr.append(titulo, data, texto);
  return tr;
}

async function carregar() {
  const estado = document.getElementById("estado");
  const erro = document.getElementById("erro");
  const lista = document.getElementById("lista");
  estado.hidden = false;
  erro.hidden = true;
  lista.hidden = true;
  try {
    const avisos = ordenarAvisos(await buscar(new URLSearchParams(location.search).get("dados")));
    estado.hidden = true;
    if (!avisos.length) return;
    lista.querySelector("tbody").replaceChildren(...avisos.map(linha));
    lista.hidden = false;
  } catch {
    estado.hidden = true;
    erro.hidden = false;
  }
}

if (typeof document !== "undefined") {
  document.getElementById("tentar").addEventListener("click", carregar);
  carregar();
}
