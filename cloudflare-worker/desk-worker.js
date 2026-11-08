/**
 * Cloudflare Worker « ai-os-desk » : le lien interactif du bureau AI OS.
 *
 * Ce worker est VOLONTAIREMENT muet : il transmet HTTP et WebSocket au pont
 * d'interaction (localhost:3001) à TRAVERS le tunnel durable nommé « ai-os »,
 * via une liaison VPC (vpc_network → tunnel_id). Aucun DNS n'est nécessaire :
 * l'URL est fixe (https://ai-os-desk.hugdu77777.workers.dev) et survit à tous
 * les redémarrages. L'authentification (jeton signé ?s=) est vérifiée par le
 * pont lui-même — jamais ici.
 *
 * Robustesse : chaque requête est réessayée pendant ~20 s avant tout repli ;
 * le repli est une page de reconnexion silencieuse qui se recharge toute seule.
 * Aucun message d'erreur n'est jamais montré au navigateur.
 *
 * Déploiement : scripts/deploy-cloudflare-worker.cjs (liaison VPC conservée
 * via keep_bindings, ou déclarée avec CLOUDFLARE_VPC_TOKEN à la première mise
 * en place).
 */

const BRIDGE = "http://localhost:3001";
const RETRIES = 5;
const RETRY_DELAY_MS = 3000;

const RECONNECT_PAGE =
  '<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="4">' +
  '<title>AI OS</title>' +
  '<body style="font-family:system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#0a0a0a;color:#eee">' +
  '<style>@keyframes spin{to{transform:rotate(360deg)}}</style>' +
  '<div style="text-align:center">' +
  '<div style="width:42px;height:42px;margin:0 auto 18px;border:3px solid #2a2a2a;border-top-color:#eee;border-radius:50%;animation:spin 1s linear infinite"></div>' +
  '<p style="font-size:18px;letter-spacing:.04em">AI OS</p></div></body>';

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    // Le corps ne se relit pas : on le met en mémoire une fois pour les réessais.
    const body = req.method === "GET" || req.method === "HEAD" ? undefined : await req.arrayBuffer();
    for (let attempt = 0; attempt < RETRIES; attempt++) {
      try {
        const target = new Request(BRIDGE + url.pathname + url.search, {
          method: req.method,
          headers: req.headers,
          body,
          redirect: "manual",
        });
        const r = await env.VPC.fetch(target);
        if (r.status === 101) {
          // WebSocket (noVNC) : transparence totale de la montée de protocole.
          return new Response(null, { status: 101, webSocket: r.webSocket, headers: r.headers });
        }
        return new Response(r.body, { status: r.status, headers: r.headers });
      } catch (e) {
        if (attempt < RETRIES - 1) await pause(RETRY_DELAY_MS);
      }
    }
    // Repli : reconnexion silencieuse (la page se recharge toute seule).
    return new Response(RECONNECT_PAGE, {
      status: 503,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "refresh": "4",
        "cache-control": "no-store",
      },
    });
  },
};
