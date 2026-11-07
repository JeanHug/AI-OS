#!/usr/bin/env bash
# qemu-durable.sh — cycle de production AI OS : restauration, bureau, tunnel,
# relais vers le cycle suivant, arrêt propre et sauvegarde chiffrée.
#
# Paramètres : voir config/aios.conf et scripts/lib-common.sh.
# Environnement requis : GH_TOKEN, AIOS_BACKUP_KEY, AIOS_VM_SSH_KEY, VM_API_TOKEN.
# Override de test : RELAY_TRIGGER_SECONDS / RELAY_SHUTDOWN_SECONDS.
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-cloudinit.sh"
aios_require_env GH_TOKEN AIOS_BACKUP_KEY AIOS_VM_SSH_KEY VM_API_TOKEN

work=$(mktemp -d)
qemu_pid=''; tunnel_pid=''; bridge_pid=''; tunnel=''
cleanup() {
  [[ -n "$tunnel_pid" ]] && kill "$tunnel_pid" 2>/dev/null || true
  [[ -n "$bridge_pid" ]] && kill "$bridge_pid" 2>/dev/null || true
  [[ -n "$qemu_pid" ]] && kill "$qemu_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
cd "$work"

aios_require_kvm

# La clé SSH du compte invité est injectée par cloud-init à la première
# installation ; la même clé doit restaurer les checkpoints suivants.
printf '%s\n' "$AIOS_VM_SSH_KEY" > "$work/key"; chmod 600 "$work/key"
pub=$(ssh-keygen -y -f "$work/key")

# cloudflared est téléchargé AVANT la restauration : chaque seconde gagnée ici
# est une seconde de moins dans la fenêtre de coupure perçue par l'utilisateur.
aios_log "Téléchargement de cloudflared..."
curl -fsSL "$CLOUDFLARED_URL" -o cloudflared; chmod +x cloudflared

image="$work/disk.img"
expected="${PREDECESSOR_RUN_ID:-}"
if [[ -n "$expected" ]]; then
  aios_log "Attente du checkpoint du cycle précédent..."
  [[ "$expected" =~ ^[0-9]+$ ]] || aios_die "predecessor_run_id invalide"
  ready=0
  for _ in $(seq 1 150); do
    status=$(curl -sS --max-time 15 -o "$work/check.json" -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$AIOS_DATA_REPO/contents/CHECKPOINT?ref=$AIOS_DATA_BRANCH" || echo 000)
    if [[ "$status" == 200 ]] && EXPECTED="$expected" python3 -c 'import json,base64,os; d=json.load(open("check.json")); assert base64.b64decode(d["content"]).decode().strip()==os.environ["EXPECTED"]' 2>/dev/null; then ready=1; break; fi
    sleep 15
  done
  [[ "$ready" == 1 ]] || aios_die "Checkpoint non publié : démarrage annulé pour protéger les données"
  bash "$GITHUB_WORKSPACE/scripts/aios-data.sh" restore "$image" "$expected"
  fresh=0
else
  status=$(curl -sS --max-time 15 -o "$work/check.json" -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$AIOS_DATA_REPO/contents/CHECKPOINT?ref=$AIOS_DATA_BRANCH" || echo 000)
  if [[ "$status" == 200 ]]; then
    expected=$(python3 -c 'import json,base64;print(base64.b64decode(json.load(open("check.json"))["content"]).decode().strip())')
    aios_log "Restauration du dernier checkpoint existant."
    bash "$GITHUB_WORKSPACE/scripts/aios-data.sh" restore "$image" "$expected"; fresh=0
  elif [[ "$status" == 404 || "$status" == 409 ]]; then
    aios_log "Aucun checkpoint : première installation."
    aios_fetch_ubuntu_image "$work" "$image" || aios_die "Téléchargement de l'image Ubuntu impossible"
    qemu-img resize "$image" "$AIOS_DISK_SIZE"; fresh=1
  else
    aios_die "Impossible de vérifier la sauvegarde (HTTP $status)"
  fi
fi

# Seed cloud-init. L'instance-id propre au durable déclenche UNE ré-exécution
# des modules cloud-init sur les anciens checkpoints : les paquets ajoutés dans
# aios_guest_packages convergent alors automatiquement (le noyau est verrouillé
# par son marqueur, jamais réinstallé, jamais de redémarrage intempestif).
aios_write_cloudinit "$pub" "$AIOS_INSTANCE_ID_DURABLE" full
cloud-localds seed.img user-data meta-data

start_vm() {
  qemu-system-x86_64 -machine "$AIOS_QEMU_MACHINE" -cpu "$AIOS_QEMU_CPU" -m "$AIOS_QEMU_MEM_MB" -smp "$AIOS_QEMU_SMP" \
    -drive "file=$image,if=virtio,format=qcow2" -drive file=seed.img,if=virtio,format=raw \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$AIOS_SSH_PORT-:22 -device virtio-net-pci,netdev=net0 \
    -display none -serial file:qemu-serial.log -no-reboot & qemu_pid=$!
}

sshopts=(); aios_ssh_options sshopts "$work/key" "$work/known_hosts"
start_vm

if [[ "$fresh" == 1 ]]; then
  aios_log 'Installation initiale du système et du noyau (premier redémarrage automatique)...'
  for _ in $(seq 1 180); do
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 10
  done
  if kill -0 "$qemu_pid" 2>/dev/null; then aios_die 'Délai installation initiale dépassé'; fi
  wait "$qemu_pid" || true; start_vm
fi

ready=0
for _ in $(seq 1 120); do
  if ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" "test -f $AIOS_KERNEL_MARKER && . /etc/os-release && test \"\$VERSION_ID\" = 26.10 && uname -r | grep -q \"^${AIOS_KERNEL_ABBREV//./\\.}\"" 2>/dev/null; then ready=1; break; fi
  kill -0 "$qemu_pid" 2>/dev/null || aios_die 'QEMU arrêté prématurément'
  sleep 5
done
[[ "$ready" == 1 ]] || aios_die 'Démarrage VM non confirmé'
aios_log 'VM prête (noyau '"$AIOS_KERNEL_VERSION"', Ubuntu 26.10).'

# Convergence des outils d'interaction : idempotente, avec une seconde tentative.
if ! ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" 'command -v xdotool && command -v xclip && command -v wmctrl && command -v scrot' >/dev/null 2>&1; then
  aios_log "Outils d'interaction manquants : installation convergente..."
  ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" 'sudo apt-get install -y xdotool xclip xsel autocutsel wmctrl x11-utils imagemagick' \
    || ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" 'sudo apt-get install -y xdotool xclip xsel autocutsel wmctrl x11-utils imagemagick' \
    || aios_warn "Installation des outils d'interaction incomplète : certaines routes du pont échoueront."
fi

# Bureau X idempotent.
ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" "pgrep -x Xvfb >/dev/null || nohup Xvfb $AIOS_GUEST_DISPLAY -screen 0 $AIOS_GUEST_RESOLUTION >/tmp/aios-xvfb.log 2>&1 </dev/null & pgrep -x xfce4-session >/dev/null || nohup env DISPLAY=$AIOS_GUEST_DISPLAY xfce4-session >/tmp/aios-xfce.log 2>&1 </dev/null &"

start_bridge() {
  AIOS_SSH_KEY="$work/key" AIOS_KNOWN_HOSTS="$work/known_hosts" \
    node "$GITHUB_WORKSPACE/scripts/qemu-interaction-bridge.cjs" > bridge.log 2>&1 & bridge_pid=$!
}
start_bridge

start_tunnel() {
  ./cloudflared tunnel --url "http://$AIOS_BRIDGE_HOST:$AIOS_BRIDGE_PORT" --no-autoupdate > tunnel.log 2>&1 & tunnel_pid=$!
}
start_tunnel
for _ in $(seq 1 90); do
  tunnel=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' tunnel.log | head -1 || true)
  [[ -n "$tunnel" ]] && break
  sleep 2
done
[[ -n "${tunnel:-}" ]] || aios_die 'Tunnel indisponible'
export AIOS_TUNNEL="$tunnel"
node "$GITHUB_WORKSPACE/scripts/qemu-publish-tunnel.cjs"
aios_log "VM prête et publiée : $tunnel — le prochain cycle sera déclenché avant la sauvegarde."

# ---------------------------------------------------------------------------
# Boucle de relais
# ---------------------------------------------------------------------------
trigger_seconds="${RELAY_TRIGGER_SECONDS:-$AIOS_RELAY_TRIGGER_SECONDS}"
shutdown_seconds="${RELAY_SHUTDOWN_SECONDS:-$AIOS_RELAY_SHUTDOWN_SECONDS}"
[[ "$trigger_seconds" =~ ^[0-9]+$ && "$shutdown_seconds" =~ ^[0-9]+$ ]] || aios_die 'Timings invalides'
(( shutdown_seconds > trigger_seconds )) || aios_die 'shutdown_seconds doit dépasser trigger_seconds'
(( shutdown_seconds + 1200 <= AIOS_JOB_BUDGET_SECONDS )) || aios_warn "Budget de job dépassé : la sauvegarde risque d'être coupée par la limite GitHub."
aios_log "Relais : déclenchement à ${trigger_seconds}s, arrêt à ${shutdown_seconds}s (chevauchement $((shutdown_seconds - trigger_seconds))s)."

start=$(date +%s); triggered=0
dispatch_next() {
  # Le relais est répété jusqu'à 5 fois ; un échec définitif ne doit JAMAIS
  # tuer le cycle : sauvegarder les données prime sur la continuité du service.
  local json
  json=$(printf '{"ref":"main","inputs":{"predecessor_run_id":"%s"}}' "$GITHUB_RUN_ID")
  for attempt in 1 2 3 4 5; do
    if curl --fail-with-body -sS --max-time 30 -X POST \
        -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/qemu-durable.yml/dispatches" -d "$json"; then
      return 0
    fi
    aios_warn "Déclenchement du cycle suivant, tentative $attempt échouée."
    sleep 15
  done
  return 1
}

while :; do
  now=$(date +%s); elapsed=$((now - start))
  # Survie des services : redémarrage au lieu de mort sans checkpoint.
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    aios_warn "QEMU s'est arrêté de façon inattendue : sauvegarde d'urgence (disque potentiellement incohérent)."
    bash "$GITHUB_WORKSPACE/scripts/aios-data.sh" save "$image" "$GITHUB_RUN_ID" || true
    aios_die 'VM perdue en cours de cycle.'
  fi
  if ! kill -0 "$bridge_pid" 2>/dev/null; then
    aios_warn "Pont d'interaction arrêté : redémarrage."
    start_bridge
  fi
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    aios_warn 'Tunnel cloudflared arrêté : redémarrage.'
    start_tunnel
    for _ in $(seq 1 45); do
      tunnel=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' tunnel.log | head -1 || true)
      [[ -n "$tunnel" ]] && break
      sleep 2
    done
    if [[ -n "${tunnel:-}" ]]; then
      export AIOS_TUNNEL="$tunnel"
      node "$GITHUB_WORKSPACE/scripts/qemu-publish-tunnel.cjs" || true
    fi
  fi
  if (( !triggered && elapsed >= trigger_seconds )); then
    if dispatch_next; then
      triggered=1
      aios_log 'Cycle suivant déclenché : attente de la fenêtre de chevauchement.'
    else
      triggered=1
      aios_warn 'Cycle suivant NON déclenché après 5 tentatives : la sauvegarde sera néanmoins effectuée.'
    fi
  fi
  if (( elapsed >= shutdown_seconds )); then
    aios_log "Arrêt propre de l'invité avant sauvegarde chiffrée."
    ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" 'sudo sync && sudo shutdown -h now' || true
    stopped=0
    for _ in $(seq 1 120); do
      if ! kill -0 "$qemu_pid" 2>/dev/null; then stopped=1; break; fi
      sleep 2
    done
    [[ "$stopped" == 1 ]] || aios_die 'Arrêt non confirmé : sauvegarde annulée pour ne pas publier un disque vivant'
    wait "$qemu_pid" || true; qemu_pid=''
    bash "$GITHUB_WORKSPACE/scripts/aios-data.sh" save "$image" "$GITHUB_RUN_ID"
    aios_log 'Checkpoint chiffré publié pour le prochain cycle.'
    exit 0
  fi
  sleep 20
done
