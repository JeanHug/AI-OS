'use strict';
// qemu-publish-tunnel.cjs — publie l'URL du tunnel courant sur la branche
// « tunnel-url » (lue par le Worker ai-os). Vérifie d'abord que le pont
// répond, pour ne jamais publier « online » sur un pont mort.
const { execFileSync } = require('child_process');
const repo = process.env.GITHUB_REPOSITORY;
const token = process.env.GH_TOKEN;
const origin = process.env.AIOS_TUNNEL;
const tunnelFile = process.env.AIOS_TUNNEL_FILE || 'tunnels-linux.json';
if (!repo || !token || !/^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/.test(origin || '')) throw Error('Missing publish settings');
if (!/^tunnels-[a-z-]+\.json$/.test(tunnelFile)) throw Error('AIOS_TUNNEL_FILE invalide');

async function api(path, init = {}) {
  const r = await fetch(`https://api.github.com/repos/${repo}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'Content-Type': 'application/json', ...(init.headers || {}) },
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw Error(`GitHub HTTP ${r.status}: ${j.message || ''}`);
  return j;
}

(async () => {
  try {
    // Le pont est-il vivant ? (le tunnel peut être publié alors que le pont
    // ne démarre pas encore — on publie alors status: starting, pas online.)
    let status = 'online';
    try {
      const probe = await fetch(`${origin}/health`, { signal: AbortSignal.timeout(10000) });
      status = probe.ok ? 'online' : 'starting';
    } catch (e) {
      status = 'starting';
    }

    let ref;
    try { ref = await api('/git/ref/heads/tunnel-url'); }
    catch (e) {
      if (!e.message.includes('404')) throw e;
      const m = await api('/git/ref/heads/main');
      await api('/git/refs', { method: 'POST', body: JSON.stringify({ ref: 'refs/heads/tunnel-url', sha: m.object.sha }) });
    }
    let sha;
    try { const old = await api(`/contents/${tunnelFile}?ref=tunnel-url`); sha = old.sha; }
    catch (e) { if (!e.message.includes('404')) throw e; }
    const payload = {
      name: 'AI OS QEMU',
      primary: origin,
      cloudflare: origin,
      status,
      updated_at: new Date().toISOString(),
    };
    const body = {
      message: 'Update temporary QEMU tunnel',
      branch: 'tunnel-url',
      content: Buffer.from(JSON.stringify(payload)).toString('base64'),
    };
    if (sha) body.sha = sha;
    await api(`/contents/${tunnelFile}`, { method: 'PUT', body: JSON.stringify(body) });
    console.log(`Tunnel publié (${tunnelFile}, status: ${status}).`);
  } catch (e) {
    console.error('Publication tunnel échouée:', e.message);
    process.exitCode = 1;
  }
})();
