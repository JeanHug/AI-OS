/**
 * aios-overlay.js — surcouche AI OS posée sur l'interface noVNC classique.
 *
 *   - le bouton flottant plein écran (26 px, déplaçable) ; APPUI LONG = menu
 *     d'outils en grille (3 par ligne) ; jusqu'à 3 icônes forment une fine
 *     barre compacte qui remplace le bouton ;
 *   - les outils : plein écran, clavier au tap (mode), curseur de défilement
 *     (mode — le curseur n'apparaît QUE quand le mode est lancé), copier,
 *     coller, presse-papier appareil → VM, VM → appareil — TOUT passe par le
 *     canal VNC lui-même (UI.rfb) : zéro latence ;
 *   - le DÉFILEMENT : fin curseur vertical en bas à droite (poignée petite) ;
 *     vers le haut = défile vers le bas, vers le bas = vers le haut ; vitesse
 *     exponentielle selon l'écart au centre ; lâché, il revient au milieu.
 *     La molette agit à la position du DERNIER CLIC. Aucun geste intercepté ;
 *   - RECONNEXION SUPERVISÉE EN CONTINU (case noVNC cochée + relance toutes
 *     les 3 s si besoin) : la page reste stable, jamais « chargée à l'infini » ;
 *   - l'adaptation du bureau à la zone VISIBLE (plein écran compris), avec
 *     recalage automatique ; l'écran qui ne s'éteint pas ; une aide brève.
 */
(function () {
  'use strict';

  var API = 'https://ai-os.hugdu77777.workers.dev';

  try {
    localStorage.setItem('reconnect', 'true');
    localStorage.setItem('reconnect_delay', '3000');
  } catch (e) {}

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
  // Accès direct à la connexion VNC (window.__aiosUI injecté côté page)
  // -------------------------------------------------------------------------
  function rfbObj() { return (window.__aiosUI && window.__aiosUI.rfb) || null; }
  function canvasEl() { return document.querySelector('#noVNC_container canvas'); }
  function toFb(cx, cy) {
    var c = canvasEl(), r = rfbObj();
    if (!c) return { x: Math.round(cx), y: Math.round(cy) };
    var b = c.getBoundingClientRect();
    var fw = (r && r._fbWidth) || b.width, fh = (r && r._fbHeight) || b.height;
    return {
      x: Math.max(0, Math.round((cx - b.left) * (fw / (b.width || 1)))),
      y: Math.max(0, Math.round((cy - b.top) * (fh / (b.height || 1)))),
    };
  }

  function el(html) {
    var d = document.createElement('div');
    d.innerHTML = html.trim();
    return d.firstChild;
  }
  function svg(paths, size) {
    return '<svg viewBox="0 0 24 24" width="' + (size || 15) + '" height="' + (size || 15) +
      '" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:block">' +
      paths + '</svg>';
  }

  // -------------------------------------------------------------------------
  // Les 7 outils
  // -------------------------------------------------------------------------
  var TOOLS = [
    { id: 'fs', label: 'Plein écran', mode: true,
      icon: '<path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/>' },
    { id: 'kb', label: 'Clavier au tap', mode: true,
      icon: '<rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M6 14h12"/>' },
    { id: 'scroll', label: 'Curseur de défilement', mode: true,
      icon: '<path d="M8 5l4-3 4 3M8 19l4 3 4-3M12 2v20"/>' },
    { id: 'copy', label: 'Copier', mode: false,
      icon: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M4 16V6a2 2 0 0 1 2-2h10"/>' },
    { id: 'paste', label: 'Coller', mode: false,
      icon: '<path d="M9 4h6v3H9zM7 5H5v15h14V5h-2M9 12h6M9 16h6"/>' },
    { id: 'clip2vm', label: 'Presse-papier vers la VM', mode: false,
      icon: '<path d="M12 3v10M8 9l4 4 4-4M4 17h16"/>' },
    { id: 'clip2dev', label: 'Presse-papier vers l’appareil', mode: false,
      icon: '<path d="M12 21V11M8 15l4-4 4 4M4 7h16"/>' },
  ];

  function loadSel() {
    try {
      var v = JSON.parse(localStorage.getItem('aios.bar') || '[]');
      return Array.isArray(v) ? v.filter(function (id) {
        return TOOLS.some(function (t) { return t.id === id; });
      }).slice(0, 3) : [];
    } catch (e) { return []; }
  }
  function loadMode(id) {
    try { return localStorage.getItem('aios.mode.' + id) === '1'; } catch (e) { return false; }
  }
  function saveMode(id, on) {
    try { localStorage.setItem('aios.mode.' + id, on ? '1' : '0'); } catch (e) {}
  }

  var selected = loadSel();
  var modes = { kb: loadMode('kb'), scroll: loadMode('scroll') };

  var pill = el('<div id="aios-pill"></div>');
  var bar = el('<div id="aios-bar"></div>');
  var menu = el('<div id="aios-menu"></div>');
  var tuto = el(
    '<div id="aios-tuto"><div class="card"><h2>Piloter le bureau au doigt</h2><ul>' +
    '<li>Tapez pour cliquer, glissez pour déplacer — noVNC gère les clics nativement.</li>' +
    '<li>Appui LONG sur le bouton : le menu d’outils (jusqu’à 3 icônes dans la barre).</li>' +
    '<li>Activez le mode « curseur » : un fin curseur en bas à droite fait défiler (vers le haut = descendre, vitesse selon l’écart).</li>' +
    '<li>Le bureau épouse votre écran, plein écran compris ; la reconnexion est automatique.</li>' +
    '</ul><button id="aios-tutook">Compris</button></div></div>'
  );
  pill.setAttribute('style', 'position:fixed;top:calc(10px + env(safe-area-inset-top));left:50%;transform:translateX(-50%);' +
    'z-index:2000;background:rgba(0,0,0,.62);border:1px solid rgba(255,255,255,.18);border-radius:999px;padding:6px 14px;' +
    'font-size:12.5px;font-family:system-ui,sans-serif;color:#eee;opacity:0;transition:opacity .35s;pointer-events:none;white-space:nowrap');
  menu.setAttribute('style', 'position:fixed;z-index:2200;display:none;grid-template-columns:repeat(3,auto);justify-items:start;align-items:start;gap:4px;' +
    'background:rgba(16,16,16,.96);border:1px solid rgba(255,255,255,.22);border-radius:12px;padding:8px;box-sizing:border-box');
  tuto.setAttribute('style', 'position:fixed;inset:0;z-index:2300;display:none;background:rgba(0,0,0,.78);place-items:center;padding:22px');
  var tstyle = document.createElement('style');
  tstyle.textContent = '#aios-tuto.aios-show{display:grid}' +
    '#aios-tuto .card{background:#161616;border:1px solid rgba(255,255,255,.2);border-radius:18px;padding:22px;max-width:400px;font-family:system-ui,sans-serif;color:#eee}' +
    '#aios-tuto h2{margin:0 0 14px;font-size:18px;font-weight:600}' +
    '#aios-tuto ul{margin:0 0 18px;padding-left:20px}' +
    '#aios-tuto li{margin:8px 0;font-size:14px;line-height:1.45;color:#ddd}' +
    '#aios-tuto button{width:100%;min-width:0;height:46px;border-radius:12px;border:0;background:#2b5fc7;color:#fff;font-size:15px;-webkit-appearance:none;appearance:none}';
  document.head.appendChild(tstyle);
  document.body.appendChild(pill);
  document.body.appendChild(bar);
  document.body.appendChild(menu);
  document.body.appendChild(tuto);

  function say(msg, ms) {
    pill.textContent = msg;
    pill.style.opacity = '1';
    clearTimeout(say._t);
    say._t = setTimeout(function () { pill.style.opacity = '0'; }, ms || 2200);
  }
  function buzz(m) { try { navigator.vibrate && navigator.vibrate(m); } catch (e) {} }

  // -------------------------------------------------------------------------
  // Actions — canal VNC direct (instantané) ; l'API est le repli.
  // -------------------------------------------------------------------------
  var KEYSYM = { ctrl: 0xffe3, c: 0x63, v: 0x76, x: 0x78, a: 0x61 };
  var CODE = { ctrl: 'ControlLeft', c: 'KeyC', v: 'KeyV', x: 'KeyX', a: 'KeyA' };
  function sendChord(letter) {
    var r = rfbObj();
    if (r && typeof r.sendKey === 'function') {
      try {
        r.sendKey(KEYSYM.ctrl, CODE.ctrl, true);
        r.sendKey(KEYSYM[letter], CODE[letter], true);
        r.sendKey(KEYSYM[letter], CODE[letter], false);
        r.sendKey(KEYSYM.ctrl, CODE.ctrl, false);
        return true;
      } catch (e) {}
    }
    return false;
  }
  function apiPost(path, body) {
    return fetch(apiUrl(path), {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: JSON.stringify(body || {}),
    }).then(function (r) { return r.json(); });
  }

  function toggleFs() {
    buzz(12);
    if (document.fullscreenElement) {
      document.exitFullscreen().catch(function () {});
    } else {
      document.documentElement.requestFullscreen({ navigationUI: 'hide' }).catch(function () {});
    }
  }
  var kbLift = null;
  function liftBar() {
    var vv = window.visualViewport;
    if (!vv) return;
    if (!kbLift) {
      kbLift = { y: bar.style.top, x: bar.style.left, right: bar.style.right, pos: barPos, vh: vv.height };
    }
    var h = bar.getBoundingClientRect().height || 30;
    bar.style.top = Math.max(4, vv.offsetTop + vv.height - h - 10) + 'px';
    bar.style.right = 'auto';
    if (!bar.style.left) bar.style.left = Math.max(4, window.innerWidth - 40) + 'px';
  }
  function unliftBar() {
    if (!kbLift) return;
    var s = kbLift; kbLift = null;
    bar.style.top = s.y || ''; bar.style.left = s.x || ''; bar.style.right = s.right || '';
    barPos = s.pos;
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', function () {
      if (!kbLift) return;
      var vv = window.visualViewport;
      if (vv.height > kbLift.vh - 40) unliftBar(); // clavier refermé
      else liftBar();
    });
  }
  function blurKb() {
    unliftBar();
    var t = document.getElementById('noVNC_keyboardinput');
    if (t && document.activeElement === t) { try { t.blur(); } catch (e) {} }
  }
  function openKb() {
    // Le mode « clavier au tap » est la SEULE autorisation d'ouvrir.
    if (!modes.kb) return;
    var t = document.getElementById('noVNC_keyboardinput');
    if (!t) return;
    try {
      if (document.activeElement === t) t.blur();
      t.focus({ preventScroll: true });
    } catch (e) {}
    liftBar(); // la barre ne monte QUE ici : clic + mode clavier actif
  }
  // Toute autre source de focus (noVNC, clic, code parasite) est neutralisée :
  // sans le mode, le clavier ne s'ouvre JAMAIS.
  document.addEventListener('focusin', function (e) {
    if (e.target && e.target.id === 'noVNC_keyboardinput' && !modes.kb) blurKb();
  }, true);
  function doCopy() {
    if (sendChord('c')) { buzz(8); say('Copié dans la VM'); return; }
    apiPost('/api/desktop/keys', { key: 'ctrl+c' }).then(function () { buzz(8); say('Copié dans la VM'); });
  }
  function doPaste() {
    if (sendChord('v')) { buzz(8); say('Collé dans la VM'); return; }
    apiPost('/api/desktop/keys', { key: 'ctrl+v' }).then(function () { buzz(8); say('Collé dans la VM'); });
  }
  var vmClip = '';
  function hookClip() {
    var r = rfbObj();
    if (!r || hookClip.done || !r.addEventListener) return;
    hookClip.done = true;
    try {
      r.addEventListener('clipboard', function (e) {
        try { vmClip = (e.detail && e.detail.text) || vmClip; } catch (err) {}
      });
    } catch (e) {}
  }
  setInterval(hookClip, 700);
  function doClip2vm() {
    try {
      navigator.clipboard.readText().then(function (t) {
        t = t || '';
        var r = rfbObj();
        if (r && typeof r.clipboardPasteFrom === 'function') {
          try { r.clipboardPasteFrom(t); buzz(8); say('Presse-papier envoyé dans la VM'); return; } catch (e) {}
        }
        return apiPost('/api/desktop/clipboard', { text: t }).then(function () {
          buzz(8); say('Presse-papier envoyé dans la VM');
        });
      }).catch(function () { say('Lecture du presse-papier refusée'); });
    } catch (e) { say('Lecture du presse-papier refusée'); }
  }
  function doClip2dev() {
    var ok = function () { buzz(8); say('Presse-papier copié sur l’appareil'); };
    if (vmClip) {
      navigator.clipboard.writeText(vmClip).then(ok).catch(function () { say('Écriture refusée'); });
      return;
    }
    fetch(apiUrl('/api/desktop/clipboard'), { method: 'GET' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        return navigator.clipboard.writeText((d && d.text) || '').then(ok);
      })
      .catch(function () { say('Écriture refusée'); });
  }
  function runTool(id) {
    if (id === 'fs') { toggleFs(); return; }
    if (id === 'kb') {
      modes.kb = !modes.kb; saveMode('kb', modes.kb);
      if (!modes.kb) blurKb();
      say(modes.kb ? 'Clavier au tap : activé' : 'Clavier au tap : désactivé');
      renderBar(); buzz(8); return;
    }
    if (id === 'scroll') {
      modes.scroll = !modes.scroll; saveMode('scroll', modes.scroll);
      applyScroll();
      say(modes.scroll ? 'Curseur de défilement : affiché' : 'Curseur de défilement : masqué');
      renderBar(); buzz(8); return;
    }
    if (id === 'copy') { doCopy(); return; }
    if (id === 'paste') { doPaste(); return; }
    if (id === 'clip2vm') { doClip2vm(); return; }
    if (id === 'clip2dev') { doClip2dev(); return; }
  }

  // -------------------------------------------------------------------------
  // Fin curseur de défilement (bas droite) — VISIBLE seulement en mode
  // -------------------------------------------------------------------------
  var track = el('<div id="aios-scroll"></div>');
  var knob = el('<div id="aios-scrollknob"></div>');
  track.appendChild(knob);
  track.setAttribute('style', 'position:fixed;right:6px;bottom:calc(46px + env(safe-area-inset-bottom));z-index:2050;' +
    'width:26px;height:33vh;min-height:150px;max-height:300px;border-radius:13px;background:rgba(0,0,0,.30);' +
    'border:1px solid rgba(255,255,255,.30);touch-action:none;opacity:.42;transition:opacity .2s;box-sizing:border-box;display:none');
  knob.setAttribute('style', 'position:absolute;left:2px;right:2px;height:26px;top:calc(50% - 13px);border-radius:8px;' +
    'background:rgba(255,255,255,.78);transition:top .25s ease,background .2s;touch-action:none');
  document.body.appendChild(track);
  function applyScroll() {
    track.style.display = modes.scroll ? 'block' : 'none';
    endScroll();
  }

  var lastCX = null, lastCY = null;
  window.addEventListener('click', function (e) {
    // « Position du dernier clic » = uniquement les clics sur l'écran distant.
    var c = canvasEl();
    if (c && (e.target === c || c.contains(e.target))) {
      lastCX = e.clientX; lastCY = e.clientY;
    }
  }, true);

  var sdrag = null;
  function wheelAt(dir) {
    // EXACTEMENT « déplacer la souris vers un point + utiliser la molette » :
    // même conversion que noVNC (clientToElement), même appel interne
    // (_handleMouseButton) et même séquence de masque que le gestionnaire de
    // molette natif : bmask | (1<<3) pour monter, | (1<<4) pour descendre,
    // puis relâchement.
    var r = rfbObj(), c = canvasEl();
    var pos = null;
    if (c && window.__aiosC2E) {
      var b = c.getBoundingClientRect();
      var cx = (lastCX == null ? b.left + b.width / 2 : lastCX);
      var cy = (lastCY == null ? b.top + b.height / 2 : lastCY);
      try { pos = window.__aiosC2E(cx, cy, c); } catch (e) {}
    }
    if (r && pos && typeof r._handleMouseButton === 'function') {
      try {
        var bm = r._mouseButtonMask || 0;
        r._handleMouseButton(pos.x, pos.y, bm);       // souris déplacée au point
        var m = dir < 0 ? 8 : 16;                     // 8 = molette haut, 16 = bas
        r._handleMouseButton(pos.x, pos.y, bm | m);   // molette pressée
        r._handleMouseButton(pos.x, pos.y, bm);       // molette relâchée
        return;
      } catch (e) {}
    }
    if (pos) {
      // Repli : la molette par xdotool, au même point.
      apiPost('/api/desktop/mouse', {
        action: 'scroll', direction: dir < 0 ? 'up' : 'down',
        x: Math.round(pos.x), y: Math.round(pos.y), amount: 1,
      });
    }
  }
  // ---- Moteur de défilement CONTINU : 50 Hz + accumulation fractionnelle ----
  // Plus aucun « cran » isolé : le flux de crans est continu, et le relâchement
  // lance une inertie naturelle (façon appareil natif).
  var mTimer = null, mAcc = 0, mPerTick = 0;
  function motionSet(perTick) {
    mPerTick = perTick;
    if (mTimer == null) {
      mTimer = setInterval(function () {
        mAcc += mPerTick;
        while (Math.abs(mAcc) >= 1) {
          var n = Math.trunc(mAcc);
          mAcc -= n;
          wheelAt(n > 0 ? 1 : -1);
        }
      }, 16);
    }
  }
  function motionStop() {
    if (mTimer != null) { clearInterval(mTimer); mTimer = null; }
    mAcc = 0; mPerTick = 0;
  }
  function motionInertia(v0) {
    motionStop();
    mPerTick = v0 * 0.016;
    mTimer = setInterval(function () {
      mPerTick *= 0.945;
      if (Math.abs(mPerTick / 0.016) < 0.8) { motionStop(); return; }
      mAcc += mPerTick;
      while (Math.abs(mAcc) >= 1) {
        var n = Math.trunc(mAcc);
        mAcc -= n;
        wheelAt(n > 0 ? 1 : -1);
      }
    }, 16);
  }
  knob.addEventListener('pointerdown', function (e) {
    e.preventDefault();
    e.stopPropagation();
    try { knob.setPointerCapture(e.pointerId); } catch (err) {}
    var r = track.getBoundingClientRect();
    sdrag = { y0: e.clientY, off: 0, h: r.height, t: Date.now(), vel: 0 };
    knob.style.transition = 'none';
    track.style.opacity = '0.95';
    motionStop();
  });
  knob.addEventListener('pointermove', function (e) {
    if (!sdrag) return;
    e.preventDefault();
    var half = sdrag.h / 2 - 13;
    var off = Math.max(-half, Math.min(half, e.clientY - sdrag.y0));
    var now = Date.now(), dt = Math.max(8, now - sdrag.t);
    if (off !== sdrag.off) {
      sdrag.vel = 0.55 * sdrag.vel + 0.45 * ((off - sdrag.off) / dt * 1000); // px/s
    }
    sdrag.t = now;
    sdrag.off = off;
    knob.style.top = (sdrag.h / 2 - 13 + off) + 'px';
    if (!off) { motionSet(0); return; }
    var ratio = Math.min(1, Math.abs(off) / (half || 1));
    // Vitesse EXPONENTIELLE : très lent près du centre, très vite au bout.
    var speed = 0.5 + 55 * (Math.exp(3 * ratio) - 1) / (Math.exp(3) - 1); // crans/s
    var dir = off < 0 ? -1 : 1; // vers le haut = défiler vers le haut (sens voulu)
    motionSet(dir * speed * 0.016); // flux continu à 62 Hz
  });
  function endScroll() {
    if (!sdrag) return;
    var half = sdrag.h / 2 - 13;
    var v = sdrag.vel / (half || 1) * 55; // inertie dans le sens du geste (crans/s)
    v = Math.max(-60, Math.min(60, v));
    sdrag = null;
    knob.style.transition = 'top .25s ease,background .2s';
    knob.style.top = 'calc(50% - 13px)';
    track.style.opacity = '.42';
    if (Math.abs(v) > 2.5) motionInertia(v);
    else motionStop();
  }
  knob.addEventListener('pointerup', endScroll);
  knob.addEventListener('pointercancel', endScroll);

  // -------------------------------------------------------------------------
  // Contrôle flottant : bouton rond 26 px OU fine barre compacte
  // -------------------------------------------------------------------------
  var CTRL_STYLE = 'position:fixed;z-index:2100;touch-action:none;box-sizing:border-box;';
  var barPos = null; // position choisie par l'utilisateur (glissement)
  function posStyle() {
    return barPos ? ('left:' + barPos.x + 'px;top:' + barPos.y + 'px;right:auto;') : 'right:10px;top:38%;';
  }

  function renderBar() {
    bar.innerHTML = '';
    if (selected.length === 0) {
      bar.setAttribute('style', CTRL_STYLE + posStyle() +
        'width:26px;height:26px;padding:0;margin:0;border-radius:50%;background:#000;' +
        'border:1.5px solid rgba(255,255,255,.55);box-shadow:0 3px 10px rgba(0,0,0,.55);' +
        'display:flex;align-items:center;justify-content:center;opacity:.72');
      bar.innerHTML = svg('<path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/>', 15);
    } else {
      bar.setAttribute('style', CTRL_STYLE + posStyle() +
        'display:flex;gap:2px;padding:2px;border-radius:9px;background:rgba(0,0,0,.72);' +
        'border:1.5px solid rgba(255,255,255,.55);box-shadow:0 3px 10px rgba(0,0,0,.55);opacity:.9');
      selected.forEach(function (id) {
        var t = TOOLS.filter(function (x) { return x.id === id; })[0];
        if (!t) return;
        var b = document.createElement('button');
        b.setAttribute('data-id', id);
        b.setAttribute('aria-label', t.label);
        b.setAttribute('style', 'width:26px;height:26px;min-width:0;min-height:0;padding:0;margin:0;border:0;border-radius:6px;flex:0 0 auto;' +
          '-webkit-appearance:none;appearance:none;font-size:0;line-height:0;' +
          'background:transparent;display:flex;align-items:center;justify-content:center;cursor:pointer;box-sizing:border-box');
        if (t.mode && modes[id]) b.style.background = '#2b5fc7';
        b.innerHTML = svg(t.icon, 15);
        bar.appendChild(b);
      });
    }
  }

  var press = null, moved = false;
  bar.addEventListener('pointerdown', function (e) {
    e.preventDefault();
    e.stopPropagation();
    try { bar.setPointerCapture(e.pointerId); } catch (err) {}
    var r = bar.getBoundingClientRect();
    moved = false;
    press = {
      x0: e.clientX, y0: e.clientY, x: r.left, y: r.top,
      iconId: (e.target.closest && e.target.closest('button[data-id]')) ?
        e.target.closest('button[data-id]').getAttribute('data-id') : null,
    };
    clearTimeout(press.lp);
    press.lp = setTimeout(function () {
      if (press && !moved) {
        press.longpressed = true;
        openMenu();
        buzz(14);
      }
    }, 520);
  });
  bar.addEventListener('pointermove', function (e) {
    if (!press) return;
    var dx = e.clientX - press.x0, dy = e.clientY - press.y0;
    if (!moved && Math.sqrt(dx * dx + dy * dy) < 8) return;
    moved = true;
    clearTimeout(press.lp);
    barPos = {
      x: Math.max(4, Math.min(window.innerWidth - 30, press.x + dx)),
      y: Math.max(4, Math.min(window.innerHeight - 30, press.y + dy)),
    };
    bar.style.left = barPos.x + 'px';
    bar.style.top = barPos.y + 'px';
    bar.style.right = 'auto';
  });
  bar.addEventListener('pointerup', function () {
    if (!press) return;
    clearTimeout(press.lp);
    var lp = press.longpressed, icon = press.iconId;
    press = null;
    if (lp) return;
    if (moved) {
      var r = bar.getBoundingClientRect();
      barPos = { x: r.left, y: r.top };
      try { localStorage.setItem('aios.fspos', JSON.stringify({ x: r.left, y: r.top })); } catch (e) {}
      return;
    }
    if (icon) { runTool(icon); return; }
    if (selected.length === 0) { toggleFs(); return; }
    // Un appui simple n'ouvre JAMAIS le menu : seul l'appui long le déploie.
  });

  try {
    var p = JSON.parse(localStorage.getItem('aios.fspos') || 'null');
    if (p && isFinite(p.x) && isFinite(p.y)) {
      barPos = { x: p.x, y: p.y };
      bar.style.left = p.x + 'px';
      bar.style.top = p.y + 'px';
      bar.style.right = 'auto';
    }
  } catch (e) {}

  // -------------------------------------------------------------------------
  // Menu (appui long) : grille de 3 par ligne, tout en tailles INLINE
  // -------------------------------------------------------------------------
  function openMenu() {
    renderMenu();
    var r = bar.getBoundingClientRect();
    menu.style.display = 'grid';
    var mw = menu.offsetWidth, mh = menu.offsetHeight;
    menu.style.left = Math.max(8, Math.min(window.innerWidth - mw - 8, r.left + r.width / 2 - mw / 2)) + 'px';
    menu.style.top = Math.max(8, Math.min(window.innerHeight - mh - 8, r.top + r.height + 10)) + 'px';
  }
  function renderMenu() {
    menu.innerHTML = '';
    TOOLS.forEach(function (t) {
      var b = document.createElement('button');
      b.setAttribute('data-id', t.id);
      b.setAttribute('aria-label', t.label);
      b.setAttribute('style', 'width:28px;height:28px;min-width:0;min-height:0;padding:0;margin:0;flex:0 0 auto;box-sizing:border-box;' +
        '-webkit-appearance:none;appearance:none;font-size:0;line-height:0;' +
        'border-radius:8px;background:#232323;border:1.5px solid rgba(255,255,255,.14);' +
        'display:flex;align-items:center;justify-content:center;cursor:pointer');
      if (selected.indexOf(t.id) >= 0) {
        b.style.background = '#2b5fc7';
        b.style.borderColor = '#7aa5f0';
      }
      b.innerHTML = svg(t.icon, 17);
      menu.appendChild(b);
    });
  }
  menu.addEventListener('click', function (e) {
    var b = e.target.closest('button[data-id]');
    if (!b) return;
    var id = b.getAttribute('data-id');
    var i = selected.indexOf(id);
    if (i >= 0) { selected.splice(i, 1); buzz(8); }
    else if (selected.length < 3) { selected.push(id); buzz(12); }
    else { say('3 icônes maximum'); return; }
    try { localStorage.setItem('aios.bar', JSON.stringify(selected)); } catch (e) {}
    renderMenu();
    renderBar();
  });
  window.addEventListener('pointerdown', function (e) {
    if (menu.style.display === 'grid' && !menu.contains(e.target) &&
        !(bar.contains && bar.contains(e.target))) {
      menu.style.display = 'none';
    }
  }, true);

  renderBar();
  applyScroll();

  // -------------------------------------------------------------------------
  // Tactile : 3 doigts = plein écran ; clavier au tap (mode) — JAMAIS de
  // suppression de touches : les clics restent 100 % natifs.
  // -------------------------------------------------------------------------
  var threeFinger = false, tapT = null;
  window.addEventListener('touchstart', function (e) {
    if (e.touches && e.touches.length >= 3 && !threeFinger) {
      threeFinger = true;
      e.preventDefault();
      e.stopPropagation();
      toggleFs();
      setTimeout(function () { threeFinger = false; }, 900);
    }
  }, { capture: true, passive: false });

  window.addEventListener('touchstart', function (e) {
    if (!modes.kb) { tapT = null; return; }
    if (!e.touches || e.touches.length !== 1 ||
        (bar.contains && bar.contains(e.target)) ||
        (menu.contains && menu.contains(e.target)) ||
        (track.contains && track.contains(e.target))) {
      tapT = null; return;
    }
    tapT = { moved: false };
  }, { capture: true, passive: true });
  window.addEventListener('touchmove', function () {
    if (tapT) tapT.moved = true;
  }, { capture: true, passive: true });
  window.addEventListener('touchend', function () {
    var t = tapT; tapT = null;
    if (t && !t.moved) setTimeout(openKb, 35);
  }, { capture: true, passive: true });

  // -------------------------------------------------------------------------
  // RECONNEXION SUPERVISÉE EN CONTINU : case noVNC cochée (reconnexion auto
  // native) + relance toutes les 3 s si le bouton Connexion apparaît. La page
  // ne reste JAMAIS bloquée en chargement, quel que soit le temps du recalage.
  // -------------------------------------------------------------------------
  function enableNoVncReconnect() {
    try {
      var cb = document.getElementById('noVNC_setting_reconnect');
      if (cb && cb.type === 'checkbox' && !cb.checked) {
        cb.checked = true;
        cb.dispatchEvent(new Event('change', { bubbles: true }));
      }
      var d = document.getElementById('noVNC_setting_reconnect_delay');
      if (d && d.value !== '3000') {
        d.value = '3000';
        d.dispatchEvent(new Event('change', { bubbles: true }));
      }
    } catch (e) {}
  }
  function superviseConnect() {
    enableNoVncReconnect();
    var btn = document.getElementById('noVNC_connect_button');
    if (btn && btn.offsetParent !== null && !btn.disabled) {
      try { btn.click(); buzz(8); } catch (e) {}
    }
    setTimeout(superviseConnect, 3000);
  }
  setTimeout(superviseConnect, 900);

  // -------------------------------------------------------------------------
  // Adaptation à la zone VISIBLE (largeur ET hauteur) : plein écran, rotation…
  // Le clavier du téléphone (hauteur seule) ne déclenche jamais ceci.
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

  var resizeAttempts = 0, resizeBusy = false;

  function adaptScreen() {
    if (location.search.indexOf('aiostest=1') >= 0) return; // banc de test : jamais de recalage
    lastW = window.innerWidth;
    if (!sig || resizeBusy || resizeAttempts >= 6) return;
    resizeBusy = true;
    fetch(apiUrl('/api/desktop/geom'), { method: 'GET' })
      .then(function (r) { return r.json(); })
      .then(function (g) {
        if (!g || !g.ok) { resizeBusy = false; return; }
        var t = targetGeom();
        var widthBad = Math.abs(g.width - t.w) > Math.max(24, t.w * 0.025);
        var heightBad = Math.abs(g.height - t.h) > Math.max(24, t.h * 0.025);
        if (!widthBad && !heightBad) { resizeAttempts = 0; resizeBusy = false; return; }
        resizeAttempts++;
        say('Adaptation de l’écran à votre appareil…', 8000);
        return apiPost('/api/desktop/resize', { width: t.w, height: t.h }).then(function () {
          resizeBusy = false;
        }).catch(function () { resizeBusy = false; });
      })
      .catch(function () { resizeBusy = false; });
  }
  window.addEventListener('resize', function () {
    if (window.innerWidth !== lastW) setTimeout(adaptScreen, 400);
  });
  window.addEventListener('orientationchange', function () { setTimeout(adaptScreen, 450); });
  document.addEventListener('fullscreenchange', function () { setTimeout(adaptScreen, 350); });
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && window.innerWidth !== lastW) setTimeout(adaptScreen, 400);
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
  window.addEventListener('pointerdown', wake, true);

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

  // ---- Banc de test autonome (?aiostest=1) : prouve chaque couche ----
  function runSelfTest() {
    var r = rfbObj(), c = canvasEl();
    var rep = [];
    rep.push('ui=' + !!window.__aiosUI + ' rfb=' + !!r + ' c2e=' + !!window.__aiosC2E +
             ' btn=' + !!(r && typeof r._handleMouseButton === 'function'));
    rep.push('etat=' + (r && r._rfbConnectionState));
    if (c) {
      var b = c.getBoundingClientRect();
      rep.push('canvas=' + c.width + 'x' + c.height + ' rect=' + Math.round(b.width) + 'x' + Math.round(b.height));
    }
    lastCX = null; lastCY = null;
    try { wheelAt(1); rep.push('wheel-bas OK'); } catch (e) { rep.push('wheel KO ' + e.message); }
    setTimeout(function () { try { wheelAt(1); } catch (e) {} }, 250);
    setTimeout(function () { try { wheelAt(-1); } catch (e) {} }, 500);
    setTimeout(function () {
      try { wheelAt(1); } catch (e) {}
      var txt = rep.join(' | ');
      try { localStorage.setItem('aios.test', txt); } catch (e) {}
      apiPost('/api/desktop/clipboard', { text: 'AIOS-TEST ' + txt });
    }, 800);
  }
  if (/[?&]aiostest=1/.test(location.search)) setTimeout(runSelfTest, 3500);

  // ---- Fluidité du flux : encodage net et rapide (Tight/JPEG haut de gamme) ----
  function tuneRfb() {
    var r = rfbObj();
    if (!r) return;
    try {
      if ('qualityLevel' in r) r.qualityLevel = 8;
      if ('compressionLevel' in r) r.compressionLevel = 2;
    } catch (e) {}
    try { r.__aiosTuned = true; } catch (e) {}
  }
  setInterval(function () {
    var r = rfbObj();
    if (r && !r.__aiosTuned) tuneRfb();
  }, 2000);

  setTimeout(function () {
    lastW = window.innerWidth;
    adaptScreen();
    wake();
    hookClip();
    enableNoVncReconnect();
  }, 1200);
})();
