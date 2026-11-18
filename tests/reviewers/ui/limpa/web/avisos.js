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

function item(aviso) {
  const li = document.createElement("li");
  li.className = "cartao";
  const titulo = document.createElement("h2");
  titulo.textContent = aviso.titulo;
  const data = document.createElement("time");
  data.dateTime = aviso.data;
  data.textContent = formatarData(aviso.data);
  li.append(titulo, data);
  if (aviso.texto) {
    const texto = document.createElement("p");
    texto.textContent = aviso.texto;
    li.append(texto);
  }
  return li;
}

async function carregar() {
  const estado = document.getElementById("estado");
  const lista = document.getElementById("lista");
  const tentar = document.getElementById("tentar");
  estado.hidden = false;
  estado.removeAttribute("data-tipo");
  estado.textContent = "Carregando avisos…";
  lista.hidden = true;
  tentar.hidden = true;
  try {
    const avisos = ordenarAvisos(await buscar(new URLSearchParams(location.search).get("dados")));
    if (!avisos.length) {
      estado.textContent = "Nenhum aviso por enquanto.";
      return;
    }
    lista.replaceChildren(...avisos.map(item));
    estado.hidden = true;
    lista.hidden = false;
  } catch {
    estado.dataset.tipo = "erro";
    estado.textContent = "Não foi possível carregar os avisos.";
    tentar.hidden = false;
  }
}

if (typeof document !== "undefined") {
  document.getElementById("tentar").addEventListener("click", carregar);
  carregar();
}
