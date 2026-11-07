'use strict';
/**
 * qemu-interaction-bridge.cjs — pont AI OS (exécuté sur le runner).
 *
 * Deux visages, un seul tunnel :
 *   /                      bureau interactif (noVNC proxy vers l'invité)
 *   /websockify            flux VNC WebSocket (proxy)
 *   /api/linux/*, /api/v1/* API d'interaction (jeton Bearer — usage Worker)
 *   /health                sonde du pont
 *
 * Le Bureau est protégé par une « autorisation » portée par :
 *   ?s=<exp>.<hmac>        jeton signé HMAC-SHA256 (délivré par le Worker)
 *   ?tok=<VM_API_TOKEN>    jeton brut (usage machine)
 *   cookie aios_s          mémorisation de l'autorisation
 *   Authorization: Basic  utilisateur quelconque, mot de passe = VM_API_TOKEN
 *
 * Modèle de sécurité (à ne jamais dégrader) :
 *  - API : jeton long (VM_API_TOKEN, ≥ 32 car.), comparaison à temps constant.
 *  - Aucune interpolation shell côté runner : spawn('ssh', [...]) + scripts
 *    invités par stdin (bash -s), données en base64 strict, listes blanches.
 *  - Chaque réponse API porte X-Linux-Daemon: 1 (le Worker en dépend).
 */
const http = require('http');
const net = require('net');
const { spawn } = require('child_process');
const crypto = require('crypto');

const secret = process.env.VM_API_TOKEN || '';
if (secret.length < 32) throw new Error('VM_API_TOKEN absent ou trop court (≥ 32 caractères requis)');

const HOST = process.env.AIOS_BRIDGE_HOST || '127.0.0.1';
const PORT = Number(process.env.AIOS_BRIDGE_PORT || 3001);
const VNC_UPSTREAM = Number(process.env.AIOS_VNC_UPSTREAM_PORT || 6080);
const SSH_KEY = process.env.AIOS_SSH_KEY || '';
const KNOWN_HOSTS = process.env.AIOS_KNOWN_HOSTS || '';
const SSH_PORT = process.env.AIOS_SSH_PORT || '22222';
const GUEST_USER = process.env.AIOS_GUEST_USER || 'aios';
const GUEST_HOME = process.env.AIOS_GUEST_HOME || `/home/${GUEST_USER}`;
const DISPLAY = process.env.AIOS_GUEST_DISPLAY || ':99';
if (!SSH_KEY) throw new Error('AIOS_SSH_KEY absent');
if (!/^:[0-9]+$/.test(DISPLAY)) throw new Error('AIOS_GUEST_DISPLAY invalide');

const MAX_BODY = 8 * 1024 * 1024;
const MAX_TEXT_OUT = 2 * 1024 * 1024;
const MAX_FILE = 5 * 1024 * 1024;
const MAX_SCREENSHOT = 15 * 1024 * 1024;

function send(res, status, obj, extraHeaders) {
  const body = Buffer.from(JSON.stringify(obj, null, 2));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Linux-Daemon': '1',
    ...(extraHeaders || {}),
  });
  res.end(body);
}
function fail(res, status, error) { send(res, status, { ok: false, error }); }
function b64(s) { return Buffer.from(s, 'utf8').toString('base64'); }

// ---------------------------------------------------------------------------
// Autorisation du bureau (jeton signé HMAC, jeton brut, cookie, Basic)
// ---------------------------------------------------------------------------
function verifyGrant(value) {
  if (typeof value !== 'string' || !value) return false;
  if (value === secret) return true; // jeton brut
  const m = value.match(/^(\d{10})\.([a-f0-9]{64})$/);
  if (!m) return false;
  const exp = Number(m[1]);
  if (!Number.isFinite(exp) || exp < Math.floor(Date.now() / 1000)) return false;
  const expected = crypto.createHmac('sha256', secret).update(String(exp)).digest('hex');
  const a = Buffer.from(expected), b = Buffer.from(m[2]);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function parseCookies(header) {
  const out = {};
  for (const part of String(header || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function desktopAuthorized(req) {
  const url = new URL(req.url, 'http://x');
  if (verifyGrant(url.searchParams.get('s'))) return true;
  if (verifyGrant(url.searchParams.get('tok'))) return true;
  if (verifyGrant(parseCookies(req.headers.cookie).aios_s)) return true;
  const auth = String(req.headers.authorization || '');
  const basic = auth.match(/^Basic\s+(.+)$/i);
  if (basic) {
    const decoded = Buffer.from(basic[1], 'base64').toString('utf8');
    const i = decoded.indexOf(':');
    if (i >= 0 && verifyGrant(decoded.slice(i + 1))) return true;
  }
  return false;
}

const APP_URL = process.env.AIOS_APP_URL || 'https://jeanhug.github.io/AI-OS/app/';

// ---------------------------------------------------------------------------
// Commandes invitées via ssh + stdin (aucun shell côté runner)
// ---------------------------------------------------------------------------
function runGuest(script, { timeoutMs = 30000, maxOut = MAX_TEXT_OUT } = {}) {
  return new Promise((resolve) => {
    const args = [
      '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=accept-new',
      '-o', `UserKnownHostsFile=${KNOWN_HOSTS}`, '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=10', '-p', SSH_PORT,
      `${GUEST_USER}@127.0.0.1`, 'bash', '-s',
    ];
    const child = spawn('ssh', args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let out = [], err = [], outSize = 0, errSize = 0, killed = false;
    const timer = setTimeout(() => { killed = true; child.kill('SIGKILL'); }, timeoutMs);
    child.stdout.on('data', (d) => { outSize += d.length; if (outSize <= maxOut) out.push(d); else { killed = true; child.kill('SIGKILL'); } });
    child.stderr.on('data', (d) => { errSize += d.length; if (errSize <= 256 * 1024) err.push(d); });
    child.on('error', () => { clearTimeout(timer); resolve({ code: -1, stdout: '', stderr: 'ssh failure' }); });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code: killed ? -2 : (code === null ? -1 : code), stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8') });
    });
    child.stdin.on('error', () => {});
    child.stdin.end(script);
  });
}

function guestPath(raw) {
  if (typeof raw !== 'string' || !raw) return null;
  const p = require('path').posix.resolve(raw);
  if (p !== GUEST_HOME && !p.startsWith(GUEST_HOME + '/')) return null;
  return p;
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on('data', (d) => { size += d.length; if (size > MAX_BODY) { reject(new Error('body too large')); req.destroy(); return; } chunks.push(d); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}
const GUEST_GUARD = `case "$P" in ${GUEST_HOME}|${GUEST_HOME}/*) : ;; *) echo 'chemin interdit' >&2; exit 9 ;; esac`;

// ---------------------------------------------------------------------------
// Proxy bureau : HTTP vers noVNC (127.0.0.1:6080, relié à l'invité par un
// forward SSH persistent) + WebSocket (/websockify).
// ---------------------------------------------------------------------------
function proxyDesktopHttp(req, res) {
  const upstream = http.request({
    host: '127.0.0.1', port: VNC_UPSTREAM, path: req.url, method: req.method,
    headers: { ...req.headers, host: `127.0.0.1:${VNC_UPSTREAM}` },
  }, (up) => {
    res.writeHead(up.statusCode || 502, up.headers);
    up.pipe(res);
  });
  upstream.on('error', () => {
    if (res.headersSent) return res.end();
    // Jamais d'erreur JSON sur les routes navigateur : page sobre, HTML.
    res.writeHead(502, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end('<!doctype html><meta charset="utf-8"><title>AI OS</title><body style="font-family:system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#0a0a0a;color:#eee"><div style="text-align:center"><p style="font-size:20px">Le bureau redémarre…</p><p style="opacity:.7">Réessayez dans une minute.</p></div></body>');
  });
  req.pipe(upstream);
}

function proxyDesktopWs(req, socket, head) {
  const up = net.connect(VNC_UPSTREAM, '127.0.0.1', () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    up.write(lines.join('\r\n') + '\r\n\r\n');
    if (head && head.length) up.write(head);
    socket.pipe(up);
    up.pipe(socket);
  });
  const kill = () => { up.destroy(); socket.destroy(); };
  up.on('error', kill);
  socket.on('error', kill);
}

// ---------------------------------------------------------------------------
// Routes API
// ---------------------------------------------------------------------------
const routes = {
  'GET /health': async (req, res) => {
    send(res, 200, { ok: true, bridge: 'aios-interaction', version: 2, display: DISPLAY, home: GUEST_HOME });
  },

  'GET /api/linux/status': async (req, res) => {
    const r = await runGuest(`printf 'kernel=%s\\n' "$(uname -r)"
printf 'uptime=%s\\n' "$(cut -d' ' -f1 /proc/uptime)"
pgrep -x Xvfb >/dev/null && echo xvfb=on || echo xvfb=off
pgrep -x xfce4-session >/dev/null && echo xfce=on || echo xfce=off
pgrep -x x11vnc >/dev/null && echo x11vnc=on || echo x11vnc=off
for t in scrot xdotool xclip xsel wmctrl import websockify; do command -v "$t" >/dev/null && echo "tool_$t=on" || echo "tool_$t=off"; done`, { timeoutMs: 15000 });
    const state = {};
    for (const line of r.stdout.split('\n')) {
      const m = line.match(/^([a-z_]+)=(.+)$/);
      if (m) state[m[1]] = m[2];
    }
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, status: state, ssh_exit: r.code });
  },

  'GET /api/linux/system': async (req, res) => {
    const r = await runGuest(`uname -srmo
. /etc/os-release && printf 'os=%s\\n' "$PRETTY_NAME"
uptime
free -m | sed -n '1,2p'
df -h / | tail -1`, { timeoutMs: 15000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, system: r.stdout });
  },

  'GET /api/linux/screenshot': async (req, res) => {
    const args = [
      '-i', SSH_KEY, '-o', 'StrictHostKeyChecking=accept-new',
      '-o', `UserKnownHostsFile=${KNOWN_HOSTS}`, '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=10', '-p', SSH_PORT,
      `${GUEST_USER}@127.0.0.1`,
      `DISPLAY=${DISPLAY} scrot -o /tmp/aios-screenshot.png && cat /tmp/aios-screenshot.png`,
    ];
    const child = spawn('ssh', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = []; let size = 0;
    const timer = setTimeout(() => child.kill('SIGKILL'), 30000);
    child.stdout.on('data', (d) => { size += d.length; if (size > MAX_SCREENSHOT) child.kill('SIGKILL'); else chunks.push(d); });
    child.on('error', () => { clearTimeout(timer); if (!res.headersSent) fail(res, 502, 'SSH failure'); });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (res.writableEnded) return;
      if (code !== 0) return fail(res, 502, 'Capture indisponible (scrot/Xvfb)');
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store', 'X-Linux-Daemon': '1' });
      res.end(Buffer.concat(chunks));
    });
  },

  'POST /api/linux/exec': async (req, res) => {
    const body = JSON.parse((await readBody(req)) || '{}');
    if (typeof body.command !== 'string' || !body.command.trim()) return fail(res, 400, 'Champ "command" requis');
    const timeoutSec = Math.min(Math.max(Number(body.timeout_sec) || 120, 1), 600);
    const r = await runGuest(body.command, { timeoutMs: timeoutSec * 1000 });
    send(res, 200, { ok: r.code === 0, exit_code: r.code === -2 ? 124 : r.code, stdout: r.stdout, stderr: r.stderr });
  },

  'POST /api/linux/mouse': async (req, res) => {
    const b = JSON.parse((await readBody(req)) || '{}');
    const action = String(b.action || 'move');
    const x = Number.isInteger(b.x) ? b.x : null;
    const y = Number.isInteger(b.y) ? b.y : null;
    let cmd = '';
    if (action === 'move') {
      if (x === null || y === null) return fail(res, 400, 'x et y entiers requis');
      cmd = `DISPLAY=${DISPLAY} xdotool mousemove ${x} ${y}`;
    } else if (action === 'click' || action === 'dblclick') {
      const button = [1, 2, 3].includes(b.button) ? b.button : 1;
      cmd = '';
      if (x !== null && y !== null) cmd += `DISPLAY=${DISPLAY} xdotool mousemove ${x} ${y}\n`;
      cmd += `DISPLAY=${DISPLAY} xdotool ${action === 'dblclick' ? 'click --repeat 2 --delay 120' : 'click'} ${button}`;
    } else if (action === 'scroll') {
      const dir = ['up', 'down', 'left', 'right'].includes(b.direction) ? b.direction : 'down';
      const code = { up: 4, down: 5, left: 6, right: 7 }[dir];
      const amount = Math.min(Math.max(Number(b.amount) || 3, 1), 20);
      cmd = '';
      if (x !== null && y !== null) cmd += `DISPLAY=${DISPLAY} xdotool mousemove ${x} ${y}\n`;
      cmd += `DISPLAY=${DISPLAY} xdotool click --repeat ${amount} --delay 60 ${code}`;
    } else {
      return fail(res, 400, 'action inconnue (move|click|dblclick|scroll)');
    }
    const r = await runGuest(cmd, { timeoutMs: 15000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, action, stderr: r.stderr });
  },

  'POST /api/linux/keyboard': async (req, res) => {
    const b = JSON.parse((await readBody(req)) || '{}');
    if (typeof b.key === 'string' && b.key.trim()) {
      const keys = b.key.trim();
      if (!/^[A-Za-z0-9_+(). -]{1,120}$/.test(keys) || keys.includes('..')) return fail(res, 400, 'Touches invalides');
      const r = await runGuest(`DISPLAY=${DISPLAY} xdotool key --delay 12 ${keys}`, { timeoutMs: 15000 });
      return send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, sent: keys, stderr: r.stderr });
    }
    if (typeof b.text === 'string') {
      if (b.text.length > 32 * 1024) return fail(res, 400, 'Texte trop long');
      const r = await runGuest(`printf %s '${b64(b.text)}' | base64 -d | DISPLAY=${DISPLAY} xdotool type --delay 12 --file -`, { timeoutMs: 60000 });
      return send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, typed: b.text.length, stderr: r.stderr });
    }
    fail(res, 400, 'Fournir "key" ou "text"');
  },

  'GET /api/linux/clipboard': async (req, res) => {
    const r = await runGuest(`DISPLAY=${DISPLAY} xclip -selection clipboard -o 2>/dev/null || DISPLAY=${DISPLAY} xsel --clipboard --output 2>/dev/null || true`, { timeoutMs: 15000 });
    send(res, 200, { ok: true, text: r.stdout });
  },

  'POST /api/linux/clipboard': async (req, res) => {
    const b = JSON.parse((await readBody(req)) || '{}');
    if (typeof b.text !== 'string') return fail(res, 400, 'Champ "text" requis');
    if (b.text.length > 1024 * 1024) return fail(res, 400, 'Texte trop long');
    const r = await runGuest(`printf %s '${b64(b.text)}' | base64 -d | DISPLAY=${DISPLAY} xclip -selection clipboard`, { timeoutMs: 15000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, bytes: b.text.length, stderr: r.stderr });
  },

  'GET /api/linux/files': async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const p = guestPath(url.searchParams.get('path'));
    if (!p) return fail(res, 400, `Chemin hors ${GUEST_HOME}`);
    const r = await runGuest(`P='${b64(p)}'; P=$(printf %s "$P" | base64 -d)\n${GUEST_GUARD}\nls -la --time-style=long-iso -- "$P"`, { timeoutMs: 15000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, path: p, listing: r.stdout, stderr: r.stderr });
  },

  'GET /api/linux/files/read': async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const p = guestPath(url.searchParams.get('path'));
    if (!p) return fail(res, 400, `Chemin hors ${GUEST_HOME}`);
    const r = await runGuest(`P='${b64(p)}'; P=$(printf %s "$P" | base64 -d)\n${GUEST_GUARD}\ncat -- "$P"`, { timeoutMs: 30000, maxOut: MAX_FILE });
    if (r.code === -2) return fail(res, 502, 'Fichier trop gros ou délai dépassé');
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, path: p, content: r.stdout, stderr: r.stderr });
  },

  'POST /api/linux/files/write': async (req, res) => {
    const b = JSON.parse((await readBody(req)) || '{}');
    const p = guestPath(b.path);
    if (!p) return fail(res, 400, `Chemin hors ${GUEST_HOME}`);
    if (typeof b.content !== 'string' || b.content.length > MAX_FILE) return fail(res, 400, 'Contenu absent ou trop gros (5 Mo max)');
    const r = await runGuest(`P='${b64(p)}'; P=$(printf %s "$P" | base64 -d)\n${GUEST_GUARD}\nmkdir -p "$(dirname "$P")"\nprintf %s '${b64(b.content)}' | base64 -d > "$P"`, { timeoutMs: 30000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, path: p, bytes: b.content.length, stderr: r.stderr });
  },

  'DELETE /api/linux/files': async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const p = guestPath(url.searchParams.get('path'));
    if (!p) return fail(res, 400, `Chemin hors ${GUEST_HOME}`);
    if (p === GUEST_HOME) return fail(res, 400, 'Suppression du domicile interdite');
    const r = await runGuest(`P='${b64(p)}'; P=$(printf %s "$P" | base64 -d)\n${GUEST_GUARD}\nrm -rf -- "$P"`, { timeoutMs: 30000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, deleted: p, stderr: r.stderr });
  },

  'POST /api/linux/apps/launch': async (req, res) => {
    const b = JSON.parse((await readBody(req)) || '{}');
    const app = String(b.app || '');
    if (!/^[A-Za-z0-9._+-]{1,64}$/.test(app)) return fail(res, 400, 'Nom d\'application invalide');
    const args = Array.isArray(b.args) ? b.args.slice(0, 32).map(String) : [];
    if (args.some((a) => a.length > 1024)) return fail(res, 400, 'Argument trop long');
    const argBlock = args.map((a) => `'${b64(a)}'`).join(' ');
    const r = await runGuest(`APPNAME='${app}'
APP=$(command -v "$APPNAME" || true)
if [ -z "$APP" ]; then echo "application introuvable : $APPNAME" >&2; exit 7; fi
set --
for a in ${argBlock || "''"}; do set -- "$@" "$(printf %s "$a" | base64 -d)"; done
nohup "$APP" "$@" >/dev/null 2>&1 &
printf 'launched=%s\\n' "$APP"`, { timeoutMs: 15000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, app, stderr: r.stderr });
  },

  'GET /api/linux/processes': async (req, res) => {
    const r = await runGuest('ps -eo pid,ppid,user,pcpu,pmem,etime,args --sort=-pcpu | head -n 60', { timeoutMs: 15000 });
    send(res, r.code === 0 ? 200 : 502, { ok: r.code === 0, processes: r.stdout });
  },
};
for (const key of Object.keys(routes)) {
  if (key.includes('/api/linux/')) routes[key.replace('/api/linux/', '/api/v1/')] = routes[key];
}

// ---------------------------------------------------------------------------
// Serveur
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  try {
    const path = req.url.split('?')[0].replace(/\/+$/, '') || '/';

    // 1. Bureau interactif (/, et les assets noVNC)
    if (path === '/' || !path.startsWith('/api/')) {
      if (!desktopAuthorized(req)) {
        // Sans autorisation : retour à la page d'application (authentification).
        res.writeHead(302, { Location: APP_URL, 'Cache-Control': 'no-store' });
        return res.end();
      }
      if (path === '/') {
        res.writeHead(302, { Location: '/vnc.html?autoconnect=true&resize=scale&path=websockify', 'Set-Cookie': grantCookie(req) });
        return res.end();
      }
      return proxyDesktopHttp(req, res);
    }

    // 2. API : jeton Bearer (usage Worker)
    const given = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
    const a = Buffer.from(given), b = Buffer.from(secret);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
      return fail(res, 401, 'Unauthorized');
    }
    const handler = routes[`${req.method} ${path}`];
    if (!handler) {
      return send(res, 404, {
        ok: false,
        error: `Route inconnue : ${req.method} ${path}`,
        routes: Object.keys(routes).filter((k) => !k.includes('/api/v1/')).sort(),
      });
    }
    await handler(req, res);
  } catch (e) {
    if (!res.writableEnded) fail(res, 500, e.message || 'internal error');
  }
});

function grantCookie(req) {
  const url = new URL(req.url, 'http://x');
  const v = url.searchParams.get('s') || url.searchParams.get('tok');
  if (!v || !verifyGrant(v)) return 'aios_s=; Path=/; Max-Age=0';
  return `aios_s=${encodeURIComponent(v)}; Path=/; Max-Age=43200; HttpOnly; SameSite=Lax`;
}

server.on('upgrade', (req, socket, head) => {
  const path = req.url.split('?')[0];
  if (!path.startsWith('/websockify')) return socket.destroy();
  if (!desktopAuthorized(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    return socket.destroy();
  }
  proxyDesktopWs(req, socket, head);
});

server.listen(PORT, HOST, () => {
  console.log(`AI OS bridge ready on ${HOST}:${PORT} — bureau interactif + API (display ${DISPLAY})`);
});
