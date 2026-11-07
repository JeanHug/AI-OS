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

# Installation idempotente du bureau et des outils d'interaction.
# $1 = nom du tableau d'options SSH (nameref).
aios_guest_ensure_desktop() {
  local -n _sshopts=$1
  local missing
  missing=$(ssh "${_sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" \
    'for t in startxfce4 Xvfb scrot xdotool xclip wmctrl import; do command -v "$t" >/dev/null || echo "$t"; done' 2>/dev/null || echo "ssh-indisponible")
  if [[ -z "$missing" ]]; then
    aios_log "Bureau et outils déjà installés — rien à faire."
    return 0
  fi
  aios_log "Manquants : $(echo "$missing" | tr '\n' ' ') — installation..."
  local -a pkgs; mapfile -t pkgs < <(aios_guest_packages)
  ssh "${_sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" "sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends ${pkgs[*]}" \
    || ssh "${_sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" "sudo apt-get install -y --no-install-recommends ${pkgs[*]}" \
    || return 1
}

# Démarrage idempotent du bureau X (Xvfb + XFCE).
aios_guest_start_desktop() {
  local -n _sshopts=$1
  ssh "${_sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" \
    "pgrep -x Xvfb >/dev/null || nohup Xvfb $AIOS_GUEST_DISPLAY -screen 0 $AIOS_GUEST_RESOLUTION >/tmp/aios-xvfb.log 2>&1 </dev/null & pgrep -x xfce4-session >/dev/null || nohup env DISPLAY=$AIOS_GUEST_DISPLAY xfce4-session >/tmp/aios-xfce.log 2>&1 </dev/null &"
}

# ---------------------------------------------------------------------------
# SSH vers l'invité
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
