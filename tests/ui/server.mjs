// Servidor estatico da fixture de interface. Uso: node server.mjs <porta> [pasta]
// /vai/<pagina> redireciona para /<pagina>. FIXTURE_HOLD_MS segura toda resposta ate passar esse tempo da subida.
// /conta so abre com a sessao que o POST de /entrar em /sessao cria (senha "abre-te-sesamo").
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const port = Number(process.argv[2] || 0);
const dir = path.resolve(process.argv[3] || path.join(path.dirname(fileURLToPath(import.meta.url)), "site"));
const types = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".png": "image/png", ".svg": "image/svg+xml" };
const ready = Date.now() + Number(process.env.FIXTURE_HOLD_MS || 0);

const server = http.createServer(async (req, res) => {
  let body = "";
  for await (const chunk of req) body += chunk;
  const hold = ready - Date.now();
  if (hold > 0) await new Promise((r) => setTimeout(r, hold));
  let name = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const go = (location, extra = {}) => {
    res.writeHead(303, { location, ...extra });
    res.end();
  };
  if (name.startsWith("/vai/")) return go(name.slice(4));
  if (req.method === "POST" && name === "/sessao") {
    const ok = new URLSearchParams(body).get("senha") === "abre-te-sesamo";
    return ok ? go("/conta", { "set-cookie": "sessao=ok; Path=/; HttpOnly" }) : go("/entrar?erro=1");
  }
  if (name === "/conta" && !/(^|;\s*)sessao=ok/.test(req.headers.cookie || "")) return go("/entrar");
  if (name === "/") name = "/index.html";
  if (!path.extname(name)) name += ".html";
  const file = path.join(dir, name);
  if (!file.startsWith(dir) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("não encontrado");
    return;
  }
  res.writeHead(200, { "content-type": types[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
  fs.createReadStream(file).pipe(res);
});

server.listen(port, "127.0.0.1", () => console.log(`fixture em http://127.0.0.1:${server.address().port}`));
