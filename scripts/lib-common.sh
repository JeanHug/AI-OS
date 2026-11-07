#!/usr/bin/env bash
# lib-common.sh — constantes et fonctions partagées par tous les scripts QEMU de AI OS.
#
# Ce fichier est la seule source de vérité pour : l'image Ubuntu, le noyau,
# les paquets, les identifiants de la VM, les paramètres QEMU et les timings.
# Aucune de ces valeurs ne doit être recopiée dans un autre script.
#
# Usage : source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"

# ---------------------------------------------------------------------------
# Emplacements
# ---------------------------------------------------------------------------
AIOS_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIOS_REPO_ROOT="$(cd "$AIOS_SCRIPTS_DIR/.." && pwd)"
AIOS_CONFIG_FILE="$AIOS_REPO_ROOT/config/aios.conf"

[[ -r "$AIOS_CONFIG_FILE" ]] || { echo "lib-common: config/aios.conf introuvable" >&2; return 1 2>/dev/null || exit 1; }
# shellcheck source=../config/aios.conf
source "$AIOS_CONFIG_FILE"

# ---------------------------------------------------------------------------
# Dépôts GitHub
# ---------------------------------------------------------------------------
AIOS_CODE_REPO="${AIOS_CODE_REPO:-JeanHug/AI-OS}"
AIOS_DATA_REPO="${AIOS_DATA_REPO:-JeanHug/ai-os-data-private}"
AIOS_DATA_BRANCH="${AIOS_DATA_BRANCH:-snapshot}"
AIOS_TUNNEL_BRANCH="${AIOS_TUNNEL_BRANCH:-tunnel-url}"
AIOS_TUNNEL_FILE="${AIOS_TUNNEL_FILE:-tunnels-linux.json}"

# ---------------------------------------------------------------------------
# QEMU — valeurs par défaut, surchargeables par variable d'environnement
# ---------------------------------------------------------------------------
# AIOS_QEMU_CPU : modèle de CPU exposé au guest.
#
# « host » reproduit le modèle exact du processeur physique du runner. Les
# runners GitHub ne sont pas homogènes : un checkpoint créé sur un runner peut
# être restauré sur un autre, avec un CPU différent. Passer à un modèle nommé
# stable rend l'image portable, mais DOIT être validé avant mise en production
# car un modèle non supporté par l'hôte empêche QEMU de démarrer.
# Validation : lancer le workflow « qemu-validation » avec AIOS_QEMU_CPU réglé
# sur le modèle visé, puis basculer la valeur par défaut ici.
AIOS_QEMU_CPU="${AIOS_QEMU_CPU:-host}"
AIOS_QEMU_MACHINE="${AIOS_QEMU_MACHINE:-q35,accel=kvm}"
AIOS_QEMU_MEM_MB="${AIOS_QEMU_MEM_MB:-3072}"
AIOS_QEMU_SMP="${AIOS_QEMU_SMP:-2}"
AIOS_DISK_SIZE="${AIOS_DISK_SIZE:-16G}"

# ---------------------------------------------------------------------------
# Invité
# ---------------------------------------------------------------------------
AIOS_GUEST_USER="${AIOS_GUEST_USER:-aios}"
AIOS_GUEST_DISPLAY="${AIOS_GUEST_DISPLAY:-:99}"
AIOS_GUEST_RESOLUTION="${AIOS_GUEST_RESOLUTION:-1280x720x24}"
AIOS_SSH_PORT="${AIOS_SSH_PORT:-22222}"
AIOS_KERNEL_MARKER="/var/lib/aios-kernel-installed"

# ---------------------------------------------------------------------------
# Services sur le runner
# ---------------------------------------------------------------------------
AIOS_BRIDGE_PORT="${AIOS_BRIDGE_PORT:-3001}"
AIOS_BRIDGE_HOST="${AIOS_BRIDGE_HOST:-127.0.0.1}"
CLOUDFLARED_URL="${CLOUDFLARED_URL:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64}"

# ---------------------------------------------------------------------------
# Timings du relais (secondes, mesurées depuis l'instant où la VM est prête)
# ---------------------------------------------------------------------------
# AIOS_RELAY_TRIGGER_SECONDS : instant auquel le cycle suivant est déclenché.
# AIOS_RELAY_SHUTDOWN_SECONDS : instant auquel l'invité est arrêté pour sauvegarde.
# Le chevauchement est la différence entre les deux. Il doit rester supérieur à
# AIOS_HANDOVER_BUDGET_SECONDS pour que le successeur ait le temps de restaurer
# le checkpoint et de publier son tunnel avant la mort du prédécesseur.
AIOS_RELAY_TRIGGER_SECONDS="${AIOS_RELAY_TRIGGER_SECONDS:-18000}"   # 5 h 00
AIOS_RELAY_SHUTDOWN_SECONDS="${AIOS_RELAY_SHUTDOWN_SECONDS:-19800}" # 5 h 30 → chevauchement 30 min
AIOS_HANDOVER_BUDGET_SECONDS="${AIOS_HANDOVER_BUDGET_SECONDS:-900}" # 15 min nécessaires au successeur

# Budget total du job GitHub Actions, en secondes. La limite dure du runner est
# de 6 h ; on garde une réserve pour l'arrêt propre et la sauvegarde.
AIOS_JOB_BUDGET_SECONDS="${AIOS_JOB_BUDGET_SECONDS:-21600}"

# Garde-fous de la sauvegarde
# Espace disque libre minimal avant d'engager une sauvegarde, en ko.
# La sauvegarde a besoin de : le disque vivant + les fragments chiffrés + le
# dépôt git et ses objets. On exige 3,5 Go de marge.
AIOS_MIN_FREE_KB="${AIOS_MIN_FREE_KB:-3670016}"

# Intervalle de sauvegarde périodique — non utilisé tant que les deltas
# incrémentaux ne sont pas implémentés ; réservé pour la suite.
AIOS_PERIODIC_SAVE_SECONDS="${AIOS_PERIODIC_SAVE_SECONDS:-600}"

# ---------------------------------------------------------------------------
# Journalisation
# ---------------------------------------------------------------------------
aios_log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
aios_warn() { printf '[%s] AVERTISSEMENT : %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
aios_die()  { printf '[%s] ERREUR : %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

# Vérifie qu'une variable d'environnement est présente et non vide.
aios_require_env() {
  local missing=0 name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      printf 'Variable requise absente : %s\n' "$name" >&2
      missing=1
    fi
  done
  (( missing == 0 )) || exit 1
}

# ---------------------------------------------------------------------------
# KVM
# ---------------------------------------------------------------------------
# Exige l'accélération matérielle. Le repli silencieux en émulation TCG a déjà
# coûté un run de 16 minutes : il est interdit partout.
aios_require_kvm() {
  [[ -e /dev/kvm ]] || aios_die "/dev/kvm absent : ce runner ne fournit pas la virtualisation matérielle. Émulation TCG refusée."
  sudo chown "$(id -u):$(id -g)" /dev/kvm
  sudo chmod 660 /dev/kvm
  [[ -r /dev/kvm && -w /dev/kvm ]] || aios_die "/dev/kvm présent mais inaccessible en lecture/écriture."
  aios_log "Accélération KVM disponible."
}

# ---------------------------------------------------------------------------
# Outillage invité
# ---------------------------------------------------------------------------
# Outils X requis par le futur système d'interaction (souris, clavier,
# presse-papier, fenêtres, captures). Le démon d'interaction en dépend.
aios_guest_packages() {
  printf '%s\n' \
    openssh-server curl ca-certificates \
    xfce4 xfce4-terminal xvfb scrot \
    xdotool xclip xsel autocutsel wmctrl x11-utils imagemagick \
    python3 python3-pip git build-essential
}

# ---------------------------------------------------------------------------
# SSH vers l'invité
# ---------------------------------------------------------------------------
# Construit le tableau d'options SSH. Usage :
#   local -a opts; aios_ssh_options opts "$key" "$known_hosts"
#   ssh "${opts[@]}" "$AIOS_GUEST_USER@127.0.0.1" '…'
aios_ssh_options() {
  local -n _out=$1
  _out=(
    -i "$2"
    -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$3"
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ServerAliveInterval=15
    -p "$AIOS_SSH_PORT"
  )
}

# ---------------------------------------------------------------------------
# Image Ubuntu
# ---------------------------------------------------------------------------
# Télécharge l'image cloud Ubuntu et vérifie sa somme SHA256.
# $1 = répertoire de destination, $2 = nom du fichier image résultant
aios_fetch_ubuntu_image() {
  local dest=$1 out=$2 sums
  sums="$(mktemp)"
  curl -fsSLo "$sums" "$AIOS_UBUNTU_BASE/SHA256SUMS" || { rm -f "$sums"; return 1; }
  curl -fSL --retry 3 --retry-delay 2 -o "$dest/$AIOS_UBUNTU_IMAGE" "$AIOS_UBUNTU_BASE/$AIOS_UBUNTU_IMAGE" || { rm -f "$sums"; return 1; }
  ( cd "$dest" && grep -F "*$AIOS_UBUNTU_IMAGE" "$sums" | sha256sum -c - ) || { rm -f "$sums"; return 1; }
  rm -f "$sums"
  mv "$dest/$AIOS_UBUNTU_IMAGE" "$dest/$out"
}
