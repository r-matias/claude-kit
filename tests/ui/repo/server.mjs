import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const porta = Number(process.env.PORTA || 41873);
const raiz = path.join(path.dirname(fileURLToPath(import.meta.url)), "web");
const tipos = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".json": "application/json; charset=utf-8" };

http.createServer((req, res) => {
  let nome = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (nome === "/") nome = "/index.html";
  if (!path.extname(nome)) nome += ".html";
  const arquivo = path.join(raiz, nome);
  if (!arquivo.startsWith(raiz) || !fs.existsSync(arquivo) || !fs.statSync(arquivo).isFile()) {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("não encontrado");
    return;
  }
  res.writeHead(200, { "content-type": tipos[path.extname(arquivo)] || "application/octet-stream", "cache-control": "no-store" });
  fs.createReadStream(arquivo).pipe(res);
}).listen(porta, "127.0.0.1", () => console.log(`painel em http://127.0.0.1:${porta}`));
