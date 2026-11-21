#!/usr/bin/env node
// Captura de interface do kit. Chamado pelo ui.sh; nao e hook.
// Sobe o app (ui.dev) se ele nao responde, abre cada rota num Chromium headless, percorre as
// larguras (tamanhos de ui.viewports, larguras padrao e as quebras do CSS da pagina), roda a
// sondagem de ui-probe.js em cada uma e grava as imagens e o report.json. Com --steps, refaz depois de
// cada carga os passos (clique, campo, tecla) que levam a tela ate o estado pedido.
// Saida: 0 sem achado, 1 com achado, 2 uso ou config, 3 sem meio de captura, 4 app nao respondeu,
// 5 captura incompleta (tela sem sondagem completa ou erro no meio da captura).
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WIN = process.platform === "win32";
const DEFAULT_VIEWPORTS = ["360x800", "768x1024", "1280x800", "1920x1080"];
const BASE_WIDTHS = [320, 360, 390, 414, 480, 600, 768, 820, 1024, 1280, 1366, 1440, 1536, 1920];
const MAX_WIDTHS = 40;
const CONFIRM_MS = 90000;
const LOCAL_HOSTS = ["localhost", "127.0.0.1", "[::1]", "0.0.0.0"];
const OVERFLOW_RULES = ["rolagem-horizontal", "corte-horizontal"];
const WAIT_S = Number(process.env.KIT_UI_WAIT_S || 120);
const LOAD_MS = Number(process.env.KIT_UI_LOAD_MS || 30000);
const BUDGET_MS = Number(process.env.KIT_UI_BUDGET_S || 540) * 1000;
const REPLY_MS = Number(process.env.KIT_UI_REPLY_S || 60) * 1000;
const STEP_MS = 10000;
const STARTED = Date.now();

class Fail extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// Passo de --steps que nao deu certo: a pagina segue inteira, so aquela tela fica incompleta.
class StepFail extends Error {}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// O sandbox do Bash (macOS, Linux e WSL2) pode barrar porta local e o proprio navegador.
const SANDBOX_HINT = WIN ? "" : " Se o Bash roda em sandbox, ele pode estar barrando a porta local ou o navegador: rode a captura de novo fora do sandbox.";
const rel = (p) => (path.relative(process.cwd(), p) || ".").split(path.sep).join("/");

function parseArgs(argv) {
  const a = { kit: ".claude/kit.json", name: "captura", routes: null, out: null, probeOnly: false, attach: null, match: "", doctor: false, tiles: 3, steps: null, serve: null };
  const need = (i, flag) => {
    if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) throw new Fail(2, `ui: ${flag} precisa de um valor`);
    return argv[i + 1];
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--kit") a.kit = need(i++, k);
    else if (k === "--name") a.name = need(i++, k);
    else if (k === "--routes") a.routes = need(i++, k).split(",").map((s) => s.trim()).filter(Boolean);
    else if (k === "--out") a.out = need(i++, k);
    else if (k === "--attach") a.attach = need(i++, k);
    else if (k === "--match") a.match = need(i++, k);
    else if (k === "--steps") a.steps = need(i++, k);
    else if (k === "--serve") a.serve = need(i++, k);
    else if (k === "--tiles") a.tiles = Math.max(1, Math.min(6, Number(need(i++, k)) || 3));
    else if (k === "--probe-only") a.probeOnly = true;
    else if (k === "--doctor") a.doctor = true;
    else throw new Fail(2, `ui: opção desconhecida: ${k}`);
  }
  // O nome vira pasta dentro de .claude/state/ui: comeca por letra ou numero, para "." e ".." nao subirem de pasta.
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,59}$/.test(a.name)) throw new Fail(2, "ui: --name começa por letra ou número e aceita só letras, números, ponto, hífen e sublinhado");
  if (a.steps && a.attach) throw new Fail(2, "ui: --steps não combina com --attach; na página aberta o estado já é o que está na tela");
  if (a.serve && a.attach) throw new Fail(2, "ui: --serve não combina com --attach; --serve abre a pasta num navegador do kit");
  return a;
}

const STEP_ACTIONS = ["goto", "click", "fill", "press", "hover", "wait", "js"];
const KEYS = {
  Enter: [13, "\r"], Tab: [9], Escape: [27], Backspace: [8], Delete: [46], Space: [32, " "], Home: [36], End: [35], PageUp: [33],
  PageDown: [34], ArrowUp: [38], ArrowDown: [40], ArrowLeft: [37], ArrowRight: [39],
};

function stepText(s) {
  const action = STEP_ACTIONS.find((k) => k in s);
  const target = String(s[action]).replace(/\s+/g, " ").slice(0, 60);
  return `${action} ${JSON.stringify(target)}`;
}

function checkStep(s, where) {
  const bad = (why) => new Fail(2, `ui: ${where} dos passos: ${why}`);
  if (!s || typeof s !== "object" || Array.isArray(s)) throw bad("cada passo é um objeto, como {\"click\": \"text=Entrar\"}");
  const actions = STEP_ACTIONS.filter((k) => k in s);
  if (actions.length !== 1) throw bad(`precisa de uma ação só, entre ${STEP_ACTIONS.join(", ")}`);
  const action = actions[0];
  const extra = Object.keys(s).filter((k) => k !== action && k !== "timeout" && !(k === "value" && action === "fill"));
  if (extra.length) throw bad(`chave desconhecida: ${extra.join(", ")}`);
  const v = s[action];
  if (action === "wait") {
    if (!(typeof v === "number" && v >= 0) && !(typeof v === "string" && v.trim())) throw bad("wait pede um seletor ou um tempo em milissegundos");
  } else if (typeof v !== "string" || !v.trim()) throw bad(`${action} pede um texto`);
  if (typeof v === "string" && /^text=\s*$/.test(v)) throw bad("text= pede o texto visível do elemento");
  if (action === "press" && !KEYS[v] && [...v].length !== 1) throw bad(`press aceita uma letra ou ${Object.keys(KEYS).join(", ")}`);
  if (action === "fill") {
    if (typeof s.value !== "string") throw bad("fill pede também \"value\" com o texto do campo");
    for (const m of s.value.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)) {
      if (process.env[m[1]] === undefined) throw bad(`a variável de ambiente ${m[1]} não está definida`);
    }
  }
  if ("timeout" in s && !(typeof s.timeout === "number" && s.timeout > 0)) throw bad("timeout é um número de milissegundos");
}

// --steps: JSON na propria linha de comando ou caminho de um arquivo. Lista de passos (refeitos depois de
// cada carga da rota) ou { "setup": [...], "steps": [...] }, com setup rodando uma vez antes da primeira rota.
function loadSteps(arg) {
  let text = arg.trim();
  let from = "--steps";
  if (!/^[[{]/.test(text)) {
    from = arg;
    try {
      text = fs.readFileSync(arg, "utf8");
    } catch {
      throw new Fail(2, `ui: arquivo de passos não encontrado: ${arg}`);
    }
    if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  }
  let data;
  try {
    data = JSON.parse(text);
  } catch (e) {
    throw new Fail(2, `ui: ${from} não é JSON válido (${e.message})`);
  }
  if (!data || typeof data !== "object") throw new Fail(2, "ui: --steps pede uma lista de passos ou um objeto com setup e steps");
  const plan = Array.isArray(data) ? { setup: [], steps: data } : { setup: data.setup || [], steps: data.steps || [] };
  if (!Array.isArray(data)) {
    const extra = Object.keys(data).filter((k) => k !== "setup" && k !== "steps");
    if (extra.length) throw new Fail(2, `ui: --steps com chave desconhecida: ${extra.join(", ")}`);
  }
  for (const name of ["setup", "steps"]) {
    if (!Array.isArray(plan[name])) throw new Fail(2, `ui: "${name}" dos passos precisa ser uma lista`);
    plan[name].forEach((s, i) => checkStep(s, `${name === "setup" ? "preparo" : "passo"} ${i + 1}`));
  }
  if (!plan.setup.length && !plan.steps.length) throw new Fail(2, "ui: --steps sem nenhum passo");
  return plan;
}

function loadUi(kitPath) {
  if (!fs.existsSync(kitPath)) throw new Fail(2, `ui: kit.json não encontrado: ${kitPath}`);
  let kit;
  try {
    const text = fs.readFileSync(kitPath, "utf8");
    kit = JSON.parse(text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);
  } catch {
    throw new Fail(2, `ui: ${kitPath} não é JSON válido`);
  }
  const ui = kit && kit.ui;
  if (!ui || typeof ui !== "object" || Array.isArray(ui)) throw new Fail(2, `ui: ${kitPath} não tem a chave "ui"; nada a capturar`);
  const list = (v) => (Array.isArray(v) ? v.filter((x) => typeof x === "string" && x.trim()) : []);
  if (typeof ui.url === "string" && ui.url.trim() && !/^https?:\/\//i.test(ui.url.trim())) {
    throw new Fail(2, "ui: ui.url precisa começar com http:// ou https://");
  }
  const viewports = list(ui.viewports).length ? list(ui.viewports) : DEFAULT_VIEWPORTS;
  const parsed = viewports.map((v) => {
    const m = /^(\d{2,5})x(\d{2,5})$/.exec(v.trim());
    if (!m) throw new Fail(2, `ui: ui.viewports "${v}" precisa ser <largura>x<altura>, como 360x800`);
    return { label: `${m[1]}x${m[2]}`, width: Number(m[1]), height: Number(m[2]) };
  }).sort((x, y) => x.width - y.width);
  return {
    dev: typeof ui.dev === "string" ? ui.dev.trim() : "",
    url: typeof ui.url === "string" ? ui.url.trim().replace(/\/+$/, "") : "",
    routes: list(ui.routes).length ? list(ui.routes) : ["/"],
    screenshot: typeof ui.screenshot === "string" ? ui.screenshot.trim() : "",
    viewports: parsed,
    root: path.resolve(path.dirname(kitPath), ".."),
    direction: loadDirection(path.resolve(path.dirname(kitPath), "..")),
  };
}

// Familias da direcao visual: a linha "Tipografia:" de cada .claude/rules/kit-design*.md com o cabecalho
// kit:design, nomes entre crases antes do travessao (variavel CSS e pasta ficam de fora). Rule sem o
// cabecalho e do projeto e nao conta.
function loadDirection(root) {
  const dir = path.join(root, ".claude", "rules");
  const rules = [];
  const families = [];
  let names = [];
  try {
    names = fs.readdirSync(dir).filter((f) => /^kit-design(-[^/\\]+)?\.md$/.test(f)).sort();
  } catch {
    return { rules, families };
  }
  for (const name of names) {
    let text = "";
    try {
      text = fs.readFileSync(path.join(dir, name), "utf8");
    } catch {
      continue;
    }
    if (!/^<!-- kit:design v\d+ -->$/m.test(text.replace(/\r/g, ""))) continue;
    rules.push(`.claude/rules/${name}`);
    const line = text.split(/\r?\n/).find((l) => /^\s*-\s*Tipografia:/.test(l));
    if (!line) continue;
    const head = line.split(/\s—\s/)[0];
    for (const m of head.matchAll(/`([^`]+)`/g)) {
      const f = m[1].trim().replace(/^["']|["']$/g, "");
      if (!f || f.startsWith("--") || /[/\\<>]/.test(f)) continue;
      if (!families.some((x) => x.toLowerCase() === f.toLowerCase())) families.push(f);
    }
  }
  return { rules, families };
}

// conferir [M10]: o projeto tem direcao com familia propria e todo o texto visivel saiu em fonte generica
// ou de sistema, nenhuma delas da direcao.
function directionFinding(ui, style) {
  const { families, rules } = ui.direction;
  if (!families.length || !style || !style.allSystem) return null;
  const chosen = new Set(families.map((f) => f.toLowerCase()));
  if (style.fonts.some((f) => chosen.has(f.family.toLowerCase()))) return null;
  const used = style.fonts.map((f) => `${f.family} ${f.share}%`).join(", ");
  const missing = (style.unloaded || []).filter((f) => chosen.has(f.toLowerCase()));
  return {
    level: "conferir", id: "M10", rule: "fonte-fora-da-direcao", where: "página", widths: "", count: 1,
    detail: `todo o texto visível em fonte genérica ou de sistema (${used}); a direção (${rules.join(", ")}) usa ${families.join(", ")}` +
      (missing.length ? `; declarada na página e não carregada: ${missing.join(", ")}` : ""),
  };
}

function firstExisting(paths) {
  for (const p of paths) {
    try {
      if (p && fs.statSync(p).isFile()) return p;
    } catch { /* segue */ }
  }
  return "";
}

function onPath(names) {
  const dirs = (process.env.PATH || "").split(path.delimiter).filter(Boolean);
  for (const n of names) {
    for (const d of dirs) {
      const hit = firstExisting(WIN ? [path.join(d, n + ".exe"), path.join(d, n)] : [path.join(d, n)]);
      if (hit) return hit;
    }
  }
  return "";
}

function playwrightChromium() {
  const home = os.homedir();
  const base = WIN ? path.join(process.env.LOCALAPPDATA || path.join(home, "AppData", "Local"), "ms-playwright")
    : process.platform === "darwin" ? path.join(home, "Library", "Caches", "ms-playwright")
      : path.join(home, ".cache", "ms-playwright");
  let dirs;
  try {
    dirs = fs.readdirSync(base).filter((d) => /^chromium-\d+$/.test(d)).sort((a, b) => Number(b.split("-")[1]) - Number(a.split("-")[1]));
  } catch {
    return "";
  }
  for (const d of dirs) {
    let subs;
    try {
      subs = fs.readdirSync(path.join(base, d));
    } catch {
      continue;
    }
    for (const s of subs) {
      const hit = firstExisting([
        path.join(base, d, s, "chrome.exe"),
        path.join(base, d, s, "chrome"),
        path.join(base, d, s, "Chromium.app", "Contents", "MacOS", "Chromium"),
        path.join(base, d, s, "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing"),
      ]);
      if (hit) return hit;
    }
  }
  return "";
}

export function findBrowser() {
  if (process.env.KIT_UI_BROWSER !== undefined) {
    const forced = firstExisting([process.env.KIT_UI_BROWSER]);
    return forced ? { path: forced, name: "navegador" } : null;
  }
  const env = process.env;
  const cands = [];
  if (WIN) {
    for (const root of [env.PROGRAMFILES, env["PROGRAMFILES(X86)"], env.LOCALAPPDATA]) {
      if (!root) continue;
      cands.push([path.join(root, "Google", "Chrome", "Application", "chrome.exe"), "chrome"]);
    }
    for (const root of [env["PROGRAMFILES(X86)"], env.PROGRAMFILES, env.LOCALAPPDATA]) {
      if (!root) continue;
      cands.push([path.join(root, "Microsoft", "Edge", "Application", "msedge.exe"), "edge"]);
      cands.push([path.join(root, "Chromium", "Application", "chrome.exe"), "chromium"]);
    }
  } else if (process.platform === "darwin") {
    for (const root of ["/Applications", path.join(os.homedir(), "Applications")]) {
      cands.push([path.join(root, "Google Chrome.app", "Contents", "MacOS", "Google Chrome"), "chrome"]);
      cands.push([path.join(root, "Microsoft Edge.app", "Contents", "MacOS", "Microsoft Edge"), "edge"]);
      cands.push([path.join(root, "Chromium.app", "Contents", "MacOS", "Chromium"), "chromium"]);
    }
  } else {
    const chrome = onPath(["google-chrome", "google-chrome-stable"]);
    if (chrome) cands.push([chrome, "chrome"]);
    const chromium = onPath(["chromium", "chromium-browser"]);
    if (chromium) cands.push([chromium, "chromium"]);
    const edge = onPath(["microsoft-edge", "microsoft-edge-stable"]);
    if (edge) cands.push([edge, "edge"]);
  }
  for (const [p, name] of cands) {
    if (firstExisting([p])) return { path: p, name };
  }
  const pw = playwrightChromium();
  return pw ? { path: pw, name: "chromium" } : null;
}

function request(url, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (v) => {
      if (!done) {
        done = true;
        resolve(v);
      }
    };
    let req;
    try {
      const lib = url.startsWith("https:") ? https : http;
      req = lib.get(url, { timeout: timeoutMs, rejectUnauthorized: false, autoSelectFamily: true }, (res) => {
        res.resume();
        finish(res.statusCode || 0);
      });
    } catch {
      finish(0);
      return;
    }
    req.on("timeout", () => {
      req.destroy();
      finish(0);
    });
    req.on("error", () => finish(0));
  });
}

function portOpen(url, timeoutMs) {
  return new Promise((resolve) => {
    let u;
    try {
      u = new URL(url);
    } catch {
      resolve(false);
      return;
    }
    const sock = net.connect({
      host: u.hostname.replace(/^\[|\]$/g, ""), port: Number(u.port || (u.protocol === "https:" ? 443 : 80)), autoSelectFamily: true,
    });
    const finish = (v) => {
      sock.destroy();
      resolve(v);
    };
    sock.setTimeout(timeoutMs, () => finish(false));
    sock.once("connect", () => finish(true));
    sock.once("error", () => finish(false));
  });
}

function getJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: 5000 }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (body += c));
      res.on("end", () => {
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(e);
        }
      });
    });
    req.on("timeout", () => req.destroy(new Error("tempo esgotado")));
    req.on("error", reject);
  });
}

function killTree(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  try {
    if (WIN) spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
    else process.kill(-child.pid, "SIGTERM");
  } catch {
    try {
      child.kill("SIGKILL");
    } catch { /* ja saiu */ }
  }
}

function listenerPids(port) {
  const pids = new Set();
  if (WIN) {
    const r = spawnSync("netstat", ["-ano", "-p", "tcp"], { encoding: "utf8", windowsHide: true });
    for (const line of (r.stdout || "").split(/\r?\n/)) {
      const f = line.trim().split(/\s+/);
      if (f.length >= 5 && f[3] === "LISTENING" && f[1].endsWith(":" + port)) pids.add(f[4]);
    }
  } else {
    const r = spawnSync("lsof", ["-ti", `tcp:${port}`, "-sTCP:LISTEN"], { encoding: "utf8" });
    for (const p of (r.stdout || "").split(/\s+/)) if (/^\d+$/.test(p)) pids.add(p);
  }
  pids.delete("0");
  pids.delete(String(process.pid));
  return [...pids];
}

const cleanups = [];
let cleaning = false;
async function cleanup() {
  if (cleaning) return;
  cleaning = true;
  for (const fn of cleanups.reverse()) {
    try {
      await fn();
    } catch { /* limpeza segue */ }
  }
}

async function ensureApp(ui, outDir) {
  if (!ui.url) return { state: "nenhum" };
  if (await request(ui.url, 2500)) return { state: "ja-rodando" };
  // Porta ja em uso: o app e de quem o subiu e so esta lento. Espera responder; nao sobe outro nem derruba esse.
  if (await portOpen(ui.url, 1500)) {
    const until = Date.now() + WAIT_S * 1000;
    while (Date.now() < until) {
      if (await request(ui.url, Math.min(30000, Math.max(1000, until - Date.now())))) return { state: "ja-rodando" };
      await sleep(400);
    }
    throw new Fail(4, `ui: a porta de ${ui.url} está em uso por um processo que não respondeu em ${WAIT_S}s; a captura não sobe outro app nem derruba esse`);
  }
  if (!ui.dev) throw new Fail(4, `ui: ${ui.url} não responde e o kit.json não tem ui.dev para subir o app`);
  const logPath = path.join(outDir, "dev.log");
  const log = fs.openSync(logPath, "w");
  const child = spawn(process.env.KIT_BASH || "bash", ["-c", ui.dev], {
    cwd: ui.root, stdio: ["ignore", log, log], detached: !WIN, windowsHide: true,
  });
  let exited = null;
  child.on("exit", (code, signal) => (exited = code === null ? `sinal ${signal}` : `código ${code}`));
  child.on("error", (e) => (exited = e.message));
  // A porta local estava livre antes de ui.dev subir: quem escuta nela no fim veio dele.
  const port = (() => {
    try {
      const u = new URL(ui.url);
      if (!LOCAL_HOSTS.includes(u.hostname)) return "";
      return u.port || (u.protocol === "https:" ? "443" : "80");
    } catch {
      return "";
    }
  })();
  cleanups.push(async () => {
    killTree(child);
    for (let i = 0; i < 15 && (await request(ui.url, 800)); i++) {
      if (i === 4 && port) {
        for (const pid of listenerPids(port)) {
          try {
            if (WIN) spawnSync("taskkill", ["/pid", pid, "/T", "/F"], { stdio: "ignore", windowsHide: true });
            else process.kill(Number(pid), "SIGKILL");
          } catch { /* ja saiu */ }
        }
      }
      await sleep(200);
    }
    try {
      fs.closeSync(log);
    } catch { /* ja fechado */ }
  });
  const tail = () => {
    try {
      return fs.readFileSync(logPath, "utf8").trim().split(/\r?\n/).slice(-8).join("\n  ");
    } catch {
      return "";
    }
  };
  const deadline = Date.now() + WAIT_S * 1000;
  while (Date.now() < deadline) {
    if (await request(ui.url, 1500)) return { state: "iniciado" };
    if (exited !== null) throw new Fail(4, `ui: "${ui.dev}" terminou (${exited}) antes de ${ui.url} responder.${SANDBOX_HINT}\n  ${tail()}`);
    await sleep(400);
  }
  throw new Fail(4, `ui: ${ui.url} não respondeu em ${WAIT_S}s depois de "${ui.dev}".${SANDBOX_HINT}\n  ${tail()}`);
}

const MIME = {
  ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".avif": "image/avif", ".ico": "image/x-icon",
  ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf",
};
const SERVE_MAX = 12;

// --serve: a pasta (amostras da /kit:design, amostra.html da SPEC) servida so para leitura em 127.0.0.1,
// numa porta livre, enquanto a captura roda. Caminho que resolve para fora da pasta, inclusive por link, e 404.
async function serveDir(dir) {
  let root;
  try {
    root = fs.realpathSync(dir);
    if (!fs.statSync(root).isDirectory()) throw new Error("arquivo");
  } catch {
    throw new Fail(2, `ui: --serve pede uma pasta que existe: ${dir}`);
  }
  const inside = (f) => f === root || f.startsWith(root.endsWith(path.sep) ? root : root + path.sep);
  const fileFor = (p) => {
    let f = fs.realpathSync(path.join(root, p));
    if (!inside(f)) return "";
    if (fs.statSync(f).isDirectory()) {
      f = fs.realpathSync(path.join(f, "index.html"));
      if (!inside(f)) return "";
    }
    return fs.statSync(f).isFile() ? f : "";
  };
  const server = http.createServer((req, res) => {
    const send = (code, body, type) => {
      res.writeHead(code, { "Content-Type": type || "text/plain; charset=utf-8", "Cache-Control": "no-store" });
      res.end(req.method === "HEAD" ? undefined : body);
    };
    if (req.method !== "GET" && req.method !== "HEAD") return send(405, "metodo nao aceito");
    // Host diferente do endereco servido (DNS rebinding) nao le a pasta.
    if (req.headers.host !== `127.0.0.1:${server.address().port}`) return send(403, "host nao aceito");
    let file = "";
    try {
      file = fileFor(decodeURIComponent(new URL(req.url, "http://kit").pathname));
    } catch { /* nao existe ou caminho invalido */ }
    if (!file) return send(404, "nao encontrado");
    fs.readFile(file, (err, body) => (err ? send(404, "nao encontrado") : send(200, body, MIME[path.extname(file).toLowerCase()] || "application/octet-stream")));
  });
  await new Promise((resolve, reject) => {
    server.once("error", (e) => reject(new Fail(4, `ui: --serve não abriu a porta local: ${e.message}.${SANDBOX_HINT}`)));
    server.listen(0, "127.0.0.1", resolve);
  });
  const close = () => new Promise((resolve) => {
    if (typeof server.closeAllConnections === "function") server.closeAllConnections();
    server.close(() => resolve());
    setTimeout(resolve, 2000);
  });
  return { url: `http://127.0.0.1:${server.address().port}`, root, close };
}

// Paginas de --serve: as de --routes (arquivos da pasta) ou todo .html do primeiro nivel da pasta.
function serveRoutes(root, asked) {
  if (asked) {
    for (const r of asked) {
      if (/^[a-z][a-z0-9+.-]*:/i.test(r)) throw new Fail(2, `ui: com --serve a rota "${r}" é um arquivo da pasta, não um endereço`);
    }
    return asked;
  }
  const found = fs.readdirSync(root).filter((f) => /\.html?$/i.test(f) && fs.statSync(path.join(root, f)).isFile()).sort();
  if (!found.length) throw new Fail(2, `ui: --serve: nenhum .html em ${rel(root)}`);
  if (found.length > SERVE_MAX) throw new Fail(2, `ui: --serve: ${found.length} arquivos .html em ${rel(root)}; passe as páginas em --routes (até ${SERVE_MAX} por vez)`);
  return found;
}

class Cdp {
  constructor(sendRaw) {
    this.sendRaw = sendRaw;
    this.seq = 0;
    this.pending = new Map();
    this.handlers = new Map();
    this.closed = false;
  }

  dispatch(text) {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if (msg.id !== undefined) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message}`));
      else p.resolve(msg.result || {});
      return;
    }
    for (const fn of this.handlers.get(msg.method) || []) fn(msg.params || {}, msg.sessionId);
  }

  fail(reason) {
    this.closed = true;
    for (const p of this.pending.values()) p.reject(new Error(reason));
    this.pending.clear();
  }

  send(method, params = {}, sessionId) {
    if (this.closed) return Promise.reject(new Error("navegador fechado"));
    const id = ++this.seq;
    const msg = { id, method, params };
    if (sessionId) msg.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method}: sem resposta do navegador`));
      }, REPLY_MS);
      this.pending.set(id, {
        method,
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      this.sendRaw(JSON.stringify(msg));
    });
  }

  on(method, fn) {
    if (!this.handlers.has(method)) this.handlers.set(method, []);
    this.handlers.get(method).push(fn);
  }
}

async function launchBrowser(browser, extraArgs) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "kit-ui-"));
  const args = [
    "--headless=new", "--remote-debugging-pipe", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check",
    "--disable-extensions", "--disable-background-networking", "--disable-sync", "--disable-component-update",
    "--hide-scrollbars", "--mute-audio", "--force-color-profile=srgb", "--disable-gpu", ...extraArgs, "about:blank",
  ];
  const child = spawn(browser.path, args, { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"], windowsHide: true });
  const cdp = new Cdp((text) => {
    try {
      child.stdio[3].write(text + "\0");
    } catch { /* navegador saiu */ }
  });
  let buf = Buffer.alloc(0);
  child.stdio[4].on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    let i;
    while ((i = buf.indexOf(0)) !== -1) {
      cdp.dispatch(buf.subarray(0, i).toString("utf8"));
      buf = buf.subarray(i + 1);
    }
  });
  child.stdio[3].on("error", () => {});
  child.stdio[4].on("error", () => {});
  child.on("exit", () => cdp.fail("o navegador fechou"));
  child.on("error", () => cdp.fail("o navegador não iniciou"));
  const close = async () => {
    try {
      await Promise.race([cdp.send("Browser.close"), sleep(2000)]);
    } catch { /* ja fechou */ }
    for (let i = 0; i < 15 && child.exitCode === null && child.signalCode === null; i++) await sleep(100);
    if (WIN) spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
    else if (child.exitCode === null) {
      try {
        child.kill("SIGKILL");
      } catch { /* ja saiu */ }
    }
    for (let i = 0; i < 10; i++) {
      try {
        fs.rmSync(profile, { recursive: true, force: true });
        break;
      } catch {
        await sleep(200);
      }
    }
  };
  try {
    const v = await Promise.race([cdp.send("Browser.getVersion"), sleep(20000).then(() => null)]);
    if (!v) throw new Error("sem resposta em 20s");
    return { cdp, close, version: (v.product || "").replace(/^[^/]*\//, "") };
  } catch (e) {
    await close();
    throw e;
  }
}

async function openBrowser(browser, ui) {
  const extra = [];
  try {
    const u = new URL(ui.url);
    if (u.protocol === "https:" && LOCAL_HOSTS.includes(u.hostname)) extra.push("--ignore-certificate-errors");
  } catch { /* sem url */ }
  try {
    return await launchBrowser(browser, extra);
  } catch (e) {
    if (process.platform !== "linux") throw new Fail(3, `ui: o navegador não iniciou (${browser.path}): ${e.message}.${SANDBOX_HINT}`);
  }
  try {
    return await launchBrowser(browser, [...extra, "--no-sandbox"]);
  } catch (e) {
    throw new Fail(3, `ui: o navegador não iniciou (${browser.path}): ${e.message}.${SANDBOX_HINT}`);
  }
}

async function attachBrowser(endpoint, match) {
  if (typeof WebSocket === "undefined") throw new Fail(3, "ui: --attach exige Node 22 ou mais novo (WebSocket nativo)");
  const base = endpoint.replace(/\/+$/, "");
  let pages;
  try {
    pages = (await getJson(base + "/json/list")).filter((t) => t.type === "page" && t.webSocketDebuggerUrl);
  } catch (e) {
    throw new Fail(3, `ui: não consegui ler as páginas em ${base} (${e.message})`);
  }
  const wanted = pages.filter((t) => (match ? (t.url || "").includes(match) || (t.title || "").includes(match) : !/^(about:|chrome:|devtools:)/.test(t.url || "")));
  if (!wanted.length) {
    throw new Fail(3, `ui: nenhuma página ${match ? `com "${match}" ` : ""}em ${base}; abertas: ${pages.map((t) => t.url).join(", ") || "nenhuma"}`);
  }
  const target = wanted[0];
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  const cdp = new Cdp((text) => ws.send(text));
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Fail(3, `ui: não conectei em ${target.webSocketDebuggerUrl}`)), { once: true });
  });
  ws.addEventListener("message", (ev) => cdp.dispatch(typeof ev.data === "string" ? ev.data : Buffer.from(ev.data).toString("utf8")));
  ws.addEventListener("close", () => cdp.fail("a conexão com o navegador fechou"));
  return { cdp, close: async () => ws.close(), version: "", pageUrl: target.url };
}

class Page {
  constructor(cdp, sessionId) {
    this.cdp = cdp;
    this.sid = sessionId;
    this.inflight = new Map();
    this.console = [];
    this.network = [];
    this.dialogs = [];
    this.loaded = null;
    this.docs = new Map();
    this.lastActivity = Date.now();
    cdp.on("Page.javascriptDialogOpening", (p, sid) => this.mine(sid) && this.onDialog(p));
    cdp.on("Network.requestWillBeSent", (p, sid) => this.mine(sid) && this.onRequest(p));
    cdp.on("Network.responseReceived", (p, sid) => this.mine(sid) && this.onResponse(p));
    cdp.on("Network.loadingFinished", (p, sid) => this.mine(sid) && this.done(p.requestId));
    cdp.on("Network.loadingFailed", (p, sid) => this.mine(sid) && this.onFailed(p));
    cdp.on("Runtime.exceptionThrown", (p, sid) => this.mine(sid) && this.onException(p));
    cdp.on("Runtime.consoleAPICalled", (p, sid) => this.mine(sid) && this.onConsole(p));
    cdp.on("Page.loadEventFired", (p, sid) => this.mine(sid) && this.loaded && this.loaded());
  }

  mine(sid) {
    return (sid || undefined) === (this.sid || undefined);
  }

  send(method, params) {
    return this.cdp.send(method, params, this.sid);
  }

  note(list, text) {
    const t = String(text).replace(/\s+/g, " ").trim().slice(0, 240);
    if (t && !list.includes(t) && list.length < 10) list.push(t);
  }

  onRequest(p) {
    this.lastActivity = Date.now();
    if (p.type === "EventSource" || p.type === "WebSocket") return;
    this.inflight.set(p.requestId, p.request.url);
  }

  onResponse(p) {
    this.lastActivity = Date.now();
    const s = p.response.status;
    if (p.type === "Document") this.docs.set(p.requestId, s);
    else if (s >= 400 && !/\/favicon\.ico(\?|$)/.test(p.response.url)) this.note(this.network, `${s} ${p.response.url}`);
    if (p.type === "EventSource") this.inflight.delete(p.requestId);
  }

  done(id) {
    this.lastActivity = Date.now();
    this.inflight.delete(id);
  }

  onFailed(p) {
    const url = this.inflight.get(p.requestId) || "";
    this.done(p.requestId);
    if (p.canceled || p.errorText === "net::ERR_ABORTED" || /\/favicon\.ico(\?|$)/.test(url)) return;
    this.note(this.network, `${p.errorText} ${url}`);
  }

  onException(p) {
    const d = p.exceptionDetails || {};
    const text = (d.exception && (d.exception.description || d.exception.value)) || d.text || "erro";
    this.note(this.console, String(text).split("\n")[0]);
  }

  // Dialogo aberto trava a pagina ate alguem responder: fecha e deixa anotado.
  onDialog(p) {
    this.note(this.dialogs, `${p.type}: ${p.message || ""}`);
    this.send("Page.handleJavaScriptDialog", { accept: true }).catch(() => {});
  }

  onConsole(p) {
    if (p.type !== "error") return;
    const text = (p.args || []).map((a) => (a.value !== undefined ? String(a.value) : a.description || "")).join(" ");
    this.note(this.console, text.split("\n")[0]);
  }

  async evaluate(expression, awaitPromise = true) {
    const r = await this.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise });
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      throw new Error((d.exception && d.exception.description) || d.text || "erro ao avaliar na página");
    }
    return r.result ? r.result.value : undefined;
  }

  async setViewport(width, height) {
    await this.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: width < 768 });
    await this.settle(120);
  }

  async settle(ms) {
    try {
      await Promise.race([
        this.evaluate("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))"),
        sleep(1500),
      ]);
    } catch { /* pagina navegando */ }
    await sleep(ms);
  }

  async idle(quietMs, maxMs) {
    const end = Date.now() + maxMs;
    while (Date.now() < end) {
      if (this.inflight.size === 0 && Date.now() - this.lastActivity >= quietMs) return;
      await sleep(100);
    }
  }

  async colorScheme(value) {
    await this.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value }] });
  }

  async navigate(url) {
    this.inflight.clear();
    this.docs.clear();
    this.console = [];
    this.network = [];
    this.dialogs = [];
    const loaded = new Promise((r) => (this.loaded = r));
    const nav = await this.send("Page.navigate", { url });
    if (nav.errorText) {
      this.loaded = null;
      return { ok: false, error: nav.errorText };
    }
    // Sem loaderId a navegacao ficou no mesmo documento (so a ancora mudou): nao ha load nem pagina nova. Recarrega.
    if (!nav.loaderId) await this.send("Page.reload");
    const timedOut = await Promise.race([loaded.then(() => false), sleep(LOAD_MS).then(() => true)]);
    this.loaded = null;
    await this.idle(500, 10000);
    try {
      await Promise.race([this.evaluate("document.fonts ? document.fonts.ready.then(() => true) : true"), sleep(3000)]);
    } catch { /* sem fontes */ }
    await this.settle(250);
    const finalUrl = await this.href();
    const status = (nav.loaderId ? this.docs.get(nav.loaderId) : [...this.docs.values()][0]) || 0;
    return { ok: true, timedOut, status, finalUrl };
  }

  async href() {
    try {
      return (await Promise.race([this.evaluate("location.href"), sleep(3000).then(() => "")])) || "";
    } catch {
      return "";
    }
  }

  // Depois de uma acao: espera a navegacao que ela disparou (se disparou), a rede e o desenho.
  async calm() {
    await sleep(120);
    const until = Date.now() + LOAD_MS;
    while (Date.now() < until) {
      let state = "";
      try {
        state = await Promise.race([this.evaluate("document.readyState"), sleep(2000).then(() => "")]);
      } catch { /* pagina navegando */ }
      if (state === "complete") break;
      await sleep(100);
    }
    await this.idle(400, 8000);
    await this.settle(120);
  }

  // Espera o elemento aparecer, rola ate ele e devolve o centro. O elemento fica em window.__kitUiEl.
  async locate(selector, mode, timeoutMs) {
    const until = Date.now() + timeoutMs;
    const expr = `(${LOCATE_SRC})(${JSON.stringify(selector)}, ${JSON.stringify(mode)})`;
    for (;;) {
      let r = null;
      try {
        r = await Promise.race([this.evaluate(expr), sleep(3000).then(() => null)]);
      } catch (e) {
        if (this.cdp.closed) throw e;
      }
      if (r && r.error) throw new Error(r.error);
      if (r) return r;
      if (Date.now() > until) throw new Error(`"${selector}" não apareceu em ${Math.round(timeoutMs / 1000)}s`);
      await sleep(100);
    }
  }

  async mouse(type, x, y, extra = {}) {
    await this.send("Input.dispatchMouseEvent", { type, x, y, ...extra });
  }

  async click(selector, timeoutMs) {
    const p = await this.locate(selector, "click", timeoutMs);
    await this.mouse("mouseMoved", p.x, p.y);
    await this.mouse("mousePressed", p.x, p.y, { button: "left", clickCount: 1 });
    await this.mouse("mouseReleased", p.x, p.y, { button: "left", clickCount: 1 });
  }

  async fill(selector, value, timeoutMs) {
    await this.locate(selector, "fill", timeoutMs);
    const err = await this.evaluate(`(${FILL_SRC})(${JSON.stringify(value)})`);
    if (err) throw new Error(err);
  }

  async press(key) {
    const k = KEYS[key];
    if (!k) {
      await this.send("Input.dispatchKeyEvent", { type: "keyDown", key, text: key });
      await this.send("Input.dispatchKeyEvent", { type: "keyUp", key });
      return;
    }
    const base = { key: key === "Space" ? " " : key, code: key, windowsVirtualKeyCode: k[0], nativeVirtualKeyCode: k[0] };
    await this.send("Input.dispatchKeyEvent", k[1] ? { type: "keyDown", text: k[1], ...base } : { type: "rawKeyDown", ...base });
    await this.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  }

  async screenshot(file) {
    const r = await this.send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(file, Buffer.from(r.data, "base64"));
  }
}

// Roda dentro da pagina. Seletor CSS, ou "text=<texto visivel>": o elemento mais interno com aquele texto
// (igual; se nao houver, que o contenha). Em fill, texto de <label> leva ao campo dele.
const LOCATE_SRC = String.raw`function (sel, mode) {
  var shown = function (el) {
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var cs = getComputedStyle(el);
    return cs.visibility !== "hidden" && cs.display !== "none";
  };
  var label = function (el) {
    var tag = el.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
      var type = (el.getAttribute("type") || "").toLowerCase();
      if (tag === "INPUT" && (type === "submit" || type === "button" || type === "reset")) return (el.value || "").trim();
      return (el.getAttribute("aria-label") || el.getAttribute("placeholder") || "").trim();
    }
    return (el.textContent || "").replace(/\s+/g, " ").trim() || (el.getAttribute("aria-label") || "").trim();
  };
  // Entre os elementos com o texto, vale primeiro o que serve para a acao: controle clicavel em click e
  // hover, campo ou rotulo em fill. Um titulo "Entrar" nao ganha do botao "Entrar".
  var likely = mode === "fill" ? "label, input, textarea, select, [contenteditable]"
    : mode === "wait" ? "" : "a[href], button, summary, label, select, input, [role=button], [role=link], [role=tab], [role=menuitem], [role=option], [role=checkbox], [role=radio], [role=switch], [onclick]";
  var byText = function (want) {
    var first = function (list, same) {
      for (var i = 0; i < list.length; i++) if (same(label(list[i])) && shown(list[i])) return list[i];
      return null;
    };
    var deepest = function (el, same) {
      for (var next = el; next;) {
        el = next;
        next = first(el.querySelectorAll("*"), same);
      }
      return el;
    };
    var all = document.querySelectorAll("body *");
    var good = likely ? document.querySelectorAll(likely) : [];
    var equal = function (t) { return t === want; };
    var within = function (t) { return t.indexOf(want) !== -1; };
    return first(good, equal) || deepest(first(all, equal), equal) || first(good, within) || deepest(first(all, within), within);
  };
  var el = null;
  if (sel.indexOf("text=") === 0) {
    el = byText(sel.slice(5).replace(/\s+/g, " ").trim());
  } else {
    var list;
    try {
      list = document.querySelectorAll(sel);
    } catch (e) {
      return { error: "seletor inválido: " + sel };
    }
    for (var i = 0; i < list.length && !el; i++) if (shown(list[i])) el = list[i];
  }
  if (!el) return null;
  if (mode === "fill" && !/^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && !el.isContentEditable) {
    var lab = el.closest("label");
    if (lab && lab.control) el = lab.control;
  }
  if (mode !== "wait") el.scrollIntoView({ block: "center", inline: "nearest", behavior: "instant" });
  var r = el.getBoundingClientRect();
  window.__kitUiEl = el;
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
}`;

// Valor pelo setter nativo e eventos input e change: e o que React, Vue, Angular e Svelte escutam.
// As mensagens nao repetem o valor, que pode ter vindo de variavel de ambiente.
const FILL_SRC = String.raw`function (value) {
  var el = window.__kitUiEl;
  if (!el || !el.isConnected) return "o campo sumiu da página";
  el.focus();
  if (el.isContentEditable) {
    el.textContent = value;
    el.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
    return "";
  }
  var tag = el.tagName;
  if (tag !== "INPUT" && tag !== "TEXTAREA" && tag !== "SELECT") return "não é um campo: <" + tag.toLowerCase() + ">";
  var type = (el.getAttribute("type") || "").toLowerCase();
  if (type === "checkbox" || type === "radio" || type === "file") return "campo do tipo " + type + " não recebe texto; use click";
  var proto = tag === "INPUT" ? HTMLInputElement.prototype : tag === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLSelectElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
  if (tag === "SELECT" && el.value !== value) {
    var hit = -1;
    for (var i = 0; i < el.options.length && hit < 0; i++) if (el.options[i].text.replace(/\s+/g, " ").trim() === value) hit = i;
    if (hit < 0) return "o select não tem essa opção";
    el.selectedIndex = hit;
  }
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  return "";
}`;

function sameOrigin(a, b) {
  try {
    return new URL(a).origin === new URL(b).origin;
  } catch {
    return false;
  }
}

async function runSteps(page, list, ctx, label) {
  for (let i = 0; i < list.length; i++) {
    const s = list[i];
    const ms = Math.min(60000, s.timeout || STEP_MS);
    try {
      if ("wait" in s) {
        if (typeof s.wait === "number") await sleep(Math.min(s.wait, 30000));
        else await page.locate(s.wait, "wait", ms);
        continue;
      }
      if ("goto" in s) {
        const nav = await page.navigate(ctx.join(s.goto));
        if (!nav.ok) throw new Error(nav.error);
        if (nav.status >= 400) throw new Error(`respondeu ${nav.status}`);
      } else if ("click" in s) {
        await page.click(s.click, ms);
      } else if ("hover" in s) {
        const p = await page.locate(s.hover, "hover", ms);
        await page.mouse("mouseMoved", p.x, p.y);
      } else if ("fill" in s) {
        let secret = false;
        const value = s.value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) => {
          secret = true;
          return process.env[name] ?? "";
        });
        if (secret && !sameOrigin(await page.href(), ctx.ui.url)) throw new Error("valor de variável de ambiente só é digitado em página de ui.url");
        await page.fill(s.fill, value, ms);
      } else if ("press" in s) {
        await page.press(s.press);
      } else {
        await page.evaluate(`(async () => { ${s.js}\n})()`);
      }
      await page.calm();
    } catch (e) {
      if (e instanceof Fail || page.cdp.closed) throw e;
      throw new StepFail(`${label} ${i + 1} (${stepText(s)}) falhou: ${String((e && e.message) || e).split("\n")[0]}`);
    }
  }
}

function sweepWidths(viewports, breakpoints) {
  const own = new Set(viewports.map((v) => v.width));
  const near = new Set();
  for (const b of breakpoints) for (const w of [b - 1, b, b + 1]) if (w >= 320 && w <= 2560) near.add(w);
  const base = BASE_WIDTHS.filter((w) => !near.has(w));
  let extra = [...near, ...base].filter((w) => !own.has(w));
  if (extra.length + own.size > MAX_WIDTHS) extra = extra.slice(0, Math.max(0, MAX_WIDTHS - own.size));
  return [...new Set(extra)].sort((a, b) => a - b);
}

function heightFor(width, viewports) {
  let best = viewports[0];
  for (const v of viewports) if (Math.abs(v.width - width) < Math.abs(best.width - width)) best = v;
  return best.height;
}

function ranges(hit, tested) {
  if (hit.length === tested.length) return "";
  const set = new Set(hit);
  const out = [];
  let start = null;
  let prev = null;
  for (const w of tested) {
    if (set.has(w)) {
      if (start === null) start = w;
      prev = w;
    } else if (start !== null) {
      out.push(start === prev ? `${start}` : `${start}–${prev}`);
      start = null;
    }
  }
  if (start !== null) out.push(start === prev ? `${start}` : `${start}–${prev}`);
  return out.join(", ");
}

class Findings {
  constructor() {
    this.map = new Map();
  }

  add(list, width) {
    const seenHere = new Map();
    for (const f of list) {
      const key = `${f.rule}|${f.where}`;
      seenHere.set(key, (seenHere.get(key) || 0) + 1);
      if (!this.map.has(key)) this.map.set(key, { ...f, widths: new Set(), details: new Map(), count: 0 });
      const e = this.map.get(key);
      e.widths.add(width);
      if (!e.details.has(width)) e.details.set(width, f.detail);
      if (f.level === "achado") e.level = "achado";
    }
    for (const [key, n] of seenHere) this.map.get(key).count = Math.max(this.map.get(key).count, n);
  }

  dropWidth(rule, width) {
    for (const [key, e] of this.map) {
      if (e.rule !== rule) continue;
      e.widths.delete(width);
      e.details.delete(width);
      if (!e.widths.size) this.map.delete(key);
    }
  }

  // O detalhe e o da menor largura em que o achado ficou, nao o da primeira em que foi visto.
  // axeWidths: as larguras em que o axe-core rodou, para a faixa das regras dele.
  result(fullWidths, allWidths, axeWidths = fullWidths) {
    const order = { B: 0, M: 1 };
    return [...this.map.values()].map((e) => {
      const widthBound = OVERFLOW_RULES.includes(e.rule) || e.rule === "alvo-pequeno";
      const tested = widthBound ? allWidths : e.rule.startsWith("axe:") ? axeWidths : fullWidths;
      const hit = [...e.widths].sort((a, b) => a - b);
      return { level: e.level, id: e.id, rule: e.rule, where: e.where, detail: e.details.get(hit[0]) ?? e.detail, widths: ranges(hit, tested), count: e.count };
    }).sort((a, b) => (a.level === b.level ? order[a.id[0]] - order[b.id[0]] || a.id.localeCompare(b.id) : a.level === "achado" ? -1 : 1));
  }
}

function slug(route) {
  const s = route.replace(/^[a-z]+:\/\/[^/]+/i, "").replace(/[^A-Za-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
  return s || "raiz";
}

// Nome de arquivo de cada tela. Rotas diferentes com o mesmo slug ("/a/b" e "/a-b") ganham sufixo.
function nameScreens(screens) {
  const used = new Set();
  for (const s of screens) {
    const root = slug(s.label);
    let base = root;
    for (let n = 2; used.has(base); n++) base = `${root}-${n}`;
    used.add(base);
    s.base = base;
  }
}

function warn(screen, text) {
  if (!screen.warnings.includes(text)) screen.warnings.push(text);
}

function samePage(asked, got) {
  try {
    const a = new URL(asked);
    const g = new URL(got);
    const p = (u) => u.pathname.replace(/\/+$/, "");
    return a.origin === g.origin && p(a) === p(g) && (!a.hash || a.hash === g.hash);
  } catch {
    return true;
  }
}

// O que rola na tela: o documento ou, em app com o corpo fixo, o conteiner com rolagem que ocupa a maior
// parte dela (fica em window.__kitUiScroll). Devolve a altura do conteudo e a da area visivel.
const SCROLL_SRC = `(() => {
  const vh = window.innerHeight;
  const docH = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
  window.__kitUiScroll = null;
  if (docH > vh + 4) return { h: docH, v: vh };
  let best = null;
  let area = 0;
  const all = document.querySelectorAll("body *");
  for (let i = 0; i < all.length && i < 6000; i++) {
    const el = all[i];
    if (el.scrollHeight - el.clientHeight < 40) continue;
    const oy = getComputedStyle(el).overflowY;
    if (oy !== "auto" && oy !== "scroll") continue;
    const r = el.getBoundingClientRect();
    const a = Math.max(0, Math.min(r.right, window.innerWidth) - Math.max(r.left, 0)) * Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0));
    if (a > area) {
      area = a;
      best = el;
    }
  }
  if (!best || area < window.innerWidth * vh * 0.4) return { h: docH, v: vh };
  window.__kitUiScroll = best;
  return { h: best.scrollHeight, v: best.clientHeight };
})()`;

// Fotografa a tela em ate max partes, de cima para baixo. cut(total, feitas) e chamado quando a tela tem
// mais partes do que as fotografadas.
async function tiles(page, outDir, base, vp, max, cut) {
  const images = [];
  const dims = await page.evaluate(SCROLL_SRC);
  // A janela volta sempre para a esquerda e para o topo: um passo de --steps pode ter rolado a pagina.
  const scrollTo = (y) => page.evaluate(`(() => {
    const inner = window.__kitUiScroll;
    window.scrollTo({ top: inner ? 0 : ${y}, left: 0, behavior: "instant" });
    if (inner) inner.scrollTo({ top: ${y}, left: 0, behavior: "instant" });
  })()`);
  const maxScroll = Math.max(0, dims.h - dims.v);
  const ys = [];
  for (let i = 0; i < max; i++) {
    const y = Math.min(i * dims.v, maxScroll);
    if (ys.length && y <= ys[ys.length - 1]) break;
    ys.push(y);
  }
  for (let i = 0; i < ys.length; i++) {
    await scrollTo(ys[i]);
    await page.settle(ys.length > 1 ? 200 : 50);
    const file = `${base}-${vp.label}-${i + 1}.png`;
    await page.screenshot(path.join(outDir, file));
    images.push({ file, viewport: vp.label, part: i + 1, parts: ys.length });
  }
  if (ys.length > 1) await scrollTo(0);
  const total = dims.v > 0 ? Math.ceil((dims.h - 4) / dims.v) : 1;
  if (cut && total > ys.length) cut(total, ys.length);
  return images;
}

function axePath(root) {
  let dir = root;
  for (let i = 0; i < 4; i++) {
    const p = path.join(dir, "node_modules", "axe-core", "axe.min.js");
    if (firstExisting([p])) return p;
    const up = path.dirname(dir);
    if (up === dir) break;
    dir = up;
  }
  return "";
}

const AXE_SKIP = new Set(["color-contrast", "image-alt", "html-has-lang", "document-title", "meta-viewport", "target-size", "button-name", "link-name", "label"]);
// Regras do axe que tratam de nome acessivel ou de uso pelo teclado (B3 do revisor). As outras sao de estrutura (M8).
const AXE_B3 = new Set([
  "aria-command-name", "aria-input-field-name", "aria-toggle-field-name", "input-button-name", "select-name", "summary-name",
  "nested-interactive", "scrollable-region-focusable", "frame-focusable-content", "aria-hidden-focus",
]);
async function runAxe(page, source) {
  const res = await page.evaluate(`(async () => { ${source}
    const r = await axe.run(document, { resultTypes: ["violations"] });
    return r.violations.map(v => ({ id: v.id, impact: v.impact || "", help: v.help, url: v.helpUrl, n: v.nodes.length, target: String((v.nodes[0] && v.nodes[0].target) || "") }));
  })()`);
  return (res || []).filter((v) => !AXE_SKIP.has(v.id)).map((v) => ({
    rule: `axe:${v.id}`, id: AXE_B3.has(v.id) ? "B3" : "M8", level: v.impact === "critical" || v.impact === "serious" ? "achado" : "conferir",
    where: v.target || "página", detail: `${v.help} (${v.n} ${v.n === 1 ? "elemento" : "elementos"}) ${v.url}`,
  }));
}

// Liga o tema escuro na raiz e no body: "class:<nome>" ou "attr:<nome>" (valor dark).
const DARK_ON_SRC = `function (toggles) {
  toggles.forEach(function (t) {
    var cut = t.indexOf(":");
    var name = t.slice(cut + 1);
    [document.documentElement, document.body].forEach(function (el) {
      if (!el) return;
      if (t.slice(0, cut) === "class") el.classList.add(name);
      else el.setAttribute(name, "dark");
    });
  });
}`;

async function captureScreen(page, ctx, screen) {
  const { ui, args, probe, outDir } = ctx;
  const found = new Findings();
  const fullWidths = ui.viewports.map((v) => v.width);
  const probeAt = async (full, breakpoints, only, style) => {
    const r = await page.evaluate(`(${probe})(${JSON.stringify({ full, breakpoints, only, style })})`);
    if (!r || r.error) screen.incomplete ||= `sondagem falhou: ${r ? String(r.error).split("\n")[0] : "sem resultado"}`;
    return r || { findings: [] };
  };
  const overflows = (r) => r.findings.some((f) => OVERFLOW_RULES.includes(f.rule));
  const base = screen.base;
  const steps = ctx.steps ? ctx.steps.steps : [];
  const axeWidths = [...new Set([ui.viewports[0].width, ui.viewports[ui.viewports.length - 1].width])];
  const toggles = new Set();
  let breakpoints = [];
  let reachable = true;
  let darkAware = false;

  for (const vp of ui.viewports) {
    await page.setViewport(vp.width, vp.height);
    if (screen.url) {
      const nav = await page.navigate(screen.url);
      if (!nav.ok) {
        screen.findings.push({ level: "achado", id: "M9", rule: "nao-carregou", where: "página", detail: `${screen.url}: ${nav.error}`, widths: "", count: 1 });
        reachable = false;
        break;
      }
      if (nav.status >= 400) {
        screen.findings.push({ level: "achado", id: "M9", rule: "nao-carregou", where: "página", detail: `${screen.url} respondeu ${nav.status}`, widths: "", count: 1 });
        if (!args.probeOnly) screen.images.push(...(await tiles(page, outDir, base, vp, 1)));
        reachable = false;
        break;
      }
      if (nav.timedOut) warn(screen, `o carregamento não terminou em ${Math.round(LOAD_MS / 1000)}s em ${vp.label}`);
      let at = nav.finalUrl;
      if (steps.length) {
        try {
          await runSteps(page, steps, ctx, "passo");
        } catch (e) {
          // A imagem de onde o passo parou ajuda a corrigir o seletor.
          if (e instanceof StepFail && !args.probeOnly) {
            try {
              screen.images.push(...(await tiles(page, outDir, `${base}-falha`, vp, 1)));
            } catch { /* sem imagem */ }
          }
          throw e;
        }
        at = await page.href();
      }
      if (at && !samePage(screen.url, at)) {
        screen.final_url = at;
        if (!steps.length) warn(screen, `a rota redirecionou para ${at}: o que foi medido é essa página, não ${screen.route}`);
      }
      for (const d of page.dialogs) warn(screen, `a página abriu um diálogo (${d}); a captura o fechou para seguir`);
    }
    // Estilo so no maior tamanho: e o que vai para o relatorio.
    const r = await probeAt(true, true, undefined, vp === ui.viewports[ui.viewports.length - 1]);
    if (r.dark) darkAware = true;
    for (const t of r.darkToggles || []) toggles.add(t);
    found.add(r.findings, vp.width);
    breakpoints = [...new Set([...breakpoints, ...(r.breakpoints || [])])];
    if (r.title && !screen.title) screen.title = r.title;
    if (r.style) screen.style = { width: vp.width, ...r.style };
    for (const c of page.console) if (!screen.console.includes(c)) screen.console.push(c);
    for (const n of page.network) if (!screen.network.includes(n)) screen.network.push(n);
    if (ctx.axe && (vp === ui.viewports[0] || vp === ui.viewports[ui.viewports.length - 1])) {
      try {
        found.add(await runAxe(page, ctx.axe), vp.width);
      } catch (e) {
        warn(screen, `axe-core falhou: ${e.message.split("\n")[0]}`);
      }
    }
    if (!args.probeOnly) {
      screen.images.push(...(await tiles(page, outDir, base, vp, args.tiles, (total, shot) => {
        warn(screen, `em ${vp.label} a tela tem ${total} alturas de rolagem e só as ${shot} primeiras foram fotografadas (--tiles aceita até 6)`);
      })));
    }
  }

  if (!reachable) return;
  screen.breakpoints = breakpoints.sort((a, b) => a - b);
  const extra = sweepWidths(ui.viewports, breakpoints);
  const allWidths = [...new Set([...fullWidths, ...extra])].sort((a, b) => a - b);
  ctx.widths = allWidths;
  const suspect = [];
  for (const w of [...extra].reverse()) {
    if (Date.now() - STARTED > BUDGET_MS) {
      screen.incomplete ||= "tempo esgotado: nem todas as larguras foram percorridas";
      break;
    }
    await page.setViewport(w, heightFor(w, ui.viewports));
    const r = await probeAt(false, false);
    found.add(r.findings, w);
    if (overflows(r)) suspect.push(w);
  }
  // Largura trocada sem recarregar pode acusar o que a pagina nao tem quando abre naquele tamanho
  // (elemento dimensionado por script na carga). Cada suspeita e conferida com recarga.
  if (screen.url && suspect.length) {
    const sorted = [...suspect].sort((a, b) => a - b);
    const order = [...new Set([sorted[0], sorted[sorted.length - 1], ...sorted])];
    const until = Date.now() + CONFIRM_MS;
    let kept = 0;
    let clean = 0;
    let left = [];
    for (let i = 0; i < order.length; i++) {
      const w = order[i];
      if (Date.now() > until || Date.now() - STARTED > BUDGET_MS) {
        left = order.slice(i);
        break;
      }
      await page.setViewport(w, heightFor(w, ui.viewports));
      const nav = await page.navigate(screen.url);
      if (!nav.ok) {
        left = order.slice(i);
        break;
      }
      if (steps.length) await runSteps(page, steps, ctx, "passo");
      const r = await probeAt(false, false);
      for (const rule of OVERFLOW_RULES) {
        if (!r.findings.some((f) => f.rule === rule)) found.dropWidth(rule, w);
      }
      if (overflows(r)) kept++;
      else clean++;
    }
    if (left.length && clean && !kept) {
      for (const w of left) for (const rule of OVERFLOW_RULES) found.dropWidth(rule, w);
    } else if (left.length) {
      warn(screen, `rolagem horizontal sem conferência com recarga em ${left.join(", ")}px`);
    }
  }
  screen.findings.push(...found.result(fullWidths, allWidths, axeWidths));
  const off = directionFinding(ui, screen.style);
  if (off) screen.findings.push(off);
  // Tema escuro: pela media query do CSS (certo) ou, sem ela, pela classe ou pelo atributo de tema que as
  // regras do CSS usam (.dark, [data-theme=dark]). No segundo caso quem liga o tema e a captura, entao o
  // contraste sai como conferir.
  const byClass = darkAware ? [] : [...toggles].slice(0, 4);
  if (screen.url && ctx.scheme && (darkAware || byClass.length)) {
    const dark = new Findings();
    const ends = [...new Set([ui.viewports[0], ui.viewports[ui.viewports.length - 1]])];
    if (darkAware) await page.colorScheme("dark");
    for (const vp of ends) {
      await page.setViewport(vp.width, vp.height);
      const nav = await page.navigate(screen.url);
      if (!nav.ok) break;
      if (steps.length) await runSteps(page, steps, ctx, "passo");
      if (byClass.length) {
        await page.evaluate(`(${DARK_ON_SRC})(${JSON.stringify(byClass)})`);
        await page.settle(400);
      }
      const r = await probeAt(true, false, ["contraste"]);
      dark.add(r.findings, vp.width);
      if (!args.probeOnly) {
        const shots = await tiles(page, outDir, `${base}-escuro`, vp, 1);
        screen.images.push(...shots.map((i) => ({ ...i, theme: "escuro" })));
      }
    }
    if (darkAware) await page.colorScheme("light");
    for (const f of dark.result(ends.map((v) => v.width), allWidths)) {
      screen.findings.push({ ...f, rule: `${f.rule} (tema escuro)`, ...(byClass.length ? { level: "conferir" } : {}) });
    }
    screen.dark = true;
    if (byClass.length) screen.dark_by = byClass.map((t) => (t.startsWith("class:") ? `.${t.slice(6)}` : `[${t.slice(5)}=dark]`)).join(", ");
  }
  for (const c of screen.console) screen.findings.push({ level: "achado", id: "M9", rule: "console", where: "página", detail: c, widths: "", count: 1 });
  for (const n of screen.network) {
    // Na pasta servida (amostra), fonte ou estilo de CDN que nao veio e falta de rede, nao defeito da tela.
    const target = n.slice(n.lastIndexOf(" ") + 1);
    if (ctx.served && /^https?:\/\//i.test(target) && !sameOrigin(target, ui.url)) {
      warn(screen, `recurso externo não carregou (sem rede ou CDN fora do ar; a tipografia mostrada pode ser a de reserva): ${n}`);
      continue;
    }
    screen.findings.push({ level: "achado", id: "M9", rule: "requisicao", where: "página", detail: n, widths: "", count: 1 });
  }
}

// {out}, {url} e {route} entram no comando ja entre aspas simples, com ou sem aspas em volta no kit.json
// ("{out}" e {out} dao no mesmo). Os mesmos valores vao em KIT_UI_OUT, KIT_UI_URL, KIT_UI_ROUTE, KIT_UI_WIDTH
// e KIT_UI_HEIGHT, para o comando que precisa deles no meio de outro texto.
function runCommandShots(ui, args, outDir, screens) {
  const sized = /\{(width|height)\}|KIT_UI_(WIDTH|HEIGHT)/.test(ui.screenshot);
  const quote = (s) => `'${String(s).replace(/'/g, "'\\''")}'`;
  for (const screen of screens) {
    const base = screen.base;
    for (const vp of sized ? ui.viewports : [null]) {
      const file = vp ? `${base}-${vp.label}-1.png` : `${base}-1.png`;
      const full = path.join(outDir, file);
      const vals = {
        out: full.split(path.sep).join("/"), url: screen.url || "", route: screen.route,
        width: vp ? String(vp.width) : "", height: vp ? String(vp.height) : "",
      };
      const cmd = ui.screenshot.replace(/(["']?)\{(out|url|route|width|height)\}\1/g, (_, q, k) => (k === "width" || k === "height" ? vals[k] : quote(vals[k])));
      const env = { ...process.env, KIT_UI_OUT: vals.out, KIT_UI_URL: vals.url, KIT_UI_ROUTE: vals.route, KIT_UI_WIDTH: vals.width, KIT_UI_HEIGHT: vals.height };
      const r = spawnSync(process.env.KIT_BASH || "bash", ["-c", cmd], { cwd: ui.root, env, encoding: "utf8", timeout: 120000, windowsHide: true });
      if (r.status === 0 && firstExisting([full])) {
        screen.images.push({ file, viewport: vp ? vp.label : "", part: 1, parts: 1 });
      } else {
        const why = ((r.stderr || "") + (r.stdout || "")).trim().split(/\r?\n/).slice(-2).join(" ") || `código ${r.status}`;
        screen.warnings.push(`ui.screenshot não gravou ${file}: ${why}`);
      }
    }
  }
}

function summary(report, outDir) {
  const lines = [];
  const srv = { iniciado: "app iniciado por ui.dev", "ja-rodando": "app já estava rodando", nenhum: "sem ui.url", pasta: `pasta ${report.served} servida pelo kit` }[report.server];
  const head = [`captura: ${report.mode}${report.browser ? ` (${report.browser})` : ""}`];
  if (report.mode !== "navegador aberto") head.push(srv);
  head.push(`${report.screens.length} ${report.screens.length === 1 ? "tela" : "telas"}`);
  if (report.widths.length) head.push(`${report.widths.length} larguras (${report.widths[0]}–${report.widths[report.widths.length - 1]}px)`);
  if (report.viewports.length && report.mode !== "comando") head.push(`imagens em ${report.viewports.join(", ")}`);
  if (report.steps) head.push(`passos: ${report.steps.setup ? `${report.steps.setup} de preparo, ` : ""}${report.steps.steps} por carga`);
  lines.push(head.join(" · "));
  for (const s of report.screens) {
    const dark = s.dark ? `, tema claro e escuro${s.dark_by ? ` (ligado por ${s.dark_by})` : ""}` : "";
    lines.push(`${s.route}${s.final_url ? ` → ${s.final_url}` : ""}${s.title ? ` — ${s.title}` : ""}: ${s.images.length} ${s.images.length === 1 ? "imagem" : "imagens"}${s.breakpoints.length ? `, quebras do CSS em ${s.breakpoints.join(", ")}px` : ""}${dark}`);
    for (const f of s.findings.slice(0, 14)) {
      lines.push(`  ${f.level} [${f.id}] ${f.rule}${f.widths ? ` em ${f.widths}px` : ""}: ${f.where !== "página" ? `${f.where}${f.count > 1 ? ` (${f.count})` : ""} — ` : ""}${f.detail}`);
    }
    if (s.findings.length > 14) lines.push(`  ... mais ${s.findings.length - 14} no relatório`);
    if (s.incomplete) lines.push(`  incompleta: ${s.incomplete}`);
    else if (!s.findings.length && report.mode !== "comando") lines.push("  sem achados na sondagem");
    for (const w of s.warnings) lines.push(`  aviso: ${w}`);
  }
  lines.push(`relatório: ${rel(path.join(outDir, "report.json"))}${report.totals.images ? ` · imagens: ${rel(outDir)}/` : ""}`);
  const n = report.totals.incomplete;
  lines.push(report.mode === "comando" ? `resultado: ${report.totals.images} imagens, sem sondagem (captura pelo comando do projeto)`
    : `resultado: ${report.totals.findings} achados, ${report.totals.check} a conferir${n ? `, ${n} ${n === 1 ? "tela" : "telas"} sem sondagem completa` : ""}`);
  return lines.join("\n");
}

// Pasta do kit (.claude/state/ui/<nome>): sai toda imagem da rodada anterior. Pasta dada por --out pode
// ter arquivo de outra origem: sai so o que o report.json anterior lista.
function prepareOut(dir, own) {
  fs.mkdirSync(dir, { recursive: true });
  const old = new Set(["report.json", "dev.log"]);
  try {
    const prev = JSON.parse(fs.readFileSync(path.join(dir, "report.json"), "utf8"));
    for (const s of prev.screens || []) for (const i of s.images || []) if (typeof i.file === "string") old.add(path.basename(i.file));
  } catch { /* sem relatorio anterior */ }
  for (const f of fs.readdirSync(dir)) {
    if (old.has(f) || (own && /\.png$/.test(f))) fs.rmSync(path.join(dir, f), { force: true });
  }
}

function doctor() {
  const b = findBrowser();
  console.log(b ? `navegador: ok ${b.name} (${b.path.split(path.sep).join("/")})` : "navegador: ausente");
  console.log(`websocket: ${typeof WebSocket === "undefined" ? "ausente" : "ok"}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.doctor) {
    doctor();
    return 0;
  }
  let ui = loadUi(args.kit);
  const outDir = path.resolve(args.out || path.join(ui.root, ".claude", "state", "ui", args.name));
  // --serve: o endereco e o do servidor da pasta; ui.url, ui.dev, ui.screenshot e ui.routes ficam de fora.
  let served = null;
  if (args.serve) {
    served = await serveDir(args.serve);
    cleanups.push(served.close);
    ui = { ...ui, url: served.url, dev: "", screenshot: "" };
  }
  const routes = served ? serveRoutes(served.root, args.routes) : args.routes || ui.routes;
  // Rota com endereco inteiro so por http ou https: file:, chrome: e parecidos nao sao tela do app.
  const join = (r) => {
    if (/^[a-z][a-z0-9+.-]*:/i.test(r)) {
      if (!/^https?:\/\//i.test(r)) throw new Fail(2, `ui: rota "${r}" precisa ser um caminho do app ou um endereço http(s)`);
      return r;
    }
    if (served) return ui.url + "/" + encodeURI(r.replace(/^\/+/, ""));
    return ui.url ? ui.url + (r.startsWith("/") ? r : "/" + r) : "";
  };
  const plan = args.steps ? loadSteps(args.steps) : null;
  const screens = (args.attach ? [args.name] : routes).map((r) => ({
    route: r, label: r, url: args.attach ? "" : join(r), title: "", images: [], breakpoints: [], findings: [], console: [], network: [], warnings: [],
  }));
  nameScreens(screens);
  const report = {
    version: 1, captured_at: new Date().toISOString(), mode: "", browser: "", url: ui.url, server: "nenhum",
    viewports: ui.viewports.map((v) => v.label), widths: [], screens, totals: { findings: 0, check: 0, images: 0, incomplete: 0 },
  };
  if (served) {
    report.server = "pasta";
    report.served = rel(served.root);
  }
  if (plan) {
    for (const s of [...plan.setup, ...plan.steps]) if ("goto" in s) join(s.goto);
    report.steps = { setup: plan.setup.length, steps: plan.steps.length };
  }
  const firstLine = (e) => String((e && e.message) || e).split("\n")[0];
  // Erro numa tela nao leva as outras junto: ela fica marcada como incompleta e o relatorio sai.
  // Devolve false quando a pagina pode ter ficado presa (erro que nao e de passo).
  const capture = async (page, ctx, screen) => {
    try {
      await captureScreen(page, ctx, screen);
      screen.done = true;
      return true;
    } catch (e) {
      if (e instanceof Fail) throw e;
      screen.incomplete = e instanceof StepFail ? e.message : `captura interrompida: ${firstLine(e)}`;
      return e instanceof StepFail;
    }
  };
  let crash = "";

  if (ui.screenshot && !args.attach) {
    report.mode = "comando";
    if (args.probeOnly) throw new Fail(3, "ui: captura pelo comando ui.screenshot não tem sondagem; rode sem --probe-only");
    if (plan) throw new Fail(2, "ui: --steps vale para a captura no navegador, não para o comando ui.screenshot");
    prepareOut(outDir, !args.out);
    report.server = (await ensureApp(ui, outDir)).state;
    runCommandShots(ui, args, outDir, screens);
  } else if (args.attach) {
    report.mode = "navegador aberto";
    prepareOut(outDir, !args.out);
    const br = await attachBrowser(args.attach, args.match);
    cleanups.push(br.close);
    report.url = br.pageUrl;
    screens[0].route = `${args.name} (${br.pageUrl})`;
    try {
      const page = new Page(br.cdp, undefined);
      for (const d of ["Page", "Runtime", "Network"]) await page.send(`${d}.enable`);
      const before = await page.evaluate("({ w: window.innerWidth, h: window.innerHeight })");
      const ctx = { ui, args, probe: fs.readFileSync(path.join(HERE, "ui-probe.js"), "utf8"), outDir, widths: [], axe: "" };
      const ax = axePath(ui.root);
      if (ax) ctx.axe = fs.readFileSync(ax, "utf8");
      await sleep(300);
      await capture(page, ctx, screens[0]);
      report.widths = ctx.widths;
      try {
        await page.send("Emulation.setDeviceMetricsOverride", { width: before.w, height: before.h, deviceScaleFactor: 1, mobile: false });
      } catch { /* pagina fechada */ }
    } catch (e) {
      if (e instanceof Fail) throw e;
      crash = firstLine(e);
    }
  } else {
    if (!ui.url) throw new Fail(2, 'ui: kit.json sem "ui.url"; sem endereço não há o que abrir');
    const browser = findBrowser();
    if (!browser) throw new Fail(3, "ui: nenhum navegador Chromium encontrado (Chrome, Edge ou Chromium); sem captura");
    report.mode = "navegador";
    prepareOut(outDir, !args.out);
    if (!served) report.server = (await ensureApp(ui, outDir)).state;
    const br = await openBrowser(browser, ui);
    cleanups.push(br.close);
    report.browser = `${browser.name} ${br.version.split(".")[0]}`.trim();
    const openPage = async () => {
      const { targetId } = await br.cdp.send("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await br.cdp.send("Target.attachToTarget", { targetId, flatten: true });
      const p = new Page(br.cdp, sessionId);
      p.targetId = targetId;
      for (const d of ["Page", "Runtime", "Network"]) await p.send(`${d}.enable`);
      await p.colorScheme("light");
      return p;
    };
    try {
      let page = await openPage();
      const ctx = { ui, args, probe: fs.readFileSync(path.join(HERE, "ui-probe.js"), "utf8"), outDir, widths: [], axe: "", scheme: true, steps: plan, join, served: !!served };
      const ax = axePath(ui.root);
      if (ax) ctx.axe = fs.readFileSync(ax, "utf8");
      // Preparo (login, dado de teste): uma vez por aba, antes das rotas. Se falha, nenhuma tela esta no estado pedido.
      let setupError = "";
      const setup = async () => {
        if (!plan || !plan.setup.length || setupError) return;
        const vp = ui.viewports[0];
        try {
          await page.setViewport(vp.width, vp.height);
          await runSteps(page, plan.setup, ctx, "preparo");
        } catch (e) {
          if (!(e instanceof StepFail)) throw e;
          setupError = e.message;
          if (!args.probeOnly) {
            try {
              screens[0].images.push(...(await tiles(page, outDir, "preparo-falha", vp, 1)));
            } catch { /* sem imagem */ }
          }
        }
      };
      await setup();
      for (const screen of screens) {
        if (setupError) {
          screen.incomplete = setupError;
          continue;
        }
        if (Date.now() - STARTED > BUDGET_MS) {
          screen.incomplete = "tempo esgotado: tela não capturada; rode a captura só com esta rota";
          continue;
        }
        if (!(await capture(page, ctx, screen))) {
          // A pagina pode ter ficado presa: a proxima tela abre numa aba nova, com o preparo refeito.
          await Promise.race([br.cdp.send("Target.closeTarget", { targetId: page.targetId }).catch(() => {}), sleep(5000)]);
          page = await openPage();
          await setup();
        }
        report.widths = [...new Set([...report.widths, ...ctx.widths])].sort((a, b) => a - b);
      }
    } catch (e) {
      if (e instanceof Fail) throw e;
      crash = firstLine(e);
    }
  }

  for (const s of screens) {
    if (crash && report.mode !== "comando" && !s.done && !s.incomplete) s.incomplete = `não capturada: ${crash}`;
    if (s.incomplete) report.totals.incomplete++;
    report.totals.images += s.images.length;
    report.totals.findings += s.findings.filter((f) => f.level === "achado").length;
    report.totals.check += s.findings.filter((f) => f.level === "conferir").length;
    delete s.label;
    delete s.url;
    delete s.base;
    delete s.done;
  }
  fs.writeFileSync(path.join(outDir, "report.json"), JSON.stringify(report, null, 2) + "\n");
  console.log(summary(report, outDir));
  if (crash) {
    console.error(`ui: erro na captura: ${crash}`);
    return 5;
  }
  if (report.mode === "comando" && !report.totals.images) return 3;
  return report.totals.findings ? 1 : report.totals.incomplete ? 5 : 0;
}

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, async () => {
    await cleanup();
    process.exit(130);
  });
}

process.on("unhandledRejection", async (e) => {
  console.error(`ui: erro na captura: ${(e && e.message) || e}`);
  await cleanup();
  process.exit(5);
});

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let code;
  try {
    code = await main();
  } catch (e) {
    if (e instanceof Fail) {
      console.error(e.message);
      code = e.code;
    } else {
      console.error(`ui: erro na captura: ${(e && e.message) || e}`);
      code = 5;
    }
  }
  await cleanup();
  process.exit(code);
}
