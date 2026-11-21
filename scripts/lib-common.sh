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

  # 2. paquets du bureau : on installe seulement ce qui manque.
  local missing
  missing=$(aios_guest_ssh "$1" 30 'for t in startxfce4 Xvfb scrot xdotool xclip wmctrl import; do command -v "$t" >/dev/null || echo "$t"; done' 2>/dev/null || echo "ssh-indisponible")
  if [[ -n "$missing" ]]; then
    aios_log "Manquants : $(echo "$missing" | tr '\n' ' ') — installation..."
    local -a pkgs; mapfile -t pkgs < <(aios_guest_packages)
    local install_cmd="sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=300 ${pkgs[*]}"
    if ! aios_guest_ssh "$1" 420 "$install_cmd"; then
      aios_warn "Première tentative d'installation échouée : mise à jour des index puis nouvel essai."
      aios_guest_ssh "$1" 300 'sudo apt-get update -qq -o DPkg::Lock::Timeout=300' || true
      aios_guest_ssh "$1" 420 "$install_cmd" || aios_warn "Paquets du bureau incomplets."
    fi
  fi

  # 3. Google Chrome (navigateur, idempotent).
  if ! aios_guest_ssh "$1" 15 'command -v google-chrome-stable >/dev/null 2>&1'; then
    aios_guest_ssh "$1" 300 'curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=300 /tmp/chrome.deb' \
      || aios_warn "Chrome non installé dans l'invité."
  fi

  # 4. Chrome : accessibilité forcée (sinon Chrome n'expose AUCUN champ texte
  #    à AT-SPI et la détection du clavier est aveugle).
  aios_guest_ssh "$1" 20 'grep -q force-renderer-accessibility /usr/share/applications/google-chrome.desktop || sudo sed -i "s#^Exec=/usr/bin/google-chrome-stable#Exec=env ACCESSIBILITY_ENABLED=1 /usr/bin/google-chrome-stable --force-renderer-accessibility#" /usr/share/applications/google-chrome.desktop' \
    || aios_warn "Chrome non configuré pour l'accessibilité."

  # 5. Raccourci Chrome sur le bureau (double-clic direct : bit exécutable).
  aios_guest_ssh "$1" 20 'command -v google-chrome-stable >/dev/null 2>&1 && { d=$(xdg-user-dir DESKTOP 2>/dev/null || echo /home/aios/Desktop); mkdir -p "$d"; cp /usr/share/applications/google-chrome.desktop "$d/" && chmod +x "$d/google-chrome.desktop"; }' \
    || aios_warn "Raccourci bureau Chrome non posé."

  # 6. Fond d'écran blanc, écrit comme fichier de canal xfconf (la session n'est
  #    pas encore lancée : pas de D-Bus). Xvfb nomme la sortie « screen » →
  #    la propriété est monitorscreen. Idempotent : on n'écrase pas un fichier
  #    déjà présent.
  aios_guest_ssh "$1" 20 'mkdir -p ~/.config/xfce4/xfconf/xfce-perchannel-xml' || true
  aios_guest_ssh "$1" 20 'test -f /home/aios/white.png || printf %s iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC | base64 -d > /home/aios/white.png' || aios_warn "Fond blanc non écrit."
  aios_guest_ssh "$1" 20 'printf %s PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPGNoYW5uZWwgbmFtZT0ieGZjZTQtZGVza3RvcCIgdmVyc2lvbj0iMS4wIj4KICA8cHJvcGVydHkgbmFtZT0iYmFja2Ryb3AiIHR5cGU9ImVtcHR5Ij4KICAgIDxwcm9wZXJ0eSBuYW1lPSJtb25pdG9yc2NyZWVuIiB0eXBlPSJlbXB0eSI+CiAgICAgIDxwcm9wZXJ0eSBuYW1lPSJ3b3Jrc3BhY2UwIiB0eXBlPSJlbXB0eSI+CiAgICAgICAgPHByb3BlcnR5IG5hbWU9Imxhc3QtaW1hZ2UiIHR5cGU9InN0cmluZyIgdmFsdWU9Ii9ob21lL2Fpb3Mvd2hpdGUucG5nIi8+CiAgICAgICAgPHByb3BlcnR5IG5hbWU9ImltYWdlLXN0eWxlIiB0eXBlPSJpbnQiIHZhbHVlPSI1Ii8+CiAgICAgICAgPHByb3BlcnR5IG5hbWU9ImNvbG9yLXN0eWxlIiB0eXBlPSJpbnQiIHZhbHVlPSIxIi8+CiAgICAgICAgPHByb3BlcnR5IG5hbWU9InJnYmEiIHR5cGU9ImFycmF5Ij4KICAgICAgICAgIDx2YWx1ZSB0eXBlPSJ1aW50IiB2YWx1ZT0iNjU1MzUiLz4KICAgICAgICAgIDx2YWx1ZSB0eXBlPSJ1aW50IiB2YWx1ZT0iNjU1MzUiLz4KICAgICAgICAgIDx2YWx1ZSB0eXBlPSJ1aW50IiB2YWx1ZT0iNjU1MzUiLz4KICAgICAgICAgIDx2YWx1ZSB0eXBlPSJ1aW50IiB2YWx1ZT0iNjU1MzUiLz4KICAgICAgICA8L3Byb3BlcnR5PgogICAgICA8L3Byb3BlcnR5PgogICAgICA8cHJvcGVydHkgbmFtZT0id29ya3NwYWNlMSIgdHlwZT0iZW1wdHkiPgogICAgICAgIDxwcm9wZXJ0eSBuYW1lPSJsYXN0LWltYWdlIiB0eXBlPSJzdHJpbmciIHZhbHVlPSIvaG9tZS9haW9zL3doaXRlLnBuZyIvPgogICAgICAgIDxwcm9wZXJ0eSBuYW1lPSJpbWFnZS1zdHlsZSIgdHlwZT0iaW50IiB2YWx1ZT0iNSIvPgogICAgICAgIDxwcm9wZXJ0eSBuYW1lPSJjb2xvci1zdHlsZSIgdHlwZT0iaW50IiB2YWx1ZT0iMSIvPgogICAgICAgIDxwcm9wZXJ0eSBuYW1lPSJyZ2JhIiB0eXBlPSJhcnJheSI+CiAgICAgICAgICA8dmFsdWUgdHlwZT0idWludCIgdmFsdWU9IjY1NTM1Ii8+CiAgICAgICAgICA8dmFsdWUgdHlwZT0idWludCIgdmFsdWU9IjY1NTM1Ii8+CiAgICAgICAgICA8dmFsdWUgdHlwZT0idWludCIgdmFsdWU9IjY1NTM1Ii8+CiAgICAgICAgICA8dmFsdWUgdHlwZT0idWludCIgdmFsdWU9IjY1NTM1Ii8+CiAgICAgICAgPC9wcm9wZXJ0eT4KICAgICAgPC9wcm9wZXJ0eT4KICAgIDwvcHJvcGVydHk+CiAgPC9wcm9wZXJ0eT4KPC9jaGFubmVsPgo= | base64 -d > ~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml' \
    || aios_warn "Configuration du fond blanc non écrite."
  # 6b. Ré-application À CHAQUE démarrage de session : configuration blanche
  # (tous les noms de moniteurs) + REDÉMARRAGE de xfdesktop (un xfdesktop
  # en état périmé peint noir même avec la bonne config — cause du fond noir).
  aios_guest_ssh "$1" 20 "mkdir -p ~/.config/autostart && printf %s aW1wb3J0IHN1YnByb2Nlc3MsIG9zCm91dCA9ICcnCmVudiA9IGRpY3Qob3MuZW52aXJvbik7IGVudlsnRElTUExBWSddID0gJzo5OScKdHJ5OgogICAgciA9IHN1YnByb2Nlc3MucnVuKFsneHJhbmRyJywgJy0tcXVlcnknXSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCBlbnY9ZW52KQogICAgZm9yIGxuIGluIChyLnN0ZG91dCBvciAnJykuc3BsaXRsaW5lcygpOgogICAgICAgIGlmICcgY29ubmVjdGVkJyBpbiBsbjoKICAgICAgICAgICAgb3V0ID0gbG4uc3BsaXQoKVswXTsgYnJlYWsKZXhjZXB0IEV4Y2VwdGlvbjoKICAgIHBhc3MKcHJpbnQoJ3NvcnRpZSB4cmFuZHIgPScsIG91dCBvciAnKGF1Y3VuZSknKQpjYW5kcyA9IFsnbW9uaXRvcnNjcmVlbicsICdtb25pdG9yMCcsICdtb25pdG9yJyArIChvdXQgb3IgJ2RlZmF1bHQnKSwKICAgICAgICAgJ3NjcmVlbjAvbW9uaXRvcjAnLCAnc2NyZWVuMC9tb25pdG9yJyArIChvdXQgb3IgJ2RlZmF1bHQnKSwgJ3NjcmVlbjAvbW9uaXRvcnNjcmVlbiddCmRlZiB3cyhuYW1lLCBpbmQpOgogICAgYiA9IGluZCArIGYnPHByb3BlcnR5IG5hbWU9IntuYW1lfSIgdHlwZT0iZW1wdHkiPlxuJwogICAgYiArPSBpbmQgKyAnICA8cHJvcGVydHkgbmFtZT0ibGFzdC1pbWFnZSIgdHlwZT0ic3RyaW5nIiB2YWx1ZT0iL2hvbWUvYWlvcy93aGl0ZS5wbmciLz5cbicKICAgIGIgKz0gaW5kICsgJyAgPHByb3BlcnR5IG5hbWU9ImltYWdlLXN0eWxlIiB0eXBlPSJpbnQiIHZhbHVlPSIwIi8+XG4nCiAgICBiICs9IGluZCArICcgIDxwcm9wZXJ0eSBuYW1lPSJjb2xvci1zdHlsZSIgdHlwZT0iaW50IiB2YWx1ZT0iMSIvPlxuJwogICAgYiArPSBpbmQgKyAnICA8cHJvcGVydHkgbmFtZT0icmdiYSIgdHlwZT0iYXJyYXkiPlxuJwogICAgZm9yIF8gaW4gcmFuZ2UoNCk6CiAgICAgICAgYiArPSBpbmQgKyAnICAgIDx2YWx1ZSB0eXBlPSJ1aW50IiB2YWx1ZT0iNjU1MzUiLz5cbicKICAgIGIgKz0gaW5kICsgJyAgPC9wcm9wZXJ0eT5cbicKICAgIGIgKz0gaW5kICsgJzwvcHJvcGVydHk+XG4nCiAgICByZXR1cm4gYgp4bWwgPSAnPD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz5cbjxjaGFubmVsIG5hbWU9InhmY2U0LWRlc2t0b3AiIHZlcnNpb249IjEuMCI+XG4gIDxwcm9wZXJ0eSBuYW1lPSJiYWNrZHJvcCIgdHlwZT0iZW1wdHkiPlxuJwpmb3IgYyBpbiBjYW5kczoKICAgIHBhcnRzID0gYy5zcGxpdCgnLycpCiAgICBhY2MgPSAnJwogICAgZm9yIGksIHBhcnQgaW4gZW51bWVyYXRlKHBhcnRzKToKICAgICAgICBhY2MgKz0gJyAgICAnICogKGkgKyAxKSArIGYnPHByb3BlcnR5IG5hbWU9IntwYXJ0fSIgdHlwZT0iZW1wdHkiPlxuJwogICAgYm9keSA9ICcnCiAgICBmb3IgdyBpbiAoJ3dvcmtzcGFjZTAnLCAnd29ya3NwYWNlMScpOgogICAgICAgIGJvZHkgKz0gd3ModywgJyAgICAnICogKGxlbihwYXJ0cykgKyAxKSkKICAgIGNsb3NlcyA9ICcnCiAgICBmb3IgaSBpbiByYW5nZShsZW4ocGFydHMpIC0gMSwgLTEsIC0xKToKICAgICAgICBjbG9zZXMgKz0gJyAgICAnICogKGkgKyAxKSArICc8L3Byb3BlcnR5PlxuJwogICAgeG1sICs9IGFjYyArIGJvZHkgKyBjbG9zZXMKeG1sICs9ICcgIDwvcHJvcGVydHk+XG48L2NoYW5uZWw+XG4nCm9wZW4oJy9ob21lL2Fpb3Mvd2FsbC1hbGwueG1sJywgJ3cnKS53cml0ZSh4bWwpCnByaW50KCd3YWxsLWFsbC54bWwgKGJsYW5jIHNvbGlkZSkgw6ljcml0LCcsIGxlbih4bWwpKQo= | base64 -d > ~/gen-wall.py && printf %s IyEvYmluL3NoCnNsZWVwIDIKZXhwb3J0IERJU1BMQVk9Ojk5ClsgLXogIiREQlVTX1NFU1NJT05fQlVTX0FERFJFU1MiIF0gJiYgZXhwb3J0IERCVVNfU0VTU0lPTl9CVVNfQUREUkVTUz11bml4OnBhdGg9L3J1bi91c2VyLyQoaWQgLXUpL2J1cwpbIC16ICIkWEFVVEhPUklUWSIgXSAmJiBleHBvcnQgWEFVVEhPUklUWT0vaG9tZS9haW9zLy5YYXV0aG9yaXR5CnhzZXRyb290IC1zb2xpZCAnI2ZmZmZmZicgMj4vZGV2L251bGwgfHwgdHJ1ZQpweXRob24zIC9ob21lL2Fpb3MvZ2VuLXdhbGwucHkgMj4vZGV2L251bGwgfHwgdHJ1ZQpta2RpciAtcCB+Ly5jb25maWcveGZjZTQveGZjb25mL3hmY2UtcGVyY2hhbm5lbC14bWwKY3AgL2hvbWUvYWlvcy93YWxsLWFsbC54bWwgfi8uY29uZmlnL3hmY2U0L3hmY29uZi94ZmNlLXBlcmNoYW5uZWwteG1sL3hmY2U0LWRlc2t0b3AueG1sIDI+L2Rldi9udWxsIHx8IHRydWUKZm9yIHdzIGluIHdvcmtzcGFjZTAgd29ya3NwYWNlMTsgZG8KICB4ZmNvbmYtcXVlcnkgLWMgeGZjZTQtZGVza3RvcCAtcCAvYmFja2Ryb3AvbW9uaXRvcnNjcmVlbi8kd3MvY29sb3Itc3R5bGUgLXMgMSAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgeGZjb25mLXF1ZXJ5IC1jIHhmY2U0LWRlc2t0b3AgLXAgL2JhY2tkcm9wL21vbml0b3JzY3JlZW4vJHdzL2ltYWdlLXN0eWxlIC1zIDAgMj4vZGV2L251bGwgfHwgdHJ1ZQpkb25lCnBraWxsIC14IHhmZGVza3RvcCAyPi9kZXYvbnVsbCB8fCB0cnVlCnNsZWVwIDEKc2V0c2lkIG5vaHVwIHhmZGVza3RvcCA+L2Rldi9udWxsIDI+JjEgJgo= | base64 -d > ~/aios-wallpaper.sh && chmod 755 ~/aios-wallpaper.sh && printf %s W0Rlc2t0b3AgRW50cnldClR5cGU9QXBwbGljYXRpb24KTmFtZT1BSU9TIGZvbmQgYmxhbmMKRXhlYz0vaG9tZS9haW9zL2Fpb3Mtd2FsbHBhcGVyLnNoClgtWEZDRS1BdXRvc3RhcnQtT3ZlcnJpZGU9dHJ1ZQo= | base64 -d > ~/.config/autostart/aios-wallpaper.desktop" \
    || aios_warn "Autostart du fond blanc non écrit."

  # 7. Surcouche mobile (bouton, barre d'outils, curseur, reconnexion
  #    supervisée) : installée à CHAQUE cycle depuis le dépôt — jamais
  #    dépendante du checkpoint ni d'une install manuelle.
  local ov_b64 ip_b64
  ov_b64=$(base64 < "$AIOS_REPO_ROOT/scripts/aios-overlay.js" | tr -d '\n')
  ip_b64=$(base64 < "$AIOS_REPO_ROOT/scripts/aios-overlay-install.py" | tr -d '\n')
  aios_guest_ssh "$1" 90 "printf %s '$ov_b64' | base64 -d | sudo tee /usr/share/novnc/aios-overlay.js >/dev/null
sudo chmod 644 /usr/share/novnc/aios-overlay.js
printf %s '$ip_b64' | base64 -d | sudo python3
sudo touch /usr/share/novnc/vnc.html" || aios_warn "Surcouche mobile non installée."
  return 0
}
# Installation du flux bureau interactif (x11vnc + noVNC/websockify) —
# best-effort : n'échoue jamais l'étape.
aios_guest_ensure_stream() {
  local -a spkgs; mapfile -t spkgs < <(aios_guest_stream_packages)
  aios_guest_ssh "$1" 300 "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=300 ${spkgs[*]}" \
    || aios_warn "Flux bureau interactif non installé (paquets ${spkgs[*]})."
  # Client mobile + habillage PWA dans le répertoire noVNC (servi derrière
  # l'auth du pont, au même titre que vnc.html). Téléchargements avec réessais.
  local mbase="https://raw.githubusercontent.com/JeanHug/AI-OS/main/scripts"
  aios_guest_ssh "$1" 120 "sudo curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /usr/share/novnc/aios-overlay.js $mbase/aios-overlay.js && sudo curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /usr/share/novnc/mobile.html $mbase/mobile.html && sudo curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /usr/share/novnc/manifest.json $mbase/mobile-manifest.json && sudo curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /usr/share/novnc/icon-512.png $mbase/mobile-icon.png && sudo chmod 644 /usr/share/novnc/aios-overlay.js /usr/share/novnc/mobile.html /usr/share/novnc/manifest.json /usr/share/novnc/icon-512.png && printf %s 'aW1wb3J0IHJlCmpzID0gb3BlbigiL3Vzci9zaGFyZS9ub3ZuYy9haW9zLW92ZXJsYXkuanMiKS5yZWFkKCkKcCA9ICIvdXNyL3NoYXJlL25vdm5jL3ZuYy5odG1sIgpoID0gb3BlbihwKS5yZWFkKCkKaCA9IHJlLnN1YihyIjwhLS1haW9zLW92ZXJsYXktLT4uKj88IS0tL2Fpb3Mtb3ZlcmxheS0tPiIsICIiLCBoLCBmbGFncz1yZS5TKQpoID0gaC5yZXBsYWNlKCc8c2NyaXB0IHNyYz1haW9zLW92ZXJsYXkuanM+PC9zY3JpcHQ+JywgJycpCmggPSBoLnJlcGxhY2UoIjwvYm9keT4iLCAiPCEtLWFpb3Mtb3ZlcmxheS0tPlxuPHNjcmlwdD5cbiIgKyBqcyArICJcbjwvc2NyaXB0PlxuPCEtLS9haW9zLW92ZXJsYXktLT5cbjwvYm9keT4iKQpvcGVuKHAsICJ3Iikud3JpdGUoaCkK' | base64 -d | sudo python3 && sudo touch /usr/share/novnc/vnc.html" \
    || aios_warn "Surcouche bureau non déposée dans l'invité."
}

# Démarrage idempotent du flux interactif dans l'invité : x11vnc (VNC sur
# l'affichage :99, boucle locale) + websockify/noVNC (port 6080, boucle locale).
# N'est joignable que par le forward SSH du runner.
aios_guest_start_stream() {
  # Un service par appel, sur le patron de aios_guest_start_desktop (prouvé).
  # L'état se teste par le port d'écoute (ss), jamais par pgrep -f : la ligne
  # de commande contenant « websockify » se matcherait elle-même (piège classique).
  aios_guest_ssh "$1" 20 "if ss -ltn 2>/dev/null | grep -q ':5900 '; then timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/5900; head -c 3 <&3' 2>/dev/null | grep -q RFB && exit 0; pkill -9 -x x11vnc 2>/dev/null; sleep 0.5; fi; command -v x11vnc >/dev/null || exit 0; setsid nohup x11vnc -display $AIOS_GUEST_DISPLAY -localhost -rfbport 5900 -shared -forever -nopw -xkb -wait 2 -defer 2 -snapfb -repeat -o /tmp/aios-x11vnc.log >/dev/null 2>&1 </dev/null & exit 0" \
    || aios_warn "x11vnc non démarré dans l'invité."
  aios_guest_ssh "$1" 20 "if ss -ltn 2>/dev/null | grep -q ':6080 '; then curl -s -o /dev/null -m 2 http://127.0.0.1:6080/ && exit 0; pkill -9 -x websockify 2>/dev/null; sleep 0.5; fi; command -v websockify >/dev/null || exit 0; setsid nohup websockify --web=/usr/share/novnc 127.0.0.1:6080 localhost:5900 >/tmp/aios-websockify.log 2>&1 </dev/null & exit 0" \
    || aios_warn "websockify non démarré dans l'invité."
}

# Démarrage idempotent du bureau X (Xvfb + XFCE), un daemon par appel, chacun
# détaché (setsid) et borné : impossible de bloquer l'étape.
aios_guest_start_desktop() {
  local d="$AIOS_GUEST_DISPLAY" r="$AIOS_GUEST_RESOLUTION"
  aios_guest_ssh "$1" 30 "command -v Xvfb >/dev/null || exit 0; pgrep -x Xvfb >/dev/null && exit 0; setsid nohup Xvfb $d -screen 0 $r >/tmp/aios-xvfb.log 2>&1 </dev/null & exit 0" \
    || aios_warn "Xvfb non démarré."
  aios_guest_ssh "$1" 30 "command -v xfce4-session >/dev/null || exit 0; pgrep -x xfce4-session >/dev/null && exit 0; setsid nohup env DISPLAY=$d ACCESSIBILITY_ENABLED=1 QT_ACCESSIBILITY=1 GTK_MODULES=gail:atk-bridge xfce4-session >/tmp/aios-xfce.log 2>&1 </dev/null & exit 0" \
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
