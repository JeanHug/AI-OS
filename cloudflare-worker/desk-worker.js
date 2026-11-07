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
 * Déploiement : scripts/deploy-cloudflare-worker.cjs (jeton CLOUDFLARE_VPC_TOKEN,
 * liaison VPC déclarée dans les métadonnées du script).
 */

const BRIDGE = "http://localhost:3001";

export default {
  async fetch(req, env) {
    try {
      const url = new URL(req.url);
      const target = new Request(BRIDGE + url.pathname + url.search, {
        method: req.method,
        headers: req.headers,
        body: req.method === "GET" || req.method === "HEAD" ? undefined : req.body,
        redirect: "manual",
      });
      const r = await env.VPC.fetch(target);
      if (r.status === 101) {
        // WebSocket (noVNC) : transparence totale de la montée de protocole.
        return new Response(null, { status: 101, webSocket: r.webSocket, headers: r.headers });
      }
      return new Response(r.body, { status: r.status, headers: r.headers });
    } catch (e) {
      // Le pont ou le connecteur redémarre : page sobre, jamais d'erreur JSON.
      return new Response(
        "<!doctype html><meta charset=\"utf-8\"><title>AI OS</title>" +
          "<body style=\"font-family:system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#0a0a0a;color:#eee\">" +
          "<div style=\"text-align:center\"><p style=\"font-size:20px\">Le bureau redémarre…</p>" +
          "<p style=\"opacity:.7\">Réessayez dans une minute.</p></div></body>",
        { status: 502, headers: { "content-type": "text/html; charset=utf-8" } }
      );
    }
  },
};
