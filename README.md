# AI OS

Un système d'exploitation atteignable depuis une seule URL : une page web qui
devient un bureau complet, construite et étendue par un agent IA au langage
naturel. Le navigateur porte l'interface ; une VM QEMU (Ubuntu 26.10, noyau
7.3.1) porte la puissance de calcul, les logiciels et le stockage.

## Architecture

```
Navigateur ──► Cloudflare Worker « ai-os » ──► tunnel durable « ai-os » ──► pont d'interaction
   │            (API : auth, relais)              (cloudflared nommé)          │  (runner)
   │                  │                                  ▲                     │
   │                  │             Worker « ai-os-desk » ┘ (liaison VPC)      ▼
   │                  │             = le lien interactif fixe        VM QEMU (Ubuntu 26.10 / 7.3.1)
   │                                                                     XFCE sur Xvfb :99, utilisateur aios
   │
   └─ état persistant ◄── checkpoints chiffrés (GPG AES256) ── JeanHug/ai-os-data-private
```

Le tunnel est **durable** : un tunnel nommé Cloudflare créé via l'API
(`CLOUDFLARE_TOKEN`), dont le connecteur se relance avec un jeton dédié. Son
URL publique (`ai-os-desk.hugdu77777.workers.dev`, reliée au tunnel par liaison
VPC) est **fixe** — plus aucune URL `trycloudflare` éphémère, plus aucune
publication d'URL à découvrir.

Trois familles d'applications pourront cohabiter : pures pages web, pages avec
dos sur la VM (API d'interaction ou services locaux), et fenêtres diffusant un
bureau distant.

## Dépôt

```
config/aios.conf                  valeurs communes (noyau, image, timings, instance-id)
scripts/lib-common.sh             constantes, KVM, SSH, journalisation
scripts/lib-cloudinit.sh          génération du seed cloud-init (minime, rapide)
scripts/qemu-cycle.sh             le cycle en phases : restore, boot, install-desktop,
                                  bridge, tunnel, publish, produce, dispatch, overlap, stop
scripts/qemu-live.sh              session de diagnostic jetable (tunnels-linux-live.json)
scripts/qemu-validation.sh        validation OS + noyau (KVM obligatoire)
scripts/aios-data.sh              sauvegarde / restauration chiffrée
scripts/qemu-interaction-bridge.cjs  pont d'interaction (authentifié, port 3001)
scripts/qemu-publish-tunnel.cjs   publication du statut du tunnel (branche tunnel-url)
scripts/deploy-cloudflare-worker.cjs déploiement des Workers « ai-os » et « ai-os-desk »
cloudflare-worker/worker.js       passerelle publique (auth, relais, documentation)
cloudflare-worker/desk-worker.js  lien interactif (transparence HTTP/WebSocket vers le pont)
```

## Workflows (tous `workflow_dispatch`)

| Workflow | Rôle |
|---|---|
| `AI OS QEMU - relais et sauvegarde` | production : le cycle complet, découpé en étapes visibles (ci-dessous) |
| `AI OS QEMU - capture expérimentale` | diagnostic jetable, sans sauvegarde, publié sous `tunnels-linux-live.json` |
| `AI OS QEMU - validation experimentale` | vérifie Ubuntu 26.10 + noyau 7.3.1 (KVM obligatoire, jamais de TCG) |

### Le cycle de production, étape par étape

```
Restaurer le checkpoint chiffré (ou créer le disque)     ~5 min
Démarrer la VM et attendre qu'elle soit prête            ~1-2 min
Installer le bureau et les outils d'interaction          ~1-2 min (idempotent)
Démarrer le pont d'interaction                           ~2 s
Déployer le tunnel cloudflared                           ~20 s
Publier l'URL et vérifier l'API d'interaction            ~5 s
Phase de production (période d'utilisation)               5 h 00   ← le service est en ligne
Créer et lancer le workflow suivant                      ~2 s
Chevauchement — continuer à servir les requêtes          30 min   ← le successeur restaure
Auto-arrêt propre et sauvegarde chiffrée                 ~5 min
```

Chaque ligne est une étape visible dans l'onglet Actions. Les durées de la
production et du chevauchement se règlent dans `config/aios.conf`
(`AIOS_PRODUCE_SECONDS`, `AIOS_OVERLAP_SECONDS`).

## Secrets

| Secret GitHub | Usage |
|---|---|
| `GH_TOKEN` | API GitHub : checkpoint, publication du statut, déclenchement du relais |
| `AIOS_BACKUP_KEY` | chiffrement GPG des checkpoints. **Irrécupérable s'il est perdu.** |
| `AIOS_VM_SSH_KEY` | clé SSH de l'invité (la clé publique est ancrée dans le checkpoint) |
| `VM_API_TOKEN` | jeton du pont d'interaction (≥ 32 caractères) |
| `CLOUDFLARE_ID` / `CLOUDFLARE_TOKEN` | compte Cloudflare : tunnel durable nommé, jeton connecteur |

Secrets du Worker `ai-os` : `PASS` (code d'accès actuel) et `VM_API_TOKEN`.
Le Worker `ai-os-desk` (lien interactif) n'a aucun secret : il s'appuie sur la
liaison VPC vers le tunnel durable, et l'authentification reste au pont.

## Relais blue-green

La production dure 5 h 00 ; le cycle suivant est alors **créé et lancé** comme
nouveau run de workflow, avec l'identifiant du cycle courant en paramètre.
Pendant le **chevauchement** (30 min), le successeur attend le `CHECKPOINT`,
restaure, démarre et publie son tunnel — puis le cycle courant s'auto-arrête
et sauvegarde. La coupure perçue est nulle tant que la restauration du
successeur tient dans le chevauchement.

Contraintes mesurées (run `42384041709`, checkpoint de 1,9 Go) :
sauvegarde ≈ 5 min, restauration + démarrage ≈ 8 min ; les deux croissent
linéairement avec la taille du disque. Jauge critique : entre 8 et 12 Go de
disque, le chevauchement de 30 min ne suffit plus — voir les options d'évolution
(base dorée immuable + deltas par bitmap QEMU) dans la documentation de projet.

Contraintes dures du runner GitHub (dépôt **public** : 4 vCPU, 16 Go RAM,
**14 Go SSD**) : ne jamais rendre ce dépôt privé (2 vCPU / 8 Go), et surveiller
l'espace disque — `aios-data.sh` refuse une sauvegarde sans 3,5 Go de marge.

## Sauvegarde

`qemu-img check` → `gzip -1` → `gpg --symmetric --cipher-algo AES256 --s2k-mode 3`
→ fragments de 45 Mo → `SHA256SUMS` + `CHECKPOINT` + `CREATED_AT` → branche
orpheline `snapshot` de `JeanHug/ai-os-data-private` (privé).
La restauration vérifie le `CHECKPOINT` attendu **et** chaque somme SHA256
avant déchiffrement. Génération unique : la branche est réécrite à chaque cycle.

## Bureau interactif

**`app/index.html`** est l'unique porte d'entrée, déployée à deux endroits :
GitHub Pages (`jeanhug.github.io/AI-OS/app/`) et le Worker (`/app`).
Page blanche, un seul champ : le code d'accès. Aucun mot de passe n'est écrit
dans le code source — le code est vérifié par le Worker (`POST /grant`), qui
répond par un jeton signé HMAC valable 4 h et renvoie vers le bureau.

- `app/` → le code → redirection vers le lien interactif fixe **avec** le jeton
  signé → bureau (noVNC à travers le tunnel durable).
- Le lien interactif ouvert **sans** autorisation → redirection vers `app/`.
- Le navigateur mémorise l'accès (cookie) : 4 h d'utilisation directe.
- L'API d'interaction reste derrière le Worker `ai-os` (Bearer), jamais exposée
  comme interface.

Le code d'accès vit uniquement dans le secret `PASS` du Worker.

## API d'interaction (pont, auth `Bearer VM_API_TOKEN`)

| Route | Rôle |
|---|---|
| `GET /health` | état du pont |
| `GET /api/linux/status` | noyau, Xvfb, XFCE, outils disponibles |
| `GET /api/linux/system` | uname, OS, mémoire, disque |
| `GET /api/linux/screenshot` | capture PNG de l'affichage |
| `POST /api/linux/exec` | `{command, timeout_sec}` — shell dans la VM |
| `POST /api/linux/mouse` | `{action: move\|click\|dblclick\|scroll, x, y, button, direction, amount}` |
| `POST /api/linux/keyboard` | `{key: "ctrl+s"}` ou `{text: "…"}` |
| `GET/POST /api/linux/clipboard` | lecture / écriture du presse-papier |
| `GET /api/linux/files` · `files/read` · `POST files/write` · `DELETE files` | fichiers, strictement sous `/home/aios` |
| `POST /api/linux/apps/launch` | `{app, args[]}` (noms validés par liste blanche) |
| `GET /api/linux/processes` | top des processus |

Toutes les routes existent aussi sous `/api/v1/*`. Le Worker `ai-os` les relaye
après vérification du code d'accès ; chaque réponse porte `X-Linux-Daemon: 1`,
ce qui permet au Worker de distinguer une erreur légitime d'un pont absent.

Sécurité du pont : aucune interpolation shell côté runner (scripts invités
envoyés par stdin, données en base64 strict), jeton comparé à temps constant,
chemins de fichiers cantonnés au domicile invité.

## Configuration et évolution

Tout est dans `config/aios.conf` :

- **Version du noyau** : modifier `AIOS_KERNEL_*` (une seule place).
- **Ajouter des paquets à la VM** : les ajouter dans `aios_guest_packages`
  (`scripts/lib-common.sh`) — l'étape « Installer le bureau et les outils » les
  pose idempotemment au cycle suivant, sans rien réinstaller de déjà présent.
- **Modèle de CPU** : `AIOS_QEMU_CPU` (défaut `host`). Un modèle nommé stable
  est nécessaire le jour où les checkpoints seront restaurés sur des runners de
  générations différentes — à valider d'abord avec le workflow de validation.

## Pistes ouvertes

1. Relais à coupure quasi nulle : base dorée immuable + deltas par bitmap QEMU
   persistant (sauvegardes incrémentales sans arrêt de la VM).
2. Authentification par jeton Firebase (remplacera le code à 4 chiffres,
   décision prise pour plus tard).
3. Le bureau web HTML (barre d'apps, apps installables, fenêtres, permissions)
   et le moteur d'agence de l'agent IA — le cœur du projet.
