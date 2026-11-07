# AI OS

Un système d'exploitation atteignable depuis une seule URL : une page web qui
devient un bureau complet, construite et étendue par un agent IA au langage
naturel. Le navigateur porte l'interface ; une VM QEMU (Ubuntu 26.10, noyau
7.3.1) porte la puissance de calcul, les logiciels et le stockage.

## Architecture

```
Navigateur ──► Cloudflare Worker « ai-os » ──► tunnel cloudflared ──► pont d'interaction
   │                  │                                                  │  (runner)
   │                  ├─ lit l'URL du tunnel sur la branche tunnel-url    │
   │                  └─ authentification (PASS) + relais des routes      │
   │                                                                     ▼
   │                                                    VM QEMU (Ubuntu 26.10 / 7.3.1)
   │                                                    XFCE sur Xvfb :99, utilisateur aios
   │
   └─ état persistant ◄── checkpoints chiffrés (GPG AES256) ── JeanHug/ai-os-data-private
```

Trois familles d'applications pourront cohabiter : pures pages web, pages avec
dos sur la VM (API d'interaction ou services locaux), et fenêtres diffusant un
bureau distant.

## Dépôt

```
config/aios.conf                  valeurs communes (noyau, image, timings, instance-id)
scripts/lib-common.sh             constantes, KVM, SSH, journalisation
scripts/lib-cloudinit.sh          génération du seed cloud-init (unique)
scripts/qemu-durable.sh           cycle de production : restauration, bureau, tunnel, relais, sauvegarde
scripts/qemu-live.sh              session de diagnostic jetable (tunnels-linux-live.json)
scripts/qemu-validation.sh        validation OS + noyau (KVM obligatoire)
scripts/aios-data.sh              sauvegarde / restauration chiffrée
scripts/qemu-interaction-bridge.cjs  pont d'interaction (authentifié, port 3001)
scripts/qemu-publish-tunnel.cjs   publication de l'URL du tunnel
scripts/deploy-cloudflare-worker.cjs déploiement du Worker « ai-os »
cloudflare-worker/worker.js       passerelle publique (auth, relais, documentation)
```

## Workflows (tous `workflow_dispatch`)

| Workflow | Rôle |
|---|---|
| `AI OS QEMU - relais et sauvegarde` | production : la VM vit ~5 h 30, puis arrêt propre, checkpoint chiffré, déclenchement du cycle suivant en chevauchement |
| `AI OS QEMU - capture expérimentale` | diagnostic jetable, sans sauvegarde, publié sous `tunnels-linux-live.json` |
| `AI OS QEMU - validation experimentale` | vérifie Ubuntu 26.10 + noyau 7.3.1 (KVM obligatoire, jamais de TCG) |

## Secrets

| Secret GitHub | Usage |
|---|---|
| `GH_TOKEN` | API GitHub : checkpoint, publication du tunnel, déclenchement du relais |
| `AIOS_BACKUP_KEY` | chiffrement GPG des checkpoints. **Irrécupérable s'il est perdu.** |
| `AIOS_VM_SSH_KEY` | clé SSH de l'invité (la clé publique est ancrée dans le checkpoint) |
| `VM_API_TOKEN` | jeton du pont d'interaction (≥ 32 caractères) |

Secrets du Worker `ai-os` : `PASS` (code d'accès actuel) et `VM_API_TOKEN`.

## Relais blue-green

Le cycle suivant est déclenché **30 minutes** avant l'arrêt du cycle courant
(`AIOS_RELAY_TRIGGER_SECONDS=18000`, `AIOS_RELAY_SHUTDOWN_SECONDS=19800`).
Pendant ce chevauchement, le successeur attend le `CHECKPOINT`, restaure,
démarre, publie son tunnel — le Worker lit automatiquement la nouvelle URL.
La coupure perçue est nulle tant que la restauration tient dans le chevauchement.

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
  (`scripts/lib-common.sh`), puis incrémenter `AIOS_INSTANCE_ID_*`. Le prochain
  redémarrage du checkpoint existant ré-exécute les modules cloud-init et
  installe les paquets manquants — le noyau est verrouillé par un marqueur et
  n'est jamais réinstallé. Un passage convergent post-démarrage couvre les
  anciens checkpoints.
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
