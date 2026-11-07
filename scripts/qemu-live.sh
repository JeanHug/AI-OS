#!/usr/bin/env bash
# qemu-live.sh — session de diagnostic jetable.
# VM neuve, tunnel + pont d'interaction publiés sous tunnels-linux-live.json
# (jamais le fichier de production), aucune sauvegarde.
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-cloudinit.sh"

work=$(mktemp -d)
qemu_pid=''; tunnel_pid=''; bridge_pid=''
cleanup() {
  [[ -n "$tunnel_pid" ]] && kill "$tunnel_pid" 2>/dev/null || true
  [[ -n "$bridge_pid" ]] && kill "$bridge_pid" 2>/dev/null || true
  [[ -n "$qemu_pid" ]] && kill "$qemu_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
cd "$work"

aios_require_kvm

aios_log "Téléchargement de l'image Ubuntu..."
aios_fetch_ubuntu_image "$work" disk.img || aios_die "Image Ubuntu indisponible"
qemu-img resize disk.img "$AIOS_DISK_SIZE"

ssh-keygen -q -t ed25519 -N '' -f "$work/key"
pub=$(cat "$work/key.pub")
aios_write_cloudinit "$pub" "$AIOS_INSTANCE_ID"
cloud-localds seed.img user-data meta-data

qemu-system-x86_64 -machine "$AIOS_QEMU_MACHINE" -cpu "$AIOS_QEMU_CPU" -m "$AIOS_QEMU_MEM_MB" -smp "$AIOS_QEMU_SMP" \
  -drive "file=$work/disk.img,if=virtio,format=qcow2" -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$AIOS_SSH_PORT-:22 -device virtio-net-pci,netdev=net0 \
  -display none -serial file:qemu-serial.log -no-reboot &
qemu_pid=$!

sshopts=(); aios_ssh_options sshopts "$work/key" "$work/known_hosts"

# Premier démarrage : cloud-init installe le noyau puis redémarre (-no-reboot
# arrête QEMU ; on relance pour basculer sur le noyau 7.3.1).
started=0
for _ in $(seq 1 180); do
  if aios_guest_ssh sshopts 20 "test -f $AIOS_KERNEL_MARKER" 2>/dev/null; then started=1; break; fi
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 10
done
if [[ $started -ne 1 ]] && kill -0 "$qemu_pid" 2>/dev/null; then aios_die 'Installation noyau non terminée'; fi
wait "$qemu_pid" || true
qemu-system-x86_64 -machine "$AIOS_QEMU_MACHINE" -cpu "$AIOS_QEMU_CPU" -m "$AIOS_QEMU_MEM_MB" -smp "$AIOS_QEMU_SMP" \
  -drive "file=$work/disk.img,if=virtio,format=qcow2" -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$AIOS_SSH_PORT-:22 -device virtio-net-pci,netdev=net0 \
  -display none -serial file:qemu-serial-second.log -no-reboot &
qemu_pid=$!

ready=0
for _ in $(seq 1 120); do
  if aios_guest_ssh sshopts 20 "test -f $AIOS_KERNEL_MARKER && . /etc/os-release && test \"\$VERSION_ID\" = 26.10 && uname -r | grep -q \"^${AIOS_KERNEL_ABBREV//./\\.}\"" 2>/dev/null; then
    ready=1; break
  fi
  kill -0 "$qemu_pid" 2>/dev/null || aios_die 'QEMU arrêté prématurément'
  sleep 10
done
[[ "$ready" == 1 ]] || aios_die 'VM non disponible'
aios_log 'VM prête : Ubuntu 26.10 avec noyau '"$AIOS_KERNEL_VERSION"

aios_guest_ensure_desktop sshopts || aios_warn "Installation des outils incomplète."
aios_guest_start_desktop sshopts

AIOS_SSH_KEY="$work/key" AIOS_KNOWN_HOSTS="$work/known_hosts" \
  node "$GITHUB_WORKSPACE/scripts/qemu-interaction-bridge.cjs" > bridge.log 2>&1 &
bridge_pid=$!

# Jamais de publication vers tunnels-linux.json (fichier de production) :
# la session live est publiée sous son propre nom, dans les limites du job.
curl -fsSL "$CLOUDFLARED_URL" -o cloudflared; chmod +x cloudflared
./cloudflared tunnel --url "http://$AIOS_BRIDGE_HOST:$AIOS_BRIDGE_PORT" --no-autoupdate > tunnel.log 2>&1 &
tunnel_pid=$!
tunnel=''
for _ in $(seq 1 90); do
  tunnel=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' tunnel.log | head -1 || true)
  [[ -n "$tunnel" ]] && break
  sleep 2
done
[[ -n "${tunnel:-}" ]] || aios_die 'Tunnel indisponible'
AIOS_TUNNEL="$tunnel" AIOS_TUNNEL_FILE="tunnels-linux-live.json" node "$GITHUB_WORKSPACE/scripts/qemu-publish-tunnel.cjs"
aios_log "Passerelle d'interaction disponible : $tunnel (jeton VM_API_TOKEN requis). VM éphémère ; aucune persistance."

for _ in $(seq 1 120); do
  kill -0 "$qemu_pid" && kill -0 "$bridge_pid" || exit 1
  sleep 20
done
