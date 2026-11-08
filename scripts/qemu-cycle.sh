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
  # Tunnel durable nommé « ai-os » (déclaré à Cloudflare via l'API, config
  # distante ingress → pont :3001). Le jeton connecteur est récupéré à chaque
  # démarrage avec CLOUDFLARE_TOKEN : l'URL publique ne change JAMAIS.
  local tok
  tok=$(curl -fsS --retry 3 --retry-all-errors --max-time 30 -H "Authorization: Bearer ${CLOUDFLARE_TOKEN:-}" \
    "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ID:-}/cfd_tunnel/${AIOS_TUNNEL_ID}/token" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result") or "", end="")') || true
  [[ -n "$tok" ]] || aios_die "Jeton connecteur du tunnel durable indisponible (CLOUDFLARE_TOKEN/CLOUDFLARE_ID)."
  # NB : --no-autoupdate est un drapeau GLOBAL : avant le sous-commande « tunnel ».
  nohup "$AIOS_WORK_DIR/cloudflared" --no-autoupdate tunnel run --token "$tok" \
    </dev/null >"$AIOS_WORK_DIR/tunnel.log" 2>&1 &
  echo $! > "$AIOS_STATE_DIR/tunnel.pid"
}

# Forward SSH persistent : runner:6080 → invité:6080 (noVNC/websockify).
start_vnc_forward() {
  nohup ssh "${sshopts[@]}" -N -L 6080:127.0.0.1:6080 "$AIOS_GUEST_USER@127.0.0.1" \
    </dev/null >"$AIOS_WORK_DIR/vncfwd.log" 2>&1 &
  echo $! > "$AIOS_STATE_DIR/vncfwd.pid"
}

wait_tunnel_registered() {
  # Le connecteur durable annonce « Registered tunnel connection » dès que
  # ses liaisons avec l'edge Cloudflare sont établies (aucune URL à attendre).
  for _ in $(seq 1 30); do
    grep -q 'Registered tunnel connection' "$AIOS_WORK_DIR/tunnel.log" 2>/dev/null && return 0
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
    if ! pid_alive "$(file_pid vncfwd.pid)"; then
      aios_warn "Forward du flux bureau arrêté : redémarrage."
      start_vnc_forward
    fi
    if [[ "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:6080/" || true)" == "000" ]]; then
      aios_warn "Flux bureau (noVNC) injoignable : relance du flux invité et du forward."
      aios_guest_start_stream sshopts || true
      kill "$(file_pid vncfwd.pid)" 2>/dev/null || true
      start_vnc_forward
    fi
    if ! pid_alive "$(file_pid tunnel.pid)"; then
      aios_warn "Tunnel durable arrêté : redémarrage."
      start_tunnel
      wait_tunnel_registered || true
      state_write tunnel-url "$AIOS_DESK_URL"
      AIOS_TUNNEL="$AIOS_DESK_URL" node "$AIOS_REPO_ROOT/scripts/qemu-publish-tunnel.cjs" || true
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

save_checkpoint() {
  # Une seule sauvegarde par cycle, publiée au DÉBUT du chevauchement : le
  # successeur restaure pendant que l'ancien continue de servir — aucun trou.
  # La copie se fait à chaud (invité vivant, sync avant) : cohérente au sens
  # journal ext4. Le stop ne sauvegarde plus : personne ne consommerait cette
  # génération, et réécrire la branche désynchroniserait le téléchargement
  # en cours du successeur.
  [[ "$(state_read saved)" == "1" ]] && return 0
  aios_guest_ssh sshopts 60 'sudo sync' || true
  if bash "$AIOS_REPO_ROOT/scripts/aios-data.sh" save "$AIOS_WORK_DIR/disk.img" "${GITHUB_RUN_ID:?}"; then
    state_write saved 1
    return 0
  fi
  return 1
}

emergency_save() {
  save_checkpoint || aios_warn "Sauvegarde d'urgence échouée."
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
  aios_guest_ensure_stream sshopts || true
  aios_guest_start_desktop sshopts
  aios_guest_start_stream sshopts
  aios_log "Bureau X démarré (Xvfb $AIOS_GUEST_DISPLAY, XFCE) + flux interactif (x11vnc/noVNC)."
  ;;

bridge)
  aios_require_env VM_API_TOKEN
  start_bridge
  start_vnc_forward
  for _ in $(seq 1 15); do
    curl -sf --max-time 2 -H "Authorization: Bearer $VM_API_TOKEN" "http://$AIOS_BRIDGE_HOST:$AIOS_BRIDGE_PORT/health" >/dev/null && break
    sleep 1
  done
  curl -s --max-time 2 -H "Authorization: Bearer $VM_API_TOKEN" "http://$AIOS_BRIDGE_HOST:$AIOS_BRIDGE_PORT/health" || aios_die "Pont d'interaction injoignable."
  # Le flux bureau doit être joignable à travers le forward SSH ; à défaut,
  # relance idempotente du flux invité (x11vnc + websockify) puis du forward.
  # N'importe quelle réponse HTTP prouve que le démon écoute : seule l'absence
  # de connexion (code 000) compte comme panne.
  vnc_up() { [[ "$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:6080/" || true)" != "000" ]]; }
  if ! vnc_up; then
    aios_warn "noVNC injoignable : relance du flux invité et du forward."
    aios_guest_start_stream sshopts
    kill "$(file_pid vncfwd.pid)" 2>/dev/null || true
    start_vnc_forward
    sleep 3
  fi
  if ! vnc_up; then
    aios_log "Diagnostic invité :"
    aios_guest_ssh sshopts 15 'ss -ltn 2>/dev/null | grep -E "6080|5900" || echo "aucune écoute 6080/5900"; pgrep -af "[w]ebsockify|x11vnc" || echo "aucun processus de flux"; tail -n 8 /tmp/aios-websockify.log /tmp/aios-x11vnc.log 2>/dev/null || true' || true
    aios_die "Flux bureau (noVNC) injoignable après relance."
  fi
  aios_log "Pont d'interaction opérationnel (port $AIOS_BRIDGE_PORT, flux bureau via forward SSH)."
  ;;

tunnel)
  if [[ ! -x "$AIOS_WORK_DIR/cloudflared" ]]; then
    aios_log "Téléchargement de cloudflared..."
    dl_ok=0
    for _ in 1 2 3 4 5; do
      if curl -fsSL --retry 2 --max-time 300 "$CLOUDFLARED_URL" -o "$AIOS_WORK_DIR/cloudflared"; then
        chmod +x "$AIOS_WORK_DIR/cloudflared" && dl_ok=1 && break
      fi
      aios_warn "Téléchargement de cloudflared échoué (réseau) : nouvelle tentative..."
      sleep 5
    done
    [[ "$dl_ok" == 1 ]] || aios_die "cloudflared impossible à télécharger après 5 tentatives."
  fi
  start_tunnel
  if ! wait_tunnel_registered; then
    aios_log "Fin de tunnel.log :"; tail -n 15 "$AIOS_WORK_DIR/tunnel.log" || true
    aios_die "Tunnel durable non enregistré auprès de Cloudflare."
  fi
  state_write tunnel-url "$AIOS_DESK_URL"
  aios_log "Tunnel durable « $AIOS_TUNNEL_NAME » actif — lien interactif fixe : $AIOS_DESK_URL"
  ;;

publish)
  aios_require_env GH_TOKEN
  t=$(state_read tunnel-url); [[ -n "$t" ]] || t="$AIOS_DESK_URL"
  state_write tunnel-url "$t"
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
  aios_log "CHEVAUCHEMENT : sauvegarde à chaud du checkpoint, puis service continu $((duration / 60)) min pendant que le successeur restaure."
  save_checkpoint || aios_die "Sauvegarde du checkpoint impossible : le successeur ne pourra pas démarrer."
  monitor_loop "$duration" "chevauchement"
  ;;

stop)
  aios_log "Auto-arrêt : arrêt propre de l'invité (le checkpoint est déjà publié depuis le chevauchement)."
  aios_guest_ssh sshopts 60 'sudo sync && sudo shutdown -h now' || true
  stopped=0
  for _ in $(seq 1 120); do
    pid_alive "$(file_pid qemu.pid)" || { stopped=1; break; }
    sleep 2
  done
  [[ "$stopped" == 1 ]] || aios_warn "Arrêt non confirmé : on poursuit (le checkpoint est déjà publié)."
  save_checkpoint || aios_die "Sauvegarde chiffrée impossible."
  kill "$(file_pid bridge.pid)" 2>/dev/null || true
  kill "$(file_pid tunnel.pid)" 2>/dev/null || true
  kill "$(file_pid vncfwd.pid)" 2>/dev/null || true
  aios_log "Cycle terminé : checkpoint publié, services arrêtés."
  ;;

*)
  aios_die "Phase inconnue : $phase"
  ;;
esac
