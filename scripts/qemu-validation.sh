#!/usr/bin/env bash
# qemu-validation.sh — validation OS + noyau, sans bureau ni tunnel.
# KVM obligatoire : le repli silencieux en émulation TCG a déjà coûté un run
# de 16 minutes et est interdit dans tous les chemins AI OS.
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib-cloudinit.sh"

work=$(mktemp -d)
qemu_pid=''
cleanup() {
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
aios_write_cloudinit "$pub" "$AIOS_INSTANCE_ID_VALIDATION" minimal
cloud-localds seed.img user-data meta-data

start_vm() {
  qemu-system-x86_64 -machine "$AIOS_QEMU_MACHINE" -cpu "$AIOS_QEMU_CPU" -m "$AIOS_QEMU_MEM_MB" -smp "$AIOS_QEMU_SMP" \
    -drive "file=$work/disk.img,if=virtio,format=qcow2" -drive file=seed.img,if=virtio,format=raw \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:$AIOS_SSH_PORT-:22 -device virtio-net-pci,netdev=net0 \
    -display none -serial "file:qemu-serial-$1.log" -no-reboot &
  qemu_pid=$!
}

sshopts=(); aios_ssh_options sshopts "$work/key" "$work/known_hosts"
start_vm first

started=0
for _ in $(seq 1 180); do
  if ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" "test -f $AIOS_KERNEL_MARKER" 2>/dev/null; then started=1; break; fi
  kill -0 "$qemu_pid" 2>/dev/null || break
  sleep 10
done
if [[ $started -ne 1 ]] && kill -0 "$qemu_pid" 2>/dev/null; then aios_die 'Installation noyau non terminée'; fi
wait "$qemu_pid" || true

start_vm second
for _ in $(seq 1 120); do
  if ssh "${sshopts[@]}" "$AIOS_GUEST_USER@127.0.0.1" "test -f $AIOS_KERNEL_MARKER && . /etc/os-release && test \"\$VERSION_ID\" = 26.10 && uname -r | grep -q \"^${AIOS_KERNEL_ABBREV//./\\.}\"" 2>/dev/null; then
    aios_log "Validation réussie : Ubuntu 26.10 avec noyau $AIOS_KERNEL_VERSION"
    exit 0
  fi
  kill -0 "$qemu_pid" 2>/dev/null || aios_die 'QEMU arrêté prématurément'
  sleep 10
done
aios_die 'Validation échouée ou délai dépassé'
