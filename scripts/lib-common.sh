#!/usr/bin/env bash
# lib-common.sh — constantes et fonctions partagées par les scripts QEMU de AI OS.
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
# QEMU — surchargeables par variable d'environnement
# ---------------------------------------------------------------------------
# AIOS_QEMU_CPU : « host » reproduit le CPU du runner (rapide mais non
# portable entre runners de générations différentes). Un modèle nommé stable
# rendra les checkpoints portables — à valider avec le workflow de validation
# AVANT de changer la valeur par défaut.
AIOS_QEMU_CPU="${AIOS_QEMU_CPU:-host}"
AIOS_QEMU_MACHINE="${AIOS_QEMU_MACHINE:-q35,accel=kvm}"
AIOS_QEMU_MEM_MB="${AIOS_QEMU_MEM_MB:-3072}"
AIOS_QEMU_SMP="${AIOS_QEMU_SMP:-2}"

# ---------------------------------------------------------------------------
# Invité
# ---------------------------------------------------------------------------
AIOS_GUEST_USER="${AIOS_GUEST_USER:-aios}"
AIOS_GUEST_HOME="${AIOS_GUEST_HOME:-/home/aios}"
AIOS_GUEST_DISPLAY="${AIOS_GUEST_DISPLAY:-:99}"
AIOS_SSH_PORT="${AIOS_SSH_PORT:-22222}"
AIOS_KERNEL_MARKER="/var/lib/aios-kernel-installed"

# ---------------------------------------------------------------------------
# Services sur le runner
# ---------------------------------------------------------------------------
AIOS_BRIDGE_PORT="${AIOS_BRIDGE_PORT:-3001}"
AIOS_BRIDGE_HOST="${AIOS_BRIDGE_HOST:-127.0.0.1}"
CLOUDFLARED_URL="${CLOUDFLARED_URL:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64}"

# ---------------------------------------------------------------------------
# État du cycle (partagé entre les étapes du workflow)
# ---------------------------------------------------------------------------
AIOS_STATE_DIR="${AIOS_STATE_DIR:-${RUNNER_TEMP:-/tmp}/aios-cycle}"
AIOS_WORK_DIR="$AIOS_STATE_DIR/work"

# ---------------------------------------------------------------------------
# Journalisation
# ---------------------------------------------------------------------------
aios_log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
aios_warn() { printf '[%s] AVERTISSEMENT : %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
aios_die()  { printf '[%s] ERREUR : %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

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
# KVM — obligatoire. Le repli silencieux en TCG est interdit partout.
# ---------------------------------------------------------------------------
aios_require_kvm() {
  [[ -e /dev/kvm ]] || aios_die "/dev/kvm absent : ce runner ne fournit pas la virtualisation matérielle. Émulation TCG refusée."
  sudo chown "$(id -u):$(id -g)" /dev/kvm
  sudo chmod 660 /dev/kvm
  [[ -r /dev/kvm && -w /dev/kvm ]] || aios_die "/dev/kvm présent mais inaccessible."
  aios_log "Accélération KVM disponible."
}

# ---------------------------------------------------------------------------
# Paquets invités — installés par l'étape explicite « install-desktop »
# (jamais par cloud-init : une ré-exécution cloud-init doit rester rapide).
# ---------------------------------------------------------------------------
aios_guest_packages() {
  printf '%s\n' \
    xfce4 xfce4-terminal xvfb scrot \
    xdotool xclip xsel autocutsel wmctrl x11-utils imagemagick \
    python3 git
}

# Flux bureau interactif (best-effort : installé séparément pour qu'une
# différence de nom de paquet ne bloque jamais les outils principaux).
aios_guest_stream_packages() {
  printf '%s\n' x11vnc novnc websockify
}


# ---------------------------------------------------------------------------
# SSH vers l'invité — TOUTES les commandes invitées passent par aios_guest_ssh,
# bornées par timeout : un canal SSH qui reste ouvert ne peut jamais bloquer
# une étape du workflow.
# ---------------------------------------------------------------------------
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

# Usage : aios_guest_ssh <nom-tableau-sshopts> <secondes-max> <commande>
aios_guest_ssh() {
  local _name=$1 _secs=$2
  shift 2
  local -n _arr=$_name
  timeout --signal=TERM "$_secs" ssh "${_arr[@]}" "$AIOS_GUEST_USER@127.0.0.1" "$@"
}

# ---------------------------------------------------------------------------
# Installation idempotente du bureau et des outils d'interaction.
# Attends la fin de cloud-init (qui tient le verrou dpkg au démarrage) puis
# installe ce qui manque, avec attente bornée du verrou dpkg.
# $1 = nom du tableau d'options SSH.
# ---------------------------------------------------------------------------
aios_guest_ensure_desktop() {
  # 1. cloud-init a-t-il fini ? (il tient le verrou dpkg pendant son travail)
  aios_log "Attente de la fin de cloud-init dans l'invité..."
  aios_guest_ssh "$1" 300 'cloud-init status --wait 2>/dev/null || true' || aios_warn "cloud-init non confirmé : on continue."

  # 2. que manque-t-il ?
  local missing
  missing=$(aios_guest_ssh "$1" 30 'for t in startxfce4 Xvfb scrot xdotool xclip wmctrl import; do command -v "$t" >/dev/null || echo "$t"; done' 2>/dev/null || echo "ssh-indisponible")
  if [[ -z "$missing" ]]; then
    aios_log "Bureau et outils déjà installés — rien à faire."
    return 0
  fi
  aios_log "Manquants : $(echo "$missing" | tr '\n' ' ') — installation..."

  # 3. installation avec attente bornée du verrou dpkg (jamais de blocage).
  local -a pkgs; mapfile -t pkgs < <(aios_guest_packages)
  local install_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=300 ${pkgs[*]}"
  aios_guest_ssh "$1" 420 "$install_cmd" && return 0

  # 4. seconde chance : rafraîchir les index, puis réessayer.
  aios_warn "Première tentative d'installation échouée : mise à jour des index puis nouvel essai."
  aios_guest_ssh "$1" 300 'sudo apt-get update -qq -o DPkg::Lock::Timeout=300' || true
  aios_guest_ssh "$1" 420 "$install_cmd" && return 0
  return 1
}

# Installation du flux bureau interactif (x11vnc + noVNC/websockify) —
# best-effort : n'échoue jamais l'étape.
aios_guest_ensure_stream() {
  local -a spkgs; mapfile -t spkgs < <(aios_guest_stream_packages)
  if aios_guest_ssh "$1" 300 "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=300 ${spkgs[*]}"; then
    return 0
  fi
  aios_warn "Flux bureau interactif non installé (paquets ${spkgs[*]})."
  return 1
}

# Démarrage idempotent du flux interactif dans l'invité : x11vnc (VNC sur
# l'affichage :99, boucle locale) + websockify/noVNC (port 6080, boucle locale).
# N'est joignable que par le forward SSH du runner.
aios_guest_start_stream() {
  # Un service par appel, sur le patron de aios_guest_start_desktop (prouvé).
  # Astuce du crochet : '[w]ebsockify' ne peut pas matcher la ligne de commande
  # de pgrep elle-même (le piège classique du pgrep -f).
  aios_guest_ssh "$1" 20 "command -v x11vnc >/dev/null || exit 0; pgrep -x x11vnc >/dev/null && exit 0; setsid nohup x11vnc -display $AIOS_GUEST_DISPLAY -localhost -rfbport 5900 -shared -forever -nopw -xkb -o /tmp/aios-x11vnc.log >/dev/null 2>&1 </dev/null & exit 0" \
    || aios_warn "x11vnc non démarré dans l'invité."
  aios_guest_ssh "$1" 20 "command -v websockify >/dev/null || exit 0; pgrep -f '[w]ebsockify' >/dev/null && exit 0; setsid nohup websockify --web=/usr/share/novnc 127.0.0.1:6080 localhost:5900 >/tmp/aios-websockify.log 2>&1 </dev/null & exit 0" \
    || aios_warn "websockify non démarré dans l'invité."
}

# Démarrage idempotent du bureau X (Xvfb + XFCE), un daemon par appel, chacun
# détaché (setsid) et borné : impossible de bloquer l'étape.
aios_guest_start_desktop() {
  local d="$AIOS_GUEST_DISPLAY" r="$AIOS_GUEST_RESOLUTION"
  aios_guest_ssh "$1" 30 "command -v Xvfb >/dev/null || exit 0; pgrep -x Xvfb >/dev/null && exit 0; setsid nohup Xvfb $d -screen 0 $r >/tmp/aios-xvfb.log 2>&1 </dev/null & exit 0" \
    || aios_warn "Xvfb non démarré."
  aios_guest_ssh "$1" 30 "command -v xfce4-session >/dev/null || exit 0; pgrep -x xfce4-session >/dev/null && exit 0; setsid nohup env DISPLAY=$d xfce4-session >/tmp/aios-xfce.log 2>&1 </dev/null & exit 0" \
    || aios_warn "XFCE non démarré."
}

# ---------------------------------------------------------------------------
# Image Ubuntu
# ---------------------------------------------------------------------------
aios_fetch_ubuntu_image() {
  local dest=$1 out=$2 sums
  sums="$(mktemp)"
  curl -fsSLo "$sums" "$AIOS_UBUNTU_BASE/SHA256SUMS" || { rm -f "$sums"; return 1; }
  curl -fSL --retry 3 --retry-delay 2 -o "$dest/$AIOS_UBUNTU_IMAGE" "$AIOS_UBUNTU_BASE/$AIOS_UBUNTU_IMAGE" || { rm -f "$sums"; return 1; }
  ( cd "$dest" && grep -F "*$AIOS_UBUNTU_IMAGE" "$sums" | sha256sum -c - ) || { rm -f "$sums"; return 1; }
  rm -f "$sums"
  mv "$dest/$AIOS_UBUNTU_IMAGE" "$dest/$out"
}

# ---------------------------------------------------------------------------
# Timestamps d'état
# ---------------------------------------------------------------------------
state_write() { mkdir -p "$AIOS_STATE_DIR"; printf '%s' "$2" > "$AIOS_STATE_DIR/$1"; }
state_read()  { cat "$AIOS_STATE_DIR/$1" 2>/dev/null || true; }
