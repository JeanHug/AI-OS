#!/usr/bin/env bash
# qemu-cycle.sh — cycle de production AI OS, découpé en phases visibles.
#
# Chaque phase correspond à une étape du workflow GitHub Actions :
#
#   restore           restauration du checkpoint (ou création du disque)
#   boot              démarrage de la VM et attente de sa disponibilité
#   install-desktop   bureau + outils d'interaction (installation idempotente)
#   bridge            démarrage du pont d'interaction (port 3001)
#   tunnel            déploiement du tunnel cloudflared
#   publish           publication de l'URL + vérification de l'API
#   produce           PHASE DE PRODUCTION (période d'utilisation)
#   dispatch          création et lancement du workflow suivant
#   overlap           chevauchement (le service continue de répondre)
#   stop              auto-arrêt propre + sauvegarde chiffrée
#
# Les processus longs (QEMU, pont, tunnel) survivent entre les étapes :
# ils sont lancés avec nohup et leurs PID sont conservés dans l'état partagé.
#
# Environnement requis selon la phase — voir le workflow.
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-cloudinit.sh"

phase=${1:?usage: qemu-cycle.sh restore|boot|install-desktop|bridge|tunnel|publish|produce|dispatch|overlap|stop}

mkdir -p "$AIOS_STATE_DIR" "$AIOS_WORK_DIR"
cd "$AIOS_WORK_DIR"

pid_alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
file_pid()  { cat "$AIOS_STATE_DIR/$1" 2>/dev/null || true; }
sshopts=(); aios_ssh_options sshopts "$AIOS_WORK_DIR/key" "$AIOS_WORK_DIR/known_hosts"

start_qemu() {
  nohup qemu-system-x86_64 -machine "$AIOS_QEMU_MACHINE" -cpu "$AIOS_QEMU_CPU" -m "$AIOS_QEMU_MEM_MB" -smp "$AIOS_QEMU_SMP" \
    -drive "file=$AIOS_WORK_DIR/disk.img,if=virtio,format=qcow2" -drive "file=$AIOS_WORK_DIR/seed.img,if=virtio,format=raw" \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$AIOS_SSH_PORT-:22 -device virtio-net-pci,netdev=net0 \
    -display none -serial "file:$AIOS_WORK_DIR/qemu-serial-$1.log" -no-reboot </dev/null >"$AIOS_WORK_DIR/qemu-$1.log" 2>&1 &
  echo $! > "$AIOS_STATE_DIR/qemu.pid"
}

start_bridge() {
  AIOS_SSH_KEY="$AIOS_WORK_DIR/key" AIOS_KNOWN_HOSTS="$AIOS_WORK_DIR/known_hosts" \
  AIOS_BRIDGE_HOST="$AIOS_BRIDGE_HOST" AIOS_BRIDGE_PORT="$AIOS_BRIDGE_PORT" \
  AIOS_GUEST_USER="$AIOS_GUEST_USER" AIOS_GUEST_HOME="$AIOS_GUEST_HOME" AIOS_GUEST_DISPLAY="$AIOS_GUEST_DISPLAY" \
    nohup node "$AIOS_REPO_ROOT/scripts/qemu-interaction-bridge.cjs" </dev/null >"$AIOS_WORK_DIR/bridge.log" 2>&1 &
  echo $! > "$AIOS_STATE_DIR/bridge.pid"
}

start_tunnel() {
  nohup "$AIOS_WORK_DIR/cloudflared" tunnel --url "http://$AIOS_BRIDGE_HOST:$AIOS_BRIDGE_PORT" --no-autoupdate \
    </dev/null >"$AIOS_WORK_DIR/tunnel.log" 2>&1 &
  echo $! > "$AIOS_STATE_DIR/tunnel.pid"
}

wait_tunnel_url() {
  local t
  for _ in $(seq 1 90); do
    t=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' "$AIOS_WORK_DIR/tunnel.log" | head -1 || true)
    if [[ -n "$t" ]]; then printf '%s' "$t"; return 0; fi
    sleep 2
  done
  return 1
}

# Surveillance commune aux phases produce et overlap.
monitor_loop() {
  local duration=$1 label=$2
  local start now elapsed last_beat=0
  start=$(date +%s)
  while :; do
    now=$(date +%s); elapsed=$((now - start))
    pid_alive "$(file_pid qemu.pid)" || { aios_warn "QEMU mort en phase $label : sauvegarde d'urgence."; emergency_save; aios_die "VM perdue."; }
    if ! pid_alive "$(file_pid bridge.pid)"; then
      aios_warn "Pont d'interaction arrêté : redémarrage."
      start_bridge
    fi
    if ! pid_alive "$(file_pid tunnel.pid)"; then
      aios_warn "Tunnel arrêté : redémarrage et republication."
      start_tunnel
      local t; t=$(wait_tunnel_url || true)
      if [[ -n "${t:-}" ]]; then state_write tunnel-url "$t"; AIOS_TUNNEL="$t" node "$AIOS_REPO_ROOT/scripts/qemu-publish-tunnel.cjs" || true; fi
    fi
    if (( elapsed - last_beat >= 60 )); then
      last_beat=$elapsed
      local up; up=$(aios_guest_ssh sshopts 30 'uptime -p' 2>/dev/null || echo 'invité muet')
      aios_log "[$label +$((elapsed / 60))m] service actif — VM : $up"
    fi
    (( elapsed >= duration )) && break
    sleep 20
  done
  aios_log "[$label] terminé après $((duration / 60)) min."
}

emergency_save() {
  bash "$AIOS_REPO_ROOT/scripts/aios-data.sh" save "$AIOS_WORK_DIR/disk.img" "${GITHUB_RUN_ID:-crash}" || aios_warn "Sauvegarde d'urgence échouée."
}

# ===========================================================================
case "$phase" in

restore)
  aios_require_env GH_TOKEN AIOS_BACKUP_KEY AIOS_VM_SSH_KEY
  state_write job-start "$(date +%s)"
  printf '%s\n' "$AIOS_VM_SSH_KEY" > "$AIOS_WORK_DIR/key"; chmod 600 "$AIOS_WORK_DIR/key"
  : > "$AIOS_WORK_DIR/known_hosts"
  expected="${PREDECESSOR_RUN_ID:-}"
  if [[ -n "$expected" ]]; then
    aios_log "Attente du checkpoint du cycle $expected..."
    [[ "$expected" =~ ^[0-9]+$ ]] || aios_die "predecessor_run_id invalide"
    ready=0
    for _ in $(seq 1 150); do
      status=$(curl -sS --max-time 15 -o "$AIOS_WORK_DIR/check.json" -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$AIOS_DATA_REPO/contents/CHECKPOINT?ref=$AIOS_DATA_BRANCH" || echo 000)
      if [[ "$status" == 200 ]] && EXPECTED="$expected" python3 -c 'import json,base64,os; d=json.load(open("check.json")); assert base64.b64decode(d["content"]).decode().strip()==os.environ["EXPECTED"]' 2>/dev/null; then ready=1; break; fi
      sleep 15
    done
    [[ "$ready" == 1 ]] || aios_die "Checkpoint non publié : démarrage annulé pour protéger les données."
    bash "$AIOS_REPO_ROOT/scripts/aios-data.sh" restore "$AIOS_WORK_DIR/disk.img" "$expected"
    state_write fresh 0
  else
    status=$(curl -sS --max-time 15 -o "$AIOS_WORK_DIR/check.json" -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$AIOS_DATA_REPO/contents/CHECKPOINT?ref=$AIOS_DATA_BRANCH" || echo 000)
    if [[ "$status" == 200 ]]; then
      expected=$(python3 -c 'import json,base64;print(base64.b64decode(json.load(open("check.json"))["content"]).decode().strip())')
      aios_log "Restauration du dernier checkpoint ($expected)."
      bash "$AIOS_REPO_ROOT/scripts/aios-data.sh" restore "$AIOS_WORK_DIR/disk.img" "$expected"
      state_write fresh 0
    elif [[ "$status" == 404 || "$status" == 409 ]]; then
      aios_log "Aucun checkpoint : création du disque depuis l'image Ubuntu."
      aios_fetch_ubuntu_image "$AIOS_WORK_DIR" disk.img || aios_die "Image Ubuntu indisponible."
      qemu-img resize "$AIOS_WORK_DIR/disk.img" "$AIOS_DISK_SIZE"
      state_write fresh 1
    else
      aios_die "Vérification de la sauvegarde impossible (HTTP $status)."
    fi
  fi
  aios_log "Disque prêt : $AIOS_WORK_DIR/disk.img ($(du -h "$AIOS_WORK_DIR/disk.img" | cut -f1))."
  ;;

boot)
  aios_require_kvm
  pub=$(ssh-keygen -y -f "$AIOS_WORK_DIR/key")
  aios_write_cloudinit "$pub" "$AIOS_INSTANCE_ID"
  cloud-localds "$AIOS_WORK_DIR/seed.img" user-data meta-data
  start_qemu first
  if [[ "$(state_read fresh)" == 1 ]]; then
    aios_log "Première installation : cloud-init installe le noyau puis redémarre."
    for _ in $(seq 1 180); do
      pid_alive "$(file_pid qemu.pid)" || break
      sleep 10
    done
    pid_alive "$(file_pid qemu.pid)" && aios_die "Délai d'installation initiale dépassé."
    start_qemu second
  fi
  ready=0
  for _ in $(seq 1 120); do
    if aios_guest_ssh sshopts 15 "test -f $AIOS_KERNEL_MARKER && . /etc/os-release && test \"\$VERSION_ID\" = 26.10 && uname -r | grep -q \"^${AIOS_KERNEL_ABBREV//./\\.}\"" 2>/dev/null; then ready=1; break; fi
    pid_alive "$(file_pid qemu.pid)" || aios_die "QEMU arrêté prématurément."
    sleep 5
  done
  [[ "$ready" == 1 ]] || aios_die "VM non disponible."
  state_write ready-at "$(date +%s)"
  aios_log "VM prête : Ubuntu 26.10, noyau $AIOS_KERNEL_VERSION."
  ;;

install-desktop)
  aios_guest_ensure_desktop sshopts || aios_warn "Installation incomplète — certaines routes de l'API échoueront."
  aios_guest_start_desktop sshopts
  aios_log "Bureau X démarré (Xvfb $AIOS_GUEST_DISPLAY, XFCE)."
  ;;

bridge)
  aios_require_env VM_API_TOKEN
  start_bridge
  for _ in $(seq 1 15); do
    curl -sf --max-time 2 -H "Authorization: Bearer $VM_API_TOKEN" "http://$AIOS_BRIDGE_HOST:$AIOS_BRIDGE_PORT/health" >/dev/null && break
    sleep 1
  done
  curl -s --max-time 2 -H "Authorization: Bearer $VM_API_TOKEN" "http://$AIOS_BRIDGE_HOST:$AIOS_BRIDGE_PORT/health" || aios_die "Pont d'interaction injoignable."
  aios_log "Pont d'interaction opérationnel (port $AIOS_BRIDGE_PORT)."
  ;;

tunnel)
  if [[ ! -x "$AIOS_WORK_DIR/cloudflared" ]]; then
    aios_log "Téléchargement de cloudflared..."
    curl -fsSL "$CLOUDFLARED_URL" -o "$AIOS_WORK_DIR/cloudflared"
    chmod +x "$AIOS_WORK_DIR/cloudflared"
  fi
  start_tunnel
  t=$(wait_tunnel_url) || aios_die "Tunnel indisponible."
  state_write tunnel-url "$t"
  aios_log "Tunnel cloudflared déployé : $t"
  ;;

publish)
  aios_require_env GH_TOKEN
  t=$(state_read tunnel-url); [[ -n "$t" ]] || aios_die "Aucune URL de tunnel."
  AIOS_TUNNEL="$t" node "$AIOS_REPO_ROOT/scripts/qemu-publish-tunnel.cjs"
  if [[ -n "${VM_API_TOKEN:-}" ]]; then
    ok=0
    for _ in 1 2 3 4 5; do
      if curl -sf --max-time 10 -H "Authorization: Bearer $VM_API_TOKEN" "$t/health" > "$AIOS_WORK_DIR/api-check.json"; then ok=1; break; fi
      sleep 5
    done
    [[ "$ok" == 1 ]] || aios_die "L'API d'interaction ne répond pas à travers le tunnel."
    aios_log "API vérifiée à travers le tunnel : $(cat "$AIOS_WORK_DIR/api-check.json" | head -c 200)"
  else
    aios_warn "VM_API_TOKEN absent : vérification de l'API ignorée."
  fi
  ;;

produce)
  [[ -n "$(state_read ready-at)" ]] || aios_die "ready-at manquant : la phase boot n'a pas tourné."
  duration="$AIOS_PRODUCE_SECONDS"
  [[ "${TEST_RELAY:-false}" == true ]] && duration=40 && aios_log "Mode test : production ramenée à ${duration}s."
  job_start=$(state_read job-start); now=$(date +%s)
  if (( job_start + AIOS_JOB_BUDGET_SECONDS < now + duration + AIOS_OVERLAP_SECONDS + 1200 )); then
    aios_warn "Le cycle complet dépassera 6 h : la sauvegarde risque d'être coupée."
  fi
  aios_log "PHASE DE PRODUCTION : $((duration / 60)) min d'utilisation à partir de maintenant."
  monitor_loop "$duration" "production"
  ;;

dispatch)
  aios_require_env GH_TOKEN
  [[ -n "${GITHUB_RUN_ID:-}" ]] || aios_die "GITHUB_RUN_ID absent."
  json=$(printf '{"ref":"main","inputs":{"predecessor_run_id":"%s"}}' "$GITHUB_RUN_ID")
  done_dispatch=0
  for attempt in 1 2 3 4 5; do
    if curl --fail-with-body -sS --max-time 30 -X POST \
        -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/qemu-durable.yml/dispatches" -d "$json"; then
      done_dispatch=1; break
    fi
    aios_warn "Déclenchement du cycle suivant : tentative $attempt échouée."
    sleep 15
  done
  [[ "$done_dispatch" == 1 ]] || aios_warn "Cycle suivant NON déclenché : la sauvegarde sera néanmoins faite."
  state_write dispatched "$done_dispatch"
  aios_log "Workflow suivant créé et lancé (predecessor_run_id=$GITHUB_RUN_ID)."
  ;;

overlap)
  duration="$AIOS_OVERLAP_SECONDS"
  [[ "${TEST_RELAY:-false}" == true ]] && duration=60 && aios_log "Mode test : chevauchement ramené à ${duration}s."
  aios_log "CHEVAUCHEMENT : le service continue de répondre $((duration / 60)) min pendant que le successeur restaure."
  monitor_loop "$duration" "chevauchement"
  ;;

stop)
  aios_log "Auto-arrêt : arrêt propre de l'invité avant sauvegarde chiffrée."
  aios_guest_ssh sshopts 60 'sudo sync && sudo shutdown -h now' || true
  stopped=0
  for _ in $(seq 1 120); do
    pid_alive "$(file_pid qemu.pid)" || { stopped=1; break; }
    sleep 2
  done
  [[ "$stopped" == 1 ]] || aios_die "Arrêt non confirmé : sauvegarde annulée pour ne pas publier un disque vivant."
  bash "$AIOS_REPO_ROOT/scripts/aios-data.sh" save "$AIOS_WORK_DIR/disk.img" "${GITHUB_RUN_ID:?}"
  kill "$(file_pid bridge.pid)" 2>/dev/null || true
  kill "$(file_pid tunnel.pid)" 2>/dev/null || true
  aios_log "Cycle terminé : checkpoint publié, services arrêtés."
  ;;

*)
  aios_die "Phase inconnue : $phase"
  ;;
esac
