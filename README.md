# AI OS — un bureau Linux, 24 h/24, dans le navigateur

AI OS exécute un **bureau Linux complet (XFCE) dans une VM QEMU**, accessible
depuis n'importe quel navigateur — ordinateur ou téléphone — via une URL
unique, sans installation. Le bureau tourne **en continu** : la chaîne
d'automatisation le fait vivre par cycles successifs, sans trou de service.

---

## Architecture

| Pièce | Rôle |
|---|---|
| **Worker Cloudflare `ai-os`** | L'API publique (jetons, exécution, géométrie, presse-papier…). C'est la seule porte d'entrée applicative. |
| **Tunnel Cloudflare durable « ai-os »** | Le lien interactif (nommé, avec token API — jamais de tunnel éphémère). |
| **Worker `ai-os-desk`** | Proxy muet HTTP + WebSocket (noVNC) vers le pont, via une liaison VPC vers le tunnel. |
| **Pont d'interaction** (`scripts/qemu-interaction-bridge.cjs`) | Sur la machine hôte : sert noVNC, relaie les commandes vers l'invité, vérifie les jetons. |
| **VM QEMU (invité Ubuntu + XFCE)** | Le bureau lui-même : Xvfb, xfce4-session, x11vnc, websockify/noVNC, Chrome. |
| **Workflows GitHub Actions** | `qemu-durable.yml` (le cycle de vie complet) + `qemu-watchdog.yml` (la veille, toutes les 15 min). |

### Le cycle sans trou de service

Chaque run `qemu-durable` : restaure le **checkpoint chiffré** (GPG AES256)
du cycle précédent → démarre la VM → installe le bureau et les outils → pont +
tunnel → **phase de production** (le service) → publie un nouveau checkpoint →
**chevauchement** (l'ancien continue de servir pendant que le successeur
restaure) → relance le workflow suivant. Une sauvegarde ratée n'interrompt
**jamais** le service : elle est retentée toutes les 5 minutes.

---

## L'expérience bureau

Le flux est du **noVNC classique** (ses clics natifs, son menu) habillé par une
surcouche légère (`scripts/aios-overlay.js`, intégrée dans la page) :

- **Bouton plein écran** flottant (grand, déplaçable, position mémorisée).
- **Appui long sur le bouton → menu d'outils** : sept fonctions, **3 icônes
  max** dans une fine barre horizontale qui remplace le bouton :

  | Outil | Type | Effet |
  |---|---|---|
  | ⛶ Plein écran | bascule | entre/sort du plein écran ; le bureau se recalcède sur la nouvelle taille |
  | ⌨ Clavier au tap | mode | chaque tap sur l'écran déploie le clavier (le clavier natif de noVNC sert à la frappe) |
  | ↕ Défiler | mode | le défilement du doigt devient la **molette du PC**, souris positionnée au départ du geste ; désactivé = mode sélectionner (comportement normal) |
  | 🗐 Copier | action | Ctrl+C dans la VM |
  | 🗐 Coller | action | Ctrl+v dans la VM |
  | ⬇ Presse-papier → VM | action | envoie le presse-papier de l'appareil dans la VM |
  | ⬆ VM → presse-papier | action | copie le presse-papier de la VM sur l'appareil |

- **Adaptation automatique du bureau** : la VM passe au format exact de la
  zone visible (rotation, plein écran, appareil) ; **la reconnexion est
  automatique** après recalage — la page ne se recharge jamais.
- Wake Lock (l'écran ne s'éteint pas), tutoriel au premier lancement.

---

## Persistance

- **Checkpoints chiffrés** publiés chaque cycle (et retentés toutes les 5 min
  en cas de panne) : les comptes, le profil Chrome et les fichiers survivent
  d'un cycle à l'autre.
- **Fond d'écran blanc** : écrit systématiquement dans la configuration xfconf
  (`xfce4-desktop.xml`) — plus jamais effacé par un redémarrage.
- **Chrome** est relancé automatiquement après tout redémarrage d'affichage,
  avec son profil (sessions et comptes reconnectés).
- Le redémarrage d'affichage vérifie ses services (bannière RFB, HTTP) et tue
  tout processus fantôme avant de relancer.

---

## API (Worker `ai-os`)

Authentification : jeton de bureau signé (`?s=` HMAC-SHA256, expiration) ou
mot de passe de l'app (en-tête `Bearer`, stocké en secret Worker). Aucun
secret dans le dépôt ni dans les réponses.

| Route | Méthode | Description |
|---|---|---|
| `/grant` | POST | Génère un lien de bureau signé (4 h par défaut) |
| `/` | GET | Sans jeton → l'app ; avec `?s=` → redirection vers le bureau |
| `/api/desktop/geom` | GET | Géométrie actuelle de l'affichage de la VM |
| `/api/desktop/resize` | POST | Recalcule l'affichage X (Xvfb + XFCE + x11vnc + websockify) |
| `/api/desktop/focus` | GET | Détection AT-SPI du champ texte actif (+ rectangle) |
| `/api/desktop/keys` | POST | Envoie des touches (Ctrl+C/V…) à la VM |
| `/api/desktop/mouse` | POST | Souris / molette (défilement) à la VM |
| `/api/desktop/clipboard` | GET/POST | Lecture / écriture du presse-papier de la VM |

---

## Développement

```
app/                  Application web (l'app, servie par Pages + le worker)
cloudflare-worker/
  worker.js           L'API (ai-os)
  desk-worker.js      Le proxy interactif muet (ai-os-desk)
scripts/
  aios-overlay.js     La surcouche bureau (bouton, barre d'outils, adaptation)
  mobile.html         Point d'entrée mobile (jeton conservé, anti-cache)
  qemu-interaction-bridge.cjs   Le pont (noVNC + API invité)
  qemu-cycle.sh       Le cycle de vie (restore, boot, install, chevauchement…)
  lib-common.sh       Installation invité (bureau, flux, Chrome, fond blanc)
  deploy-cloudflare-worker.cjs  Déploiement des workers
.github/workflows/
  qemu-durable.yml    Le workflow du cycle (chaîne permanente)
  qemu-watchdog.yml   La veille (redémarre la chaîne si elle s'arrête)
```

Déploiement : `node scripts/deploy-cloudflare-worker.cjs` (les workers) et les
workflows s'occupent du reste à chaque cycle. Les sauvegardes chiffrées vivent
dans le dépôt privé `aios-data-private`.

## Sécurité

- Repo public : **aucun mot de passe, aucun token** nulle part dans le code.
- Jetons de bureau signés (HMAC-SHA256, expiration) — jamais le secret en clair.
- Tunnel durable nommé (token API Cloudflare en secret GitHub) — aucun lien
  éphémère.
- Le bureau n'est joignable qu'authentifié ; sans jeton, l'utilisateur est
  renvoyé vers l'app.
