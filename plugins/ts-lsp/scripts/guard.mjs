// Sobe o typescript-language-server (--stdio) repassando stdin/stdout e confere a memória da árvore
// dele (language server + tsservers) a cada KIT_TS_LSP_INTERVAL_S segundos (padrão 30). Passou de
// KIT_TS_LSP_MAX_MB (padrão 6144), mata a árvore e sai com 1: o Claude Code trata como crash e sobe
// outro servidor no próximo pedido. Memória: bytes privados no Windows, RSS no Linux/macOS.
// stdout é do protocolo LSP; mensagens do guard vão só para o stderr. KIT_TS_LSP_SERVER troca o
// servidor (arquivo .js/.cjs/.mjs roda com o node atual), para os testes.
import { spawn, execFile } from 'node:child_process';

const win = process.platform === 'win32';
const limitMb = Number(process.env.KIT_TS_LSP_MAX_MB) || 6144;
const intervalMs = (Number(process.env.KIT_TS_LSP_INTERVAL_S) || 30) * 1000;
const server = process.env.KIT_TS_LSP_SERVER || 'typescript-language-server';

const script = /\.[cm]?js$/.test(server);

const child = spawn(script ? process.execPath : server, script ? [server, '--stdio'] : ['--stdio'], {
  stdio: ['pipe', 'pipe', 'inherit'],
  shell: win && !script,
  detached: !win,
  windowsHide: true,
});

let stopping = false;
let timer;

function killTree() {
  if (win) {
    execFile('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }, () => {});
  } else {
    try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch {} }
  }
}

function stop(code) {
  if (stopping) return;
  stopping = true;
  clearInterval(timer);
  process.exitCode = code;
  killTree();
  setTimeout(() => process.exit(code), 500);
}

// Linhas "pid ppid bytes" de todos os processos.
function snapshot() {
  return new Promise((resolve) => {
    const done = (err, out) => resolve(err ? '' : String(out));
    if (win) {
      execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
        'Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,PrivatePageCount | ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId) $($_.PrivatePageCount)" }'],
      { windowsHide: true, maxBuffer: 16 * 1024 * 1024, timeout: 20000 }, done);
    } else {
      execFile('ps', ['-A', '-o', 'pid=,ppid=,rss='], { maxBuffer: 16 * 1024 * 1024, timeout: 20000 },
        (err, out) => done(err, err ? '' : String(out).split('\n').map((l) => {
          const [pid, ppid, kb] = l.trim().split(/\s+/);
          return pid ? `${pid} ${ppid} ${Number(kb) * 1024}` : '';
        }).join('\n')));
    }
  });
}

function treeBytes(text, root) {
  const kids = new Map();
  const mem = new Map();
  for (const line of text.split(/\r?\n/)) {
    const [pid, ppid, bytes] = line.trim().split(/\s+/).map(Number);
    if (!pid) continue;
    mem.set(pid, bytes || 0);
    if (!kids.has(ppid)) kids.set(ppid, []);
    kids.get(ppid).push(pid);
  }
  let total = 0;
  const seen = new Set();
  const queue = [root];
  while (queue.length) {
    const pid = queue.pop();
    if (seen.has(pid)) continue;
    seen.add(pid);
    total += mem.get(pid) || 0;
    for (const k of kids.get(pid) || []) queue.push(k);
  }
  return total;
}

async function check() {
  if (stopping) return;
  const mb = Math.round(treeBytes(await snapshot(), child.pid) / 1048576);
  if (mb > limitMb && !stopping) {
    process.stderr.write(`ts-lsp: language server com ${mb} MB (limite ${limitMb} MB); reiniciando\n`);
    stop(1);
  }
}

process.stdin.pipe(child.stdin);
child.stdout.pipe(process.stdout);
child.stdin.on('error', () => {});
process.stdin.on('end', () => child.stdin.end());
child.on('error', (err) => {
  process.stderr.write(`ts-lsp: não consegui iniciar ${server}: ${err.message}\n`);
  stop(1);
});
child.on('exit', (code) => {
  if (stopping) return;
  stopping = true;
  clearInterval(timer);
  process.exit(code ?? 1);
});
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => stop(0));

timer = setInterval(check, intervalMs);
timer.unref();
