/**
 * Cloudflare Worker « ai-os » : passerelle sécurisée et API d'interaction
 * de la VM AI OS (https://ai-os.hugdu77777.workers.dev).
 */

/**
 * Bureau interactif : lien fixe du tunnel durable « ai-os » (tunnel nommé
 * Cloudflare, relié au Worker ai-os-desk par liaison VPC). Aucune URL de
 * tunnel n'est plus publiée ni découverte — elle ne change jamais.
 */
const DESK_URL = "https://ai-os-desk.hugdu77777.workers.dev";

/** Comparaison à temps constant (le Worker n'a pas crypto.timingSafeEqual). */
function timingSafeEqualStr(a, b) {
  const ab = new TextEncoder().encode(a);
  const bb = new TextEncoder().encode(b);
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

/**
 * Jeton d'accès au bureau interactif : <expiration>.<HMAC-SHA256(expiration)>.
 * Le pont vérifie la signature avec le même VM_API_TOKEN — le secret ne
 * circule jamais dans l'URL.
 */
async function signDesktopGrant(secret) {
  const exp = Math.floor(Date.now() / 1000) + 14400; // 4 h
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(String(exp)));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${exp}.${hex}`;
}

/** Vérifie un jeton de bureau <exp>.<hmac> (même signature que /grant). */
async function verifyDesktopGrant(secret, value) {
  if (!secret || typeof value !== "string" || !value) return false;
  if (value === secret) return true; // jeton brut (usage machine)
  const m = value.match(/^(\d{10})\.([a-f0-9]{64})$/);
  if (!m) return false;
  const exp = Number(m[1]);
  if (!Number.isFinite(exp) || exp < Math.floor(Date.now() / 1000)) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(String(exp)));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return timingSafeEqualStr(hex, m[2]);
}

/** Exécute une commande dans l'invité via le pont (relais /api/linux/exec). */
async function linuxExec(env, command, timeoutSec = 60) {
  const init = {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + env.VM_API_TOKEN },
    body: JSON.stringify({ command, timeout_sec: timeoutSec }),
    redirect: "follow",
  };
  const r = env.DESK
    ? await env.DESK.fetch("https://ai-os-desk.hugdu77777.workers.dev/api/linux/exec", init)
    : await fetch("https://ai-os-desk.hugdu77777.workers.dev/api/linux/exec", init);
  return r.json();
}

/** Détecteur de focus texte (AT-SPI) + démon de veille dans l'invité. */
const FOCUS_PY_B64 = "aW1wb3J0IHN5cywganNvbgpURVhUX1JPTEVTID0geyd0ZXh0JywgJ2VudHJ5JywgJ3Bhc3N3b3JkIHRleHQnLCAncGFyYWdyYXBoJywgJ3Rlcm1pbmFsJywgJ2RvY3VtZW50IHRleHQnLCAnc3BpbiBidXR0b24nfQpzdGF0ZSA9ICdub25lJwpyZWN0ID0gTm9uZQp0cnk6CiAgICBpbXBvcnQgcHlhdHNwaQogICAgZGVmIHdhbGsobywgZGVwdGgpOgogICAgICAgIGdsb2JhbCBzdGF0ZSwgcmVjdAogICAgICAgIGlmIHN0YXRlICE9ICdub25lJyBvciBkZXB0aCA+IDEyOgogICAgICAgICAgICByZXR1cm4KICAgICAgICB0cnk6CiAgICAgICAgICAgIGlmIG8uZ2V0U3RhdGUoKS5jb250YWlucyhweWF0c3BpLlNUQVRFX0ZPQ1VTRUQpOgogICAgICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgIHJvbGUgPSBzdHIoby5nZXRSb2xlTmFtZSgpKQogICAgICAgICAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgICAgICAgICByb2xlID0gJycKICAgICAgICAgICAgICAgIHN0YXRlID0gJ3RleHQnIGlmIHJvbGUgaW4gVEVYVF9ST0xFUyBlbHNlICdvdGhlcicKICAgICAgICAgICAgICAgIGlmIHN0YXRlID09ICd0ZXh0JzoKICAgICAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgICAgIGNvbXAgPSBvLnF1ZXJ5Q29tcG9uZW50KCkKICAgICAgICAgICAgICAgICAgICAgICAgZSA9IGNvbXAuZ2V0RXh0ZW50cyhweWF0c3BpLkNvb3JkVHlwZS5TQ1JFRU4pCiAgICAgICAgICAgICAgICAgICAgICAgIHJlY3QgPSBbaW50KGVbMF0pLCBpbnQoZVsxXSksIGludChlWzJdKSwgaW50KGVbM10pXQogICAgICAgICAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICAgICAgICAgICAgIHJlY3QgPSBOb25lCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCiAgICAgICAgdHJ5OgogICAgICAgICAgICBmb3IgYyBpbiBvOgogICAgICAgICAgICAgICAgd2FsayhjLCBkZXB0aCArIDEpCiAgICAgICAgICAgICAgICBpZiBzdGF0ZSAhPSAnbm9uZSc6CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICAgICAgcGFzcwogICAgdHJ5OgogICAgICAgIGRlc2t0b3AgPSBweWF0c3BpLlJlZ2lzdHJ5LmdldERlc2t0b3AoMCkKICAgICAgICBmb3IgYXBwIGluIGRlc2t0b3A6CiAgICAgICAgICAgIHdhbGsoYXBwLCAwKQogICAgICAgICAgICBpZiBzdGF0ZSAhPSAnbm9uZSc6CiAgICAgICAgICAgICAgICBicmVhawogICAgZXhjZXB0IEV4Y2VwdGlvbjoKICAgICAgICBwYXNzCmV4Y2VwdCBFeGNlcHRpb246CiAgICBwYXNzCmlmIHN0YXRlID09ICdub25lJzoKICAgIHRyeToKICAgICAgICBpbXBvcnQgc3VicHJvY2VzcwogICAgICAgIHcgPSBzdWJwcm9jZXNzLmNoZWNrX291dHB1dChbJ3hkb3Rvb2wnLCAnZ2V0YWN0aXZld2luZG93JywgJ2dldHdpbmRvd2NsYXNzbmFtZSddLCB0aW1lb3V0PTIpLmRlY29kZSgpLnN0cmlwKCkubG93ZXIoKQogICAgICAgIGlmIGFueShrIGluIHcgZm9yIGsgaW4gKCd0ZXJtaW5hbCcsICd4dGVybScsICd1cnh2dCcsICdraXR0eScsICdhbGFjcml0dHknLCAna29uc29sZScsICd0aWxpeCcsICdndWFrZScsICdzYWt1cmEnKSk6CiAgICAgICAgICAgIHN0YXRlID0gJ3RleHQnCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIG91dCA9IHN1YnByb2Nlc3MuY2hlY2tfb3V0cHV0KFsneGRvdG9vbCcsICdnZXRhY3RpdmV3aW5kb3cnLCAnZ2V0d2luZG93Z2VvbWV0cnknLCAnLS1zaGVsbCddLCB0aW1lb3V0PTIpLmRlY29kZSgpCiAgICAgICAgICAgICAgICBnID0gZGljdChsLnNwbGl0KCc9JywgMSkgZm9yIGwgaW4gb3V0LnNwbGl0KCkgaWYgJz0nIGluIGwpCiAgICAgICAgICAgICAgICByZWN0ID0gW2ludChnWydYJ10pLCBpbnQoZ1snWSddKSwgaW50KGdbJ1dJRFRIJ10pLCBpbnQoZ1snSEVJR0hUJ10pXQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICAgICAgcmVjdCA9IE5vbmUKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwpwcmludChqc29uLmR1bXBzKHsnZm9jdXMnOiBzdGF0ZSwgJ3JlY3QnOiByZWN0fSkpCg==";
const FOCUS_ENSURE = [
  "printf %s '" + FOCUS_PY_B64 + "' | base64 -d > /tmp/focus-poll.py.new && { cmp -s /tmp/focus-poll.py.new /home/aios/focus-poll.py 2>/dev/null || mv /tmp/focus-poll.py.new /home/aios/focus-poll.py; }",
  'python3 -c "import pyatspi" 2>/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pyatspi >/dev/null 2>&1',
  'if ! kill -0 "$(cat /tmp/aios-focus.pid 2>/dev/null)" 2>/dev/null; then',
  "  setsid nohup bash -c 'while :; do DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus python3 /home/aios/focus-poll.py > /tmp/aios-focus.new 2>/dev/null && mv /tmp/aios-focus.new /tmp/aios-focus || echo none > /tmp/aios-focus; sleep 0.7; done' >/dev/null 2>&1 &",
  "  echo $! > /tmp/aios-focus.pid",
  "fi",
].join("\n");

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 1. Gestion des requêtes CORS pre-flight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Requested-With",
          "Access-Control-Max-Age": "86400",
        },
      });
    }

    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Requested-With",
      "Cache-Control": "no-store, no-cache, must-revalidate",
    };

    // 2. Documentation Minimaliste Fond Blanc (/docs ou /api/docs)
    const isDocRequest = url.pathname === "/docs" || 
                         url.pathname === "/api/docs" || 
                         url.searchParams.has("docs") ||
                         (url.pathname === "/" && request.headers.get("accept")?.includes("text/html") && !url.searchParams.get("target") && !url.searchParams.get("password"));

    if (isDocRequest) {
      return new Response(generateDocsHtml(url.origin), {
        headers: {
          ...corsHeaders,
          "Content-Type": "text/html; charset=utf-8",
        },
      });
    }

    // 3. Endpoint public de santé (Health Check)
    if (url.pathname === "/api/health" || url.pathname === "/health") {
      return new Response(
        JSON.stringify({
          status: "ok",
          service: "AI OS — passerelle VM Linux",
          worker: "ai-os",
          timestamp: new Date().toISOString(),
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" } }
      );
    }

    // 3b. Page d'application publique (fichier unique, servie aussi par GitHub Pages)
    if (url.pathname === "/app" || url.pathname === "/app/") {
      try {
        const resApp = await fetch("https://raw.githubusercontent.com/JeanHug/AI-OS/main/app/index.html", {
          headers: { "User-Agent": "Cloudflare-AI-OS" },
          cf: { cacheTtl: 300, cacheEverything: true },
        });
        if (resApp.ok) {
          return new Response(await resApp.text(), {
            headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=300" },
          });
        }
      } catch (e) {}
      return new Response("Application indisponible.", { status: 502, headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }

    // 4. Bureau mobile : géométrie, focus texte, redimensionnement.
    //    Autorisé par le jeton de bureau signé (?s=) — jamais de secret en clair.
    if (url.pathname.startsWith("/api/desktop/")) {
      const ticket = url.searchParams.get("s") || url.searchParams.get("tok") || "";
      const bearer = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
      const okTicket = await verifyDesktopGrant(env.VM_API_TOKEN, ticket);
      const okPass = !!env.PASS && !!bearer && timingSafeEqualStr(bearer, env.PASS);
      if (!okTicket && !okPass) {
        return new Response(JSON.stringify({ ok: false, error: "Unauthorized" }), {
          status: 401, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
        });
      }
      const J = (o, s = 200) => new Response(JSON.stringify(o), {
        status: s,
        headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8", "X-Linux-Daemon": "1" },
      });

      if (url.pathname === "/api/desktop/geom" && request.method === "GET") {
        const r = await linuxExec(env, 'export DISPLAY=:99\nxrandr 2>/dev/null | grep -o "current [0-9]* x [0-9]*" || true', 20);
        const m = String((r && r.stdout) || "").match(/current (\d+) x (\d+)/);
        return J({ ok: !!m, width: m ? Number(m[1]) : null, height: m ? Number(m[2]) : null });
      }

      if (url.pathname === "/api/desktop/focus" && request.method === "GET") {
        const r = await linuxExec(env, FOCUS_ENSURE + "\ncat /tmp/aios-focus 2>/dev/null || echo none", 30);
        const v = String((r && r.stdout) || "").trim().split("\n").pop();
        let focus = "none", rect = null;
        if (v.startsWith("{")) {
          try {
            const o = JSON.parse(v);
            focus = o.focus === "text" ? "text" : (o.focus === "other" ? "other" : "none");
            rect = Array.isArray(o.rect) ? o.rect : null;
          } catch (e) {}
        } else {
          focus = v === "text" ? "text" : (v === "other" ? "other" : "none");
        }
        return J({ ok: true, focus, rect });
      }

      if (url.pathname === "/api/desktop/resize" && request.method === "POST") {
        let body = {};
        try { body = JSON.parse(await request.text()); } catch (e) {}
        const w = Math.round(Number(body.width)), h = Math.round(Number(body.height));
        if (!Number.isFinite(w) || !Number.isFinite(h) || w < 480 || w > 3840 || h < 320 || h > 2400) {
          return J({ ok: false, error: "Géométrie invalide" }, 400);
        }
        const script = FOCUS_ENSURE + "\n" + [
          "pkill -x xfce4-session 2>/dev/null; pkill -x xfwm4 2>/dev/null; pkill -x xfdesktop 2>/dev/null; pkill -x xfce4-panel 2>/dev/null; pkill -x xfsettingsd 2>/dev/null",
          "pkill -x x11vnc 2>/dev/null; pkill -x websockify 2>/dev/null; pkill -x Xvfb 2>/dev/null",
          "sleep 1",
          "pkill -9 -x x11vnc 2>/dev/null; pkill -9 -x websockify 2>/dev/null; pkill -9 -x Xvfb 2>/dev/null",
          "for i in 1 2 3 4 5 6 7 8; do if ss -ltn | grep -q ':5900 ' || ss -ltn | grep -q ':6080 '; then sleep 1; else break; fi; done",
          `setsid nohup Xvfb :99 -screen 0 ${w}x${h}x24 >/tmp/aios-xvfb.log 2>&1 &`,
          "sleep 1.6",
          "setsid nohup env DISPLAY=:99 xfce4-session >/tmp/aios-xfce.log 2>&1 &",
          "sleep 1",
          "setsid nohup x11vnc -display :99 -localhost -rfbport 5900 -shared -forever -nopw -xkb -wait 8 -defer 8 -o /tmp/aios-x11vnc.log >/dev/null 2>&1 &",
          "setsid nohup websockify --web=/usr/share/novnc 127.0.0.1:6080 localhost:5900 >/tmp/aios-websockify.log 2>&1 &",
          "sleep 1.5",
          'for i in 1 2 3 4 5 6; do ss -ltn | grep -q ":5900 " && ss -ltn | grep -q ":6080 " && break; sleep 1.5; done',
          'ss -ltn | grep -q ":5900 " || setsid nohup x11vnc -display :99 -localhost -rfbport 5900 -shared -forever -nopw -xkb -wait 8 -defer 8 -o /tmp/aios-x11vnc.log >/dev/null 2>&1 &',
          'ss -ltn | grep -q ":6080 " || setsid nohup websockify --web=/usr/share/novnc 127.0.0.1:6080 localhost:5900 >/tmp/aios-websockify.log 2>&1 &',
          "sleep 1",
          'xrandr 2>/dev/null | grep -o "current [0-9]* x [0-9]*" || true',
        ].join("\n");
        const r = await linuxExec(env, script, 90);
        return J({ ok: !!(r && r.ok), width: w, height: h, out: String((r && r.stdout) || "").slice(-300) });
      }

      return J({ ok: false, error: "Route inconnue : " + url.pathname }, 404);
    }

    // 4. Extraction & Validation de l'Authentification
    let userPassword = url.searchParams.get("password") || url.searchParams.get("pin");
    
    const authHeader = request.headers.get("Authorization");
    if (authHeader) {
      const match = authHeader.match(/^Bearer\s+(.*)$/i);
      if (match) {
        userPassword = match[1].trim();
      } else if (!userPassword) {
        userPassword = authHeader.trim();
      }
    }

    let requestBody = null;
    let requestBodyText = null;

    if (request.method === "POST" || request.method === "PUT") {
      try {
        requestBodyText = await request.text();
        if (requestBodyText) {
          try {
            requestBody = JSON.parse(requestBodyText);
            if (!userPassword && requestBody) {
              userPassword = requestBody.password || requestBody.pin;
            }
          } catch (e) {
            // Pas du JSON pur
          }
        }
      } catch (e) {
        // Corps non lisible
      }
    }

    const expectedPassword = env.PASS;

    if (!expectedPassword || !userPassword || !timingSafeEqualStr(userPassword, expectedPassword)) {
      return new Response(
        JSON.stringify({
          ok: false,
          authenticated: false,
          error: "Mot de passe incorrect ou manquant.",
          hint: "Fournissez le mot de passe via l'en-tête 'Authorization: Bearer <PASS>', le paramètre URL '?password=<PASS>', ou dans le corps JSON '{\"password\": \"<PASS>\"}'.",
          docs_url: `${url.origin}/docs`
        }, null, 2),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" } }
      );
    }

    // 5. Lien du bureau (URL fixe du tunnel durable)
    const linuxPrimaryUrl = DESK_URL;

    // 5b. Délivrance du jeton d'accès au bureau (utilisé par la page d'application)
    if (url.pathname === "/grant" || url.pathname === "/api/grant") {
      if (!env.VM_API_TOKEN) {
        return new Response(JSON.stringify({ ok: false, error: "VM_API_TOKEN absent du Worker" }), {
          status: 503, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
        });
      }
      const grant = await signDesktopGrant(env.VM_API_TOKEN);
      return new Response(JSON.stringify({ ok: true, url: `${linuxPrimaryUrl}/mobile.html?s=${grant}`, expires_in: 14400 }), {
        headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
      });
    }

    // 6. Lien interactif : ouverture du bureau (jeton signé à usage temporaire)
    const target = url.searchParams.get("target")?.toLowerCase();
    if (target === "linux") {
      if (!env.VM_API_TOKEN) {
        return new Response(JSON.stringify({ ok: false, error: "VM_API_TOKEN absent du Worker" }), {
          status: 503, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
        });
      }
      const grant = await signDesktopGrant(env.VM_API_TOKEN);
      return Response.redirect(`${linuxPrimaryUrl}/mobile.html?s=${grant}`, 302);
    }

    // 7. Route générale : Tunnels et Statut Global (/ ou /api/tunnels)
    if (url.pathname === "/" || url.pathname === "/api/tunnels") {
      return new Response(
        JSON.stringify({
          authenticated: true,
          status: "online",
          linux: { name: "Ubuntu Linux Desktop", primary: linuxPrimaryUrl, status: "online" },
          primary: linuxPrimaryUrl,
          cloudflare: linuxPrimaryUrl,
          docs_url: `${url.origin}/docs`,
          updated_at: new Date().toISOString()
        }, null, 2),
        { headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" } }
      );
    }

    // 8. Relais d'Interaction API Linux (/api/linux/* ou /api/v1/*)
    if (url.pathname.startsWith("/api/linux") || url.pathname.startsWith("/api/v1")) {
      // 8a. Statut rapide du tunnel Linux
      if (url.pathname === "/api/linux/status") {
        return new Response(
          JSON.stringify({
            ok: true,
            status: "online",
            name: "Ubuntu Linux Desktop",
            tunnel_url: linuxPrimaryUrl,
            updated_at: new Date().toISOString(),
            gateway: url.origin,
            docs_url: `${url.origin}/docs`
          }, null, 2),
          { headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" } }
        );
      }

      // 8b. Transmission directe de la requête au runner Linux via le tunnel Cloudflare
      const targetVmUrl = new URL(url.pathname, linuxPrimaryUrl);
      targetVmUrl.search = url.search;

      try {
        const forwardHeaders = new Headers();
        for (const [key, value] of request.headers.entries()) {
          // Filtrer les en-têtes hop-by-hop
          if (!['host', 'cf-ray', 'cf-connecting-ip', 'cf-visitor', 'x-forwarded-for', 'x-forwarded-proto'].includes(key.toLowerCase())) {
            forwardHeaders.set(key, value);
          }
        }
        forwardHeaders.set("X-Forwarded-Host", url.host);
        if (!env.VM_API_TOKEN) return new Response("VM bridge not configured", { status: 503 });
        forwardHeaders.set("Authorization", `Bearer ${env.VM_API_TOKEN}`);
        targetVmUrl.searchParams.delete("password");
        targetVmUrl.searchParams.delete("pin");

        const init = {
          method: request.method,
          headers: forwardHeaders,
          body: requestBodyText || undefined,
          redirect: "follow",
        };
        // Liaison de service directe (rapide, sans edge) ; repli sur l'URL publique.
        const vmResponse = env.DESK
          ? await env.DESK.fetch(targetVmUrl.toString(), init)
          : await fetch(targetVmUrl.toString(), init);

        // Le pont d'interaction signale ses réponses par X-Linux-Daemon. Sans cet
        // en-tête, une réponse 404/502 vient du tunnel lui-même (pont absent) et
        // ne doit JAMAIS être présentée comme un succès.
        const isFromDaemon = vmResponse.headers.has("x-linux-daemon") ||
          (vmResponse.headers.get("content-type") || "").includes("application/json");

        if (isFromDaemon || (vmResponse.status !== 404 && vmResponse.status !== 502)) {
          const respHeaders = new Headers(vmResponse.headers);
          respHeaders.set("Access-Control-Allow-Origin", "*");
          respHeaders.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
          respHeaders.set("Access-Control-Allow-Headers", "Content-Type, Authorization");

          return new Response(vmResponse.body, {
            status: vmResponse.status,
            headers: respHeaders
          });
        }

        // Le tunnel existe mais aucun pont d'interaction n'y répond.
        return new Response(
          JSON.stringify({
            ok: false,
            status: "bridge_unreachable",
            message: "Le tunnel est publié mais le pont d'interaction ne répond pas. Le système sera restauré lors du prochain cycle.",
            tunnel_info: { tunnel: "ai-os", url: DESK_URL }
          }, null, 2),
          { status: 503, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" } }
        );

      } catch (err) {
        return new Response(
          JSON.stringify({
            ok: false,
            error: "Erreur de communication avec le tunnel Linux: " + err.message,
            tunnel_url: DESK_URL
          }, null, 2),
          { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" } }
        );
      }
    }

    // 9. Point de terminaison non trouvé
    return new Response(
      JSON.stringify({
        ok: false,
        error: `Point de terminaison non reconnu : ${url.pathname}`,
        available_endpoints: [
          "/docs",
          "/app",
          "/grant",
          "/api/health",
          "/api/tunnels",
          "/api/linux/status",
          "/api/linux/system",
          "/api/linux/exec",
          "/api/linux/screenshot",
          "/api/linux/mouse",
          "/api/linux/keyboard",
          "/api/linux/clipboard",
          "/api/linux/files",
          "/api/linux/files/read",
          "/api/linux/files/write",
          "/api/linux/apps/launch",
          "/api/linux/processes"
        ],
        docs_url: `${url.origin}/docs`
      }, null, 2),
      { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" } }
    );
  }
};

/**
 * Générateur de la documentation minimaliste sur fond blanc
 */
function generateDocsHtml(origin) {
  return `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Documentation API — AI OS</title>
  <style>
    :root {
      --bg: #ffffff;
      --text: #111827;
      --text-muted: #4b5563;
      --border: #e5e7eb;
      --code-bg: #f9fafb;
      --accent: #2563eb;
      --accent-hover: #1d4ed8;
      --success: #059669;
      --error: #dc2626;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      line-height: 1.6;
      padding: 40px 20px;
    }
    .container {
      max-width: 960px;
      margin: 0 auto;
    }
    header {
      border-bottom: 1px solid var(--border);
      padding-bottom: 24px;
      margin-bottom: 32px;
    }
    h1 {
      font-size: 26px;
      font-weight: 700;
      letter-spacing: -0.02em;
      margin-bottom: 8px;
    }
    .badge {
      display: inline-block;
      font-size: 12px;
      font-weight: 600;
      padding: 2px 8px;
      border-radius: 4px;
      background: #eff6ff;
      color: var(--accent);
      border: 1px solid #bfdbfe;
      margin-bottom: 12px;
    }
    p.lead {
      font-size: 15px;
      color: var(--text-muted);
    }
    section {
      margin-bottom: 40px;
    }
    h2 {
      font-size: 19px;
      font-weight: 600;
      margin-bottom: 16px;
      padding-bottom: 6px;
      border-bottom: 1px solid var(--border);
    }
    h3 {
      font-size: 15px;
      font-weight: 600;
      margin: 20px 0 8px 0;
    }
    pre, code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 13px;
    }
    code {
      background: var(--code-bg);
      padding: 2px 6px;
      border-radius: 4px;
      border: 1px solid var(--border);
    }
    pre {
      background: var(--code-bg);
      padding: 14px 16px;
      border-radius: 6px;
      border: 1px solid var(--border);
      overflow-x: auto;
      margin: 10px 0 16px 0;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin: 14px 0 24px 0;
      font-size: 14px;
    }
    th, td {
      text-align: left;
      padding: 10px 12px;
      border: 1px solid var(--border);
    }
    th {
      background: var(--code-bg);
      font-weight: 600;
    }
    .method {
      font-weight: 700;
      font-size: 11px;
      padding: 2px 6px;
      border-radius: 3px;
    }
    .get { background: #ecfdf5; color: #047857; }
    .post { background: #eff6ff; color: #1d4ed8; }
    .delete { background: #fef2f2; color: #b91c1c; }

    /* Console Interactive */
    .console-card {
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 20px;
      background: #ffffff;
      box-shadow: 0 1px 3px rgba(0,0,0,0.03);
    }
    .form-group {
      margin-bottom: 14px;
    }
    label {
      display: block;
      font-size: 13px;
      font-weight: 600;
      margin-bottom: 6px;
    }
    input, select, textarea {
      width: 100%;
      padding: 8px 12px;
      font-size: 14px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: #fff;
      color: var(--text);
      font-family: inherit;
    }
    input:focus, select:focus, textarea:focus {
      outline: none;
      border-color: var(--accent);
      box-shadow: 0 0 0 2px rgba(37, 99, 235, 0.1);
    }
    button.btn {
      background: var(--accent);
      color: #fff;
      border: none;
      padding: 9px 18px;
      border-radius: 6px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s;
    }
    button.btn:hover {
      background: var(--accent-hover);
    }
    .response-box {
      margin-top: 16px;
      display: none;
    }
    .screenshot-preview {
      max-width: 100%;
      border: 1px solid var(--border);
      border-radius: 6px;
      margin-top: 10px;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <span class="badge">Cloudflare Worker Gateway • v1.0</span>
      <h1>API d'Interaction Linux VM</h1>
      <p class="lead">Passerelle unifiée et sécurisée pour interagir avec le bureau Linux Ubuntu (exécution de commandes, capture d'écran, souris/clavier, fichiers et applications).</p>
    </header>

    <!-- 1. Authentification -->
    <section id="auth">
      <h2>1. Authentification</h2>
      <p>Toutes les requêtes (sauf <code>/api/health</code> et <code>/docs</code>) exigent votre mot de passe secret (variable <code>PASS</code> configurée dans votre compte Cloudflare).</p>
      
      <h3>3 méthodes acceptées :</h3>
      <ul>
        <li><strong>En-tête HTTP (Recommandé) :</strong> <code>Authorization: Bearer &lt;VOTRE_MOT_DE_PASSE&gt;</code></li>
        <li><strong>Paramètre URL :</strong> <code>?password=&lt;VOTRE_MOT_DE_PASSE&gt;</code></li>
        <li><strong>Corps JSON (POST/PUT) :</strong> <code>{ "password": "&lt;VOTRE_MOT_DE_PASSE&gt;", ... }</code></li>
      </ul>
    </section>

    <!-- 2. Points de terminaison -->
    <section id="endpoints">
      <h2>2. Référence des Endpoints</h2>
      <table>
        <thead>
          <tr>
            <th>Méthode</th>
            <th>Endpoint</th>
            <th>Description</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/health</code></td>
            <td>Statut public de la passerelle (sans authentification).</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/tunnels</code></td>
            <td>Retourne les URLs en direct de la VM Linux.</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/linux/status</code></td>
            <td>Statut du tunnel Linux et date de dernière synchronisation.</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/linux/system</code></td>
            <td>Informations système (CPU, mémoire, disque, fenêtre active).</td>
          </tr>
          <tr>
            <td><span class="method post">POST</span></td>
            <td><code>/api/linux/exec</code></td>
            <td>Exécute une commande Bash dans le conteneur Ubuntu Desktop.</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/linux/screenshot</code></td>
            <td>Capture d'écran de l'affichage X11 (PNG direct ou JSON base64).</td>
          </tr>
          <tr>
            <td><span class="method post">POST</span></td>
            <td><code>/api/linux/mouse</code></td>
            <td>Contrôle souris : clic, déplacement, clic droit, molette.</td>
          </tr>
          <tr>
            <td><span class="method post">POST</span></td>
            <td><code>/api/linux/keyboard</code></td>
            <td>Contrôle clavier : saisie de texte fluide ou frappe de touches.</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span>/<span class="method post">POST</span></td>
            <td><code>/api/linux/clipboard</code></td>
            <td>Lecture ou modification du presse-papier X11.</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/linux/files?path=...</code></td>
            <td>Liste le contenu d'un répertoire dans <code>/home/aios</code>.</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/linux/files/read?path=...</code></td>
            <td>Lit le contenu textuel d'un fichier.</td>
          </tr>
          <tr>
            <td><span class="method post">POST</span></td>
            <td><code>/api/linux/files/write</code></td>
            <td>Écrit ou crée un fichier sur le disque persistant.</td>
          </tr>
          <tr>
            <td><span class="method post">POST</span></td>
            <td><code>/api/linux/apps/launch</code></td>
            <td>Lance une application graphique (Chrome, Terminal, etc.).</td>
          </tr>
          <tr>
            <td><span class="method get">GET</span></td>
            <td><code>/api/linux/processes</code></td>
            <td>Liste les processus actifs triés par consommation CPU.</td>
          </tr>
        </tbody>
      </table>
    </section>

    <!-- 3. Exemples de Payloads -->
    <section id="examples">
      <h2>3. Exemples d'Appels JSON</h2>

      <h3>Exécuter une commande Bash :</h3>
      <pre>POST /api/linux/exec
Content-Type: application/json
Authorization: Bearer &lt;VOTRE_MOT_DE_PASSE&gt;

{
  "command": "python3 -c 'import platform; print(platform.uname())'",
  "cwd": "/home/aios",
  "timeout": 30
}</pre>

      <h3>Contrôler la souris :</h3>
      <pre>POST /api/linux/mouse
Content-Type: application/json
Authorization: Bearer &lt;VOTRE_MOT_DE_PASSE&gt;

{
  "action": "click",
  "x": 450,
  "y": 300
}</pre>

      <h3>Saisir du texte au clavier :</h3>
      <pre>POST /api/linux/keyboard
Content-Type: application/json
Authorization: Bearer &lt;VOTRE_MOT_DE_PASSE&gt;

{
  "text": "echo 'Hello from AI Agent!'"
}</pre>
    </section>

    <!-- 4. Console de Test Interactive -->
    <section id="console">
      <h2>4. Console de Test Interactive</h2>
      <div class="console-card">
        <div class="form-group">
          <label for="cfgPassword">Mot de passe secret :</label>
          <input type="password" id="cfgPassword" value="" placeholder="Entrez obligatoirement votre mot de passe pour tester" autocomplete="off" required>
        </div>

        <div class="form-group">
          <label for="cfgEndpoint">Endpoint à tester :</label>
          <select id="cfgEndpoint" onchange="handleEndpointChange()">
            <option value="GET|/api/tunnels">GET /api/tunnels (Tunnels actifs)</option>
            <option value="GET|/api/linux/status">GET /api/linux/status (Statut Linux)</option>
            <option value="GET|/api/linux/system">GET /api/linux/system (Métriques système)</option>
            <option value="POST|/api/linux/exec">POST /api/linux/exec (Commande Bash)</option>
            <option value="GET|/api/linux/screenshot">GET /api/linux/screenshot (Capture d'écran)</option>
            <option value="GET|/api/linux/clipboard">GET /api/linux/clipboard (Presse-papier)</option>
            <option value="GET|/api/linux/processes">GET /api/linux/processes (Processus)</option>
            <option value="GET|/api/linux/files?path=/home/aios">GET /api/linux/files (Domicile)</option>
          </select>
        </div>

        <div class="form-group" id="bodyGroup" style="display: none;">
          <label for="cfgBody">Corps JSON (POST) :</label>
          <textarea id="cfgBody" rows="4" style="font-family: monospace; font-size: 13px;">{
  "command": "uname -a && free -h"
}</textarea>
        </div>

        <button type="button" class="btn" onclick="executeTest()">Envoyer la requête</button>

        <div class="response-box" id="responseBox">
          <label>Réponse du serveur (<span id="resStatus"></span>) :</label>
          <pre id="resContent" style="max-height: 380px; overflow-y: auto;"></pre>
          <img id="imgPreview" class="screenshot-preview" style="display: none;" alt="Aperçu écran">
        </div>
      </div>
    </section>

    <!-- 5. Guide Agent IA -->
    <section id="ai-guide">
      <h2>5. Guide d'Intégration pour Agents IA</h2>
      <p>Vous pouvez copier ce bloc de contexte directement dans les instructions de votre agent IA (Gemini, Claude, GPT) :</p>
      <pre>Tu disposes d'un accès complet à une machine Linux Ubuntu via l'API REST suivante :
Base URL : ${origin}
Mot de passe : &lt;VOTRE_MOT_DE_PASSE&gt; (en-tête Authorization: Bearer &lt;VOTRE_MOT_DE_PASSE&gt;)

- Pour exécuter des commandes : POST /api/linux/exec { "command": "votre commande" }
- Pour voir l'écran : GET /api/linux/screenshot?format=base64
- Pour interagir avec la souris : POST /api/linux/mouse { "action": "click", "x": 100, "y": 200 }
- Pour taper au clavier : POST /api/linux/keyboard { "text": "texte" } ou { "key": "Return" }
- Pour gérer les fichiers : GET/POST /api/linux/files</pre>
    </section>
  </div>

  <script>
    function handleEndpointChange() {
      const val = document.getElementById('cfgEndpoint').value;
      const [method] = val.split('|');
      document.getElementById('bodyGroup').style.display = method === 'POST' ? 'block' : 'none';
    }

    async function executeTest() {
      const pwd = document.getElementById('cfgPassword').value.trim();
      const val = document.getElementById('cfgEndpoint').value;
      const [method, endpoint] = val.split('|');
      const bodyText = document.getElementById('cfgBody').value;
      const resBox = document.getElementById('responseBox');
      const resStatus = document.getElementById('resStatus');
      const resContent = document.getElementById('resContent');
      const imgPreview = document.getElementById('imgPreview');

      resBox.style.display = 'block';
      imgPreview.style.display = 'none';

      if (!pwd && endpoint !== '/api/health') {
        resStatus.textContent = 'Mot de passe requis';
        resContent.textContent = 'Veuillez renseigner votre mot de passe secret dans le champ ci-dessus pour pouvoir envoyer cette requête.';
        return;
      }

      resStatus.textContent = 'En cours...';
      resContent.textContent = 'Requête transmise à la passerelle Cloudflare Worker...';

      try {
        const fullUrl = '${origin}' + endpoint;
        const options = {
          method: method,
          headers: {
            'Authorization': 'Bearer ' + pwd
          }
        };

        if (method === 'POST') {
          options.headers['Content-Type'] = 'application/json';
          options.body = bodyText;
        }

        const res = await fetch(fullUrl, options);
        resStatus.textContent = 'HTTP ' + res.status + ' ' + res.statusText;

        const contentType = res.headers.get('content-type') || '';
        if (contentType.includes('image/')) {
          const blob = await res.blob();
          const imgUrl = URL.createObjectURL(blob);
          imgPreview.src = imgUrl;
          imgPreview.style.display = 'block';
          resContent.textContent = '[Image PNG reçue avec succès : ' + blob.size + ' octets]';
        } else {
          const data = await res.json().catch(() => res.text());
          resContent.textContent = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
        }
      } catch (err) {
        resStatus.textContent = 'Erreur';
        resContent.textContent = err.message;
      }
    }
  </script>
</body>
</html>`;
}
