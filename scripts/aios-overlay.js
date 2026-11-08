/**
 * aios-overlay.js — surcouche AI OS posée sur l'interface noVNC classique.
 *
 * Ajoute, SANS rien modifier de noVNC (ni ses clics, ni son panneau) :
 *   - le petit bouton flottant plein écran (noir, glyphe blanc, déplaçable) ;
 *   - le clavier automatique : il s'ouvre dès qu'un champ texte est actif dans
 *     la VM (AT-SPI) et se ferme tout seul (ouverture liée au geste utilisateur,
 *     seule forme autorisée par les navigateurs) ;
 *   - l'adaptation du bureau à la zone VISIBLE de l'appareil (largeur), jamais
 *     perturbée par l'ouverture du clavier ;
 *   - l'écran qui ne s'éteint pas, une aide brève au premier lancement.
 *
 * Le jeton de bureau est lu dans l'URL de la page, ou à défaut dans le
 * localStorage / cookie lisible / nom de fenêtre (posés par mobile.html).
 */
(function () {
  'use strict';

  var API = 'https://ai-os.hugdu77777.workers.dev';

  // -------------------------------------------------------------------------
  // Jeton de bureau
  // -------------------------------------------------------------------------
  function getSig() {
    try {
      var q = new URLSearchParams(location.search).get('s');
      if (q) return q;
      var saved = JSON.parse(localStorage.getItem('aios.sig') || 'null');
      if (saved && saved.v && (!saved.exp || saved.exp > Math.floor(Date.now() / 1000))) return saved.v;
    } catch (e) {}
    var m = document.cookie.match(/(?:^|;\s*)aios_t=([^;]+)/);
    if (m) { try { return decodeURIComponent(m[1]); } catch (e) {} }
    if (window.name && window.name.indexOf('aios:') === 0) return window.name.slice(5);
    return '';
  }
  var sig = getSig();
  function apiUrl(path) {
    return API + path + (sig ? (path.indexOf('?') >= 0 ? '&' : '?') + 's=' + encodeURIComponent(sig) : '');
  }

  // -------------------------------------------------------------------------
  // Styles (le bouton, lui, porte ses styles EN LIGNE : incontestables)
  // -------------------------------------------------------------------------
  var css = [
    '#aios-pill{position:fixed;top:calc(10px + env(safe-area-inset-top));left:50%;transform:translateX(-50%);z-index:2000;',
    'background:rgba(0,0,0,.62);border:1px solid rgba(255,255,255,.18);border-radius:999px;padding:6px 14px;',
    'font-size:12.5px;font-family:system-ui,sans-serif;color:#eee;opacity:0;transition:opacity .35s;',
    'pointer-events:none;white-space:nowrap}',
    '#aios-pill.aios-show{opacity:1}',
    '#aios-kbar{position:fixed;left:0;right:0;z-index:2050;bottom:0;display:none;gap:5px;overflow-x:auto;',
    'padding:7px calc(8px + env(safe-area-inset-left)) calc(7px + env(safe-area-inset-bottom));',
    'background:rgba(12,12,12,.97);border-top:1px solid rgba(255,255,255,.14);-webkit-overflow-scrolling:touch}',
    '#aios-kbar.aios-show{display:flex}',
    '#aios-kbar button{flex:0 0 auto;min-width:40px;height:38px;border-radius:9px;background:#232323;color:#eee;',
    'border:1px solid rgba(255,255,255,.14);font-size:13px;padding:0 10px;font-family:system-ui,sans-serif}',
    '#aios-kbar button.aios-on{background:#3b6fd4;border-color:#6a95e8}',
    '#aios-ime{position:fixed;left:0;right:0;bottom:0;z-index:2040;height:2px;width:100%;opacity:.01;border:0;',
    'outline:0;background:transparent;color:transparent;font-size:16px}',
    '#aios-tuto{position:fixed;inset:0;z-index:2200;display:none;background:rgba(0,0,0,.78);place-items:center;padding:22px}',
    '#aios-tuto.aios-show{display:grid}',
    '#aios-tuto .card{background:#161616;border:1px solid rgba(255,255,255,.2);border-radius:18px;padding:22px;max-width:400px;',
    'font-family:system-ui,sans-serif;color:#eee}',
    '#aios-tuto h2{margin:0 0 14px;font-size:18px;font-weight:600}',
    '#aios-tuto ul{margin:0 0 18px;padding-left:20px}',
    '#aios-tuto li{margin:8px 0;font-size:14px;line-height:1.45;color:#ddd}',
    '#aios-tuto button{width:100%;height:46px;border-radius:12px;border:0;background:#2b5fc7;color:#fff;font-size:15px}',
  ].join('\n');
  var style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  function el(html) {
    var d = document.createElement('div');
    d.innerHTML = html.trim();
    return d.firstChild;
  }

  var pill = el('<div id="aios-pill"></div>');
  var fsBtn = el(
    '<button id="aios-fs" aria-label="Plein écran" style="position:fixed;z-index:2100;' +
    'width:26px;height:26px;min-width:26px;max-width:26px;padding:0;margin:0;border-radius:50%;' +
    'background:#000;border:1.5px solid rgba(255,255,255,.6);box-shadow:0 3px 10px rgba(0,0,0,.55);' +
    'display:block;overflow:hidden;box-sizing:border-box;cursor:pointer;opacity:.65;' +
    'right:10px;top:38%;line-height:0">' +
    '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" style="display:block">' +
    '<path id="aios-fsicon" d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/></svg></button>'
  );
  var kbar = el(
    '<div id="aios-kbar">' +
    '<button data-k="hide">⌄</button>' +
    '<button data-k="Esc">Esc</button><button data-k="Tab">Tab</button>' +
    '<button data-k="Ctrl" class="mod">Ctrl</button><button data-k="Alt" class="mod">Alt</button>' +
    '<button data-k="Shift" class="mod">Maj</button><button data-k="Super">⊞</button>' +
    '<button data-k="Left">←</button><button data-k="Up">↑</button><button data-k="Down">↓</button>' +
    '<button data-k="Right">→</button><button data-k="Backspace">⌫</button><button data-k="Enter">↵</button>' +
    '<button data-k="Delete">Suppr</button><button data-k="CAD">Ctrl+Alt+Suppr</button>' +
    '</div>'
  );
  var ime = el('<textarea id="aios-ime" autocapitalize="off" autocomplete="off" autocorrect="on" spellcheck="true"></textarea>');
  var tuto = el(
    '<div id="aios-tuto"><div class="card"><h2>Piloter le bureau au doigt</h2><ul>' +
    '<li>Tapez pour cliquer, glissez pour déplacer — noVNC gère les clics nativement.</li>' +
    '<li>Le clavier du téléphone s’ouvre tout seul dès qu’un champ texte est actif (trois doigts pour forcer).</li>' +
    '<li>Le bureau épouse la largeur de votre écran ; le petit bouton rond passe en plein écran.</li>' +
    '</ul><button id="aios-tutook">Compris</button></div></div>'
  );
  document.body.appendChild(pill);
  document.body.appendChild(fsBtn);
  document.body.appendChild(kbar);
  document.body.appendChild(ime);
  document.body.appendChild(tuto);

  function say(msg, ms) {
    pill.textContent = msg;
    pill.classList.add('aios-show');
    clearTimeout(say._t);
    say._t = setTimeout(function () { pill.classList.remove('aios-show'); }, ms || 2200);
  }
  function buzz(m) { try { navigator.vibrate && navigator.vibrate(m); } catch (e) {} }

  // -------------------------------------------------------------------------
  // Clavier : touches synthétiques vers le conteneur noVNC
  // -------------------------------------------------------------------------
  function fireKey(type, key, code, keyCode) {
    var target = document.getElementById('noVNC_container') || document.body;
    var ev = new KeyboardEvent(type, { key: key, code: code, bubbles: true, cancelable: true, view: window });
    Object.defineProperty(ev, 'keyCode', { get: function () { return keyCode; } });
    Object.defineProperty(ev, 'which', { get: function () { return keyCode; } });
    target.dispatchEvent(ev);
  }
  var KEY = {
    Esc: ['Escape', 'Escape', 27], Tab: ['Tab', 'Tab', 9],
    Ctrl: ['Control', 'ControlLeft', 17], Alt: ['Alt', 'AltLeft', 18],
    Shift: ['Shift', 'ShiftLeft', 16], Super: ['Meta', 'MetaLeft', 91],
    Left: ['ArrowLeft', 'ArrowLeft', 37], Up: ['ArrowUp', 'ArrowUp', 38],
    Down: ['ArrowDown', 'ArrowDown', 40], Right: ['ArrowRight', 'ArrowRight', 39],
    Backspace: ['Backspace', 'Backspace', 8], Enter: ['Enter', 'Enter', 13],
    Delete: ['Delete', 'Delete', 46],
  };
  var sticky = { Ctrl: false, Alt: false, Shift: false };

  var kbOpen = false, kbManual = false, lastFocus = 'none';

  function openKb() {
    if (kbOpen) return;
    kbOpen = true;
    try {
      ime.focus({ preventScroll: true });
      ime.setSelectionRange(0, 0);
    } catch (e) { try { ime.focus(); } catch (e2) {} }
    kbar.classList.add('aios-show');
  }
  function closeKb() {
    if (!kbOpen) return;
    kbOpen = false;
    kbManual = false;
    ime.blur();
    kbar.classList.remove('aios-show');
  }

  ime.addEventListener('input', function () {
    for (var i = 0; i < ime.value.length; i++) {
      var ch = ime.value.charAt(i);
      var cp = ch.charCodeAt(0);
      if (cp === 10) { fireKey('keydown', 'Enter', 'Enter', 13); fireKey('keyup', 'Enter', 'Enter', 13); continue; }
      if (cp < 32) continue;
      var code = cp >= 97 && cp <= 122 ? 'Key' + ch.toUpperCase() : (cp >= 65 && cp <= 90 ? 'Key' + ch : 'Unidentified');
      fireKey('keydown', ch, code, cp);
      fireKey('keyup', ch, code, cp);
    }
    ime.value = '';
  });

  kbar.addEventListener('click', function (e) {
    var b = e.target.closest('button[data-k]');
    if (!b) return;
    buzz(8);
    var k = b.getAttribute('data-k');
    if (k === 'hide') { closeKb(); return; }
    if (k === 'CAD') {
      fireKey('keydown', 'Control', 'ControlLeft', 17);
      fireKey('keydown', 'Alt', 'AltLeft', 18);
      fireKey('keydown', 'Delete', 'Delete', 46);
      fireKey('keyup', 'Delete', 'Delete', 46);
      fireKey('keyup', 'Alt', 'AltLeft', 18);
      fireKey('keyup', 'Control', 'ControlLeft', 17);
      return;
    }
    if (sticky.hasOwnProperty(k) && b.classList.contains('mod')) {
      sticky[k] = !sticky[k];
      b.classList.toggle('aios-on', sticky[k]);
      fireKey(sticky[k] ? 'keydown' : 'keyup', KEY[k][0], KEY[k][1], KEY[k][2]);
      return;
    }
    if (KEY[k]) {
      fireKey('keydown', KEY[k][0], KEY[k][1], KEY[k][2]);
      fireKey('keyup', KEY[k][0], KEY[k][1], KEY[k][2]);
    }
  });

  // -------------------------------------------------------------------------
  // Détection du focus texte (AT-SPI via le Worker) + ouverture au geste
  // -------------------------------------------------------------------------
  function pollFocus() {
    if (!sig || document.hidden) return;
    fetch(apiUrl('/api/desktop/focus'), { method: 'GET' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        lastFocus = (d && d.focus) || 'none';
        if (lastFocus !== 'text' && kbOpen && !kbManual) closeKb();
        if (lastFocus === 'text' && !kbOpen && !kbManual && navigator.userActivation && navigator.userActivation.isActive) {
          openKb();
        }
      })
      .catch(function () {});
  }

  function onGestureStart(e) {
    if (e.touches && e.touches.length >= 3) {
      e.preventDefault();
      e.stopPropagation();
      kbManual = !kbOpen;
      if (kbManual) { openKb(); say('Clavier'); } else { closeKb(); say('Clavier masqué'); }
      return;
    }
    wake();
    if (lastFocus === 'text' && !kbOpen) openKb();
    // Le geste vient de changer le focus dans la VM : on revérifie aussitôt
    // (puis dans la foulée) pour ouvrir le clavier si un champ texte est actif.
    pollFocus();
    setTimeout(pollFocus, 350);
    setTimeout(pollFocus, 1200);
  }
  window.addEventListener('touchstart', onGestureStart, { capture: true, passive: false });
  window.addEventListener('pointerdown', function () {
    wake();
    if (lastFocus === 'text' && !kbOpen) openKb();
    pollFocus();
  }, true);
  setInterval(pollFocus, 1300);

  // -------------------------------------------------------------------------
  // Adaptation à la zone VISIBLE (largeur) — l'ouverture du clavier ne change
  // que la hauteur : elle ne déclenche donc JAMAIS de redimensionnement.
  // -------------------------------------------------------------------------
  var lastW = 0;
  function targetGeom() {
    var w = Math.round((window.innerWidth || 390) * Math.min(window.devicePixelRatio || 1, 2));
    var h = Math.round((window.innerHeight || 844) * Math.min(window.devicePixelRatio || 1, 2));
    var long = Math.max(w, h);
    if (long > 2560) { var k = 2560 / long; w = Math.round(w * k); h = Math.round(h * k); }
    w = Math.max(480, w - (w % 2)); h = Math.max(320, h - (h % 2));
    return { w: w, h: h };
  }

  var resizeAttempts = 0;
  function adaptScreen() {
    lastW = window.innerWidth;
    if (!sig || resizeAttempts >= 2) return;
    fetch(apiUrl('/api/desktop/geom'), { method: 'GET' })
      .then(function (r) { return r.json(); })
      .then(function (g) {
        if (!g || !g.ok) return;
        var t = targetGeom();
        var ratioBad = Math.abs((g.width / g.height) - (t.w / t.h)) > 0.04;
        var widthBad = Math.abs(g.width - t.w) > Math.max(60, t.w * 0.10);
        if (!ratioBad && !widthBad) { resizeAttempts = 0; return; }
        resizeAttempts++;
        say('Adaptation de l’écran à votre appareil…', 6000);
        return fetch(apiUrl('/api/desktop/resize'), {
          method: 'POST',
          headers: { 'Content-Type': 'text/plain' },
          body: JSON.stringify({ width: t.w, height: t.h }),
        });
      })
      .catch(function () {});
  }
  window.addEventListener('resize', function () {
    // Un changement de LARGEUR = rotation ou nouvel affichage → on adapte.
    // Un changement de hauteur seul = clavier → on n'y touche pas.
    if (window.innerWidth !== lastW) setTimeout(adaptScreen, 400);
  });
  window.addEventListener('orientationchange', function () { setTimeout(adaptScreen, 450); });
  document.addEventListener('fullscreenchange', function () {
    setTimeout(adaptScreen, 350);
    wake();
  });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { pollFocus(); setTimeout(adaptScreen, 400); }
  });

  // -------------------------------------------------------------------------
  // Bouton plein écran flottant (26 px, styles en ligne, déplaçable)
  // -------------------------------------------------------------------------
  var ICON_FS = 'M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5';
  var ICON_RESTORE = 'M9 4v5H4M20 9h-5V4M15 20v-5h5M4 15h5v5';
  try {
    var p = JSON.parse(localStorage.getItem('aios.fspos') || 'null');
    if (p && isFinite(p.x) && isFinite(p.y)) {
      fsBtn.style.left = p.x + 'px';
      fsBtn.style.top = p.y + 'px';
      fsBtn.style.right = 'auto';
    }
  } catch (e) {}

  var fsDrag = null;
  fsBtn.addEventListener('pointerdown', function (e) {
    e.preventDefault();
    e.stopPropagation();
    try { fsBtn.setPointerCapture(e.pointerId); } catch (err) {}
    var r = fsBtn.getBoundingClientRect();
    fsDrag = { x0: e.clientX, y0: e.clientY, x: r.left, y: r.top, moved: false };
  });
  fsBtn.addEventListener('pointermove', function (e) {
    if (!fsDrag) return;
    var dx = e.clientX - fsDrag.x0, dy = e.clientY - fsDrag.y0;
    if (!fsDrag.moved && Math.sqrt(dx * dx + dy * dy) < 8) return;
    fsDrag.moved = true;
    fsBtn.style.left = Math.max(4, Math.min(window.innerWidth - 30, fsDrag.x + dx)) + 'px';
    fsBtn.style.top = Math.max(4, Math.min(window.innerHeight - 30, fsDrag.y + dy)) + 'px';
    fsBtn.style.right = 'auto';
    fsBtn.style.opacity = '1';
  });
  fsBtn.addEventListener('pointerup', function () {
    if (!fsDrag) return;
    var moved = fsDrag.moved;
    fsDrag = null;
    fsBtn.style.opacity = '.65';
    if (moved) {
      var r = fsBtn.getBoundingClientRect();
      try { localStorage.setItem('aios.fspos', JSON.stringify({ x: r.left, y: r.top })); } catch (e) {}
    } else {
      toggleFs();
    }
  });

  function toggleFs() {
    buzz(12);
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(function () {});
    } else {
      document.documentElement.requestFullscreen({ navigationUI: 'hide' }).catch(function () {});
    }
  }
  document.addEventListener('fullscreenchange', function () {
    document.getElementById('aios-fsicon').setAttribute('d', document.fullscreenElement ? ICON_RESTORE : ICON_FS);
    wake();
  });

  // -------------------------------------------------------------------------
  // Wake Lock
  // -------------------------------------------------------------------------
  function wake() {
    if (!navigator.wakeLock) return;
    navigator.wakeLock.request('screen').then(function (l) {
      l.addEventListener('release', function () {});
    }).catch(function () {});
  }
  wake();

  // -------------------------------------------------------------------------
  // Tutoriel (première visite)
  // -------------------------------------------------------------------------
  try {
    if (!localStorage.getItem('aios.tuto')) tuto.classList.add('aios-show');
    document.getElementById('aios-tutook').addEventListener('click', function () {
      localStorage.setItem('aios.tuto', '1');
      tuto.classList.remove('aios-show');
    });
  } catch (e) {}

  // -------------------------------------------------------------------------
  // Démarrage
  // -------------------------------------------------------------------------
  setTimeout(function () {
    lastW = window.innerWidth;
    pollFocus();
    adaptScreen();
    wake();
  }, 1200);
})();
