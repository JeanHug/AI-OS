#!/usr/bin/env bash
set -Eeuo pipefail
# Test jetable uniquement : aucune sauvegarde, tunnel ni interface distante.
work=$(mktemp -d)
qemu_pid=''
cleanup() {
  if [[ -n "$qemu_pid" ]]; then kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
cd "$work"
base=https://cloud-images.ubuntu.com/releases/stonking/release
image=ubuntu-26.10-server-cloudimg-amd64.img
curl -fsSLo SHA256SUMS "$base/SHA256SUMS"
curl -fSL --retry 3 -o "$image" "$base/$image"
grep -F "*$image" SHA256SUMS | sha256sum -c -
qemu-img resize "$image" 16G
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
pub=$(cat "$work/key.pub")
cat > user-data <<EOF_CLOUD
#cloud-config
users:
  - name: aios
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $pub
package_update: true
packages:
  - openssh-server
  - curl
  - xfce4
  - xvfb
  - scrot
runcmd:
  - [bash, -c, 'set -e; mkdir -p /root/kernel731; cd /root/kernel731; base=https://kernel.ubuntu.com/mainline/v7.3.1/amd64; for f in linux-image-unsigned-7.3.1-070301-generic_7.3.1-070301.202610301300_amd64.deb linux-modules-7.3.1-070301-generic_7.3.1-070301.202610301300_amd64.deb; do curl -fSL --retry 3 -O "\$base/\$f"; done; curl -fsSLO "\$base/CHECKSUMS"; grep -E "^[a-f0-9]{64}  linux-(image-unsigned|modules)-7.3.1-070301-generic_7.3.1-070301.202610301300_amd64.deb\$" CHECKSUMS | sha256sum -c -; apt-get install -y ./linux-modules-*.deb ./linux-image-unsigned-*.deb; touch /var/lib/aios-kernel-installed; reboot']
EOF_CLOUD
cat > meta-data <<EOF_META
instance-id: aios-qemu-validation
local-hostname: aios
EOF_META
cloud-localds seed.img user-data meta-data
[[ -r /dev/kvm && -w /dev/kvm ]] || { echo "KVM requis : émulation TCG désactivée pour éviter une attente excessive."; exit 1; }
accel=kvm
cpu=host
echo "Accélération : KVM"
qemu-system-x86_64 -machine "q35,accel=$accel" -cpu "$cpu" -m 3072 -smp 2 \
  -drive "file=$image,if=virtio,format=qcow2" -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net-pci,netdev=net0 \
  -display none -serial file:qemu-serial.log -no-reboot &
qemu_pid=$!
# -no-reboot stops QEMU on guest reboot; reboot into updated kernel below.
sshopts=(-i "$work/key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$work/known_hosts" -o BatchMode=yes -o ConnectTimeout=4 -p 22222)
started=0
for _ in $(seq 1 180); do
 if ssh "${sshopts[@]}" aios@127.0.0.1 'test -f /var/lib/aios-kernel-installed' 2>/dev/null; then started=1; break; fi
 if ! kill -0 "$qemu_pid" 2>/dev/null; then break; fi
 sleep 10
done
if [[ $started -ne 1 ]] && kill -0 "$qemu_pid" 2>/dev/null; then echo 'Installation noyau non terminée'; exit 1; fi
wait "$qemu_pid" || true
qemu-system-x86_64 -machine "q35,accel=$accel" -cpu "$cpu" -m 3072 -smp 2 \
  -drive "file=$image,if=virtio,format=qcow2" -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net-pci,netdev=net0 \
  -display none -serial file:qemu-serial-second.log -no-reboot &
qemu_pid=$!
for _ in $(seq 1 120); do
 if ssh "${sshopts[@]}" aios@127.0.0.1 'test -f /var/lib/aios-kernel-installed && . /etc/os-release && test "$VERSION_ID" = 26.10 && uname -r | grep -q "^7\.3\.1"' 2>/dev/null; then
  echo 'Validation réussie : Ubuntu 26.10 avec noyau 7.3.1'; break
 fi
 kill -0 "$qemu_pid" 2>/dev/null || { echo 'QEMU arrêté prématurément'; exit 1; }
 sleep 10
done
ssh "${sshopts[@]}" aios@127.0.0.1 'test -f /var/lib/aios-kernel-installed && uname -r | grep -q "^7\.3\.1"' || { echo "VM non disponible"; exit 1; }
ssh "${sshopts[@]}" aios@127.0.0.1 'nohup Xvfb :99 -screen 0 1280x720x24 >/tmp/aios-xvfb.log 2>&1 </dev/null & nohup env DISPLAY=:99 xfce4-session >/tmp/aios-xfce.log 2>&1 </dev/null &' 
export AIOS_SSH_KEY="$work/key" AIOS_KNOWN_HOSTS="$work/known_hosts"
node "$GITHUB_WORKSPACE/scripts/qemu-screenshot-bridge.cjs" &
bridge_pid=$!
# Origin is authenticated independently of the Worker; never log the token.
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
chmod +x cloudflared
./cloudflared tunnel --url http://127.0.0.1:3001 --no-autoupdate > tunnel.log 2>&1 &
for _ in $(seq 1 90); do
 tunnel=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' tunnel.log | head -1 || true)
 [[ -n "$tunnel" ]] && break
 sleep 2
done
[[ -n "${tunnel:-}" ]] || { echo 'Tunnel indisponible'; exit 1; }
export AIOS_TUNNEL="$tunnel"
node "$GITHUB_WORKSPACE/scripts/qemu-publish-tunnel.cjs"
echo 'Passerelle de capture disponible. VM éphémère ; aucune persistance.'
# Keep the runner alive for a bounded diagnostic session.
for _ in $(seq 1 120); do kill -0 "$qemu_pid" && kill -0 "$bridge_pid" || exit 1; sleep 20; done
