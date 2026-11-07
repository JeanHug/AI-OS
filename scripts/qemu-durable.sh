#!/usr/bin/env bash
set -Eeuo pipefail
: "${GH_TOKEN:?}" "${AIOS_BACKUP_KEY:?}" "${AIOS_VM_SSH_KEY:?}" "${VM_API_TOKEN:?}"
work=$(mktemp -d); qemu_pid=''; tunnel_pid=''; bridge_pid=''
cleanup(){ [[ -n "$tunnel_pid" ]] && kill "$tunnel_pid" 2>/dev/null || true; [[ -n "$bridge_pid" ]] && kill "$bridge_pid" 2>/dev/null || true; [[ -n "$qemu_pid" ]] && kill "$qemu_pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
cd "$work"
[[ -r /dev/kvm && -w /dev/kvm ]] || { echo 'KVM indisponible'; exit 1; }
image="$work/disk.img"; printf '%s\n' "$AIOS_VM_SSH_KEY" > "$work/key"; chmod 600 "$work/key"; pub=$(ssh-keygen -y -f "$work/key")
expected="${PREDECESSOR_RUN_ID:-}"
if [[ -n "$expected" ]]; then
  echo "Attente du checkpoint du cycle précédent..."
  [[ "$expected" =~ ^[0-9]+$ ]] || exit 2
  ready=0
  for _ in $(seq 1 150); do
    status=$(curl -sS --max-time 15 -o "$work/check.json" -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/JeanHug/ai-os-data-private/contents/CHECKPOINT?ref=snapshot" || echo 000)
    if [[ "$status" == 200 ]] && EXPECTED="$expected" python3 -c 'import json,base64,os; d=json.load(open("check.json")); assert base64.b64decode(d["content"]).decode().strip()==os.environ["EXPECTED"]' 2>/dev/null; then ready=1; break; fi
    sleep 15
  done
  [[ "$ready" == 1 ]] || { echo 'Checkpoint non publié : démarrage annulé pour protéger les données'; exit 1; }
  bash "$GITHUB_WORKSPACE/scripts/aios-data.sh" restore "$image" "$expected"
  fresh=0
else
  status=$(curl -sS --max-time 15 -o "$work/check.json" -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' 'https://api.github.com/repos/JeanHug/ai-os-data-private/contents/CHECKPOINT?ref=snapshot' || echo 000)
  if [[ "$status" == 200 ]]; then
    expected=$(python3 -c 'import json,base64;print(base64.b64decode(json.load(open("check.json"))["content"]).decode().strip())')
    echo 'Restauration du dernier checkpoint existant.'
    bash "$GITHUB_WORKSPACE/scripts/aios-data.sh" restore "$image" "$expected"; fresh=0
  elif [[ "$status" == 404 || "$status" == 409 ]]; then
    base=https://cloud-images.ubuntu.com/releases/stonking/release; source_image=ubuntu-26.10-server-cloudimg-amd64.img
    curl -fsSLo SHA256SUMS "$base/SHA256SUMS"; curl -fSL --retry 3 -o "$source_image" "$base/$source_image"
    grep -F "*$source_image" SHA256SUMS | sha256sum -c -; mv "$source_image" "$image"; qemu-img resize "$image" 16G; fresh=1
  else echo "Impossible de vérifier la sauvegarde (HTTP $status)"; exit 1; fi
fi
cat > user-data <<EOF_CLOUD
#cloud-config
users:
  - name: aios
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $pub
write_files:
  - path: /etc/polkit-1/rules.d/49-aios-colord.rules
    owner: root:root
    permissions: '0644'
    content: |
      polkit.addRule(function(action, subject) {
        var allowed = ["org.freedesktop.color-manager.create-device", "org.freedesktop.color-manager.create-profile", "org.freedesktop.color-manager.modify-device", "org.freedesktop.color-manager.modify-profile"];
        if (subject.user === "aios" && allowed.indexOf(action.id) !== -1) return polkit.Result.YES;
      });
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
start_vm(){
 qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 3072 -smp 2 \
  -drive "file=$image,if=virtio,format=qcow2" -drive file=seed.img,if=virtio,format=raw \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net-pci,netdev=net0 \
  -display none -serial file:qemu-serial.log -no-reboot & qemu_pid=$!
}
sshopts=(-i "$work/key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$work/known_hosts" -o BatchMode=yes -o ConnectTimeout=4 -p 22222)
start_vm
if [[ "$fresh" == 1 ]]; then
 echo 'Installation initiale du système et du noyau...'
 for _ in $(seq 1 180); do
  if ! kill -0 "$qemu_pid" 2>/dev/null; then break; fi
  sleep 10
 done
 if kill -0 "$qemu_pid" 2>/dev/null; then echo 'Délai installation initiale dépassé'; exit 1; fi
 wait "$qemu_pid" || true; start_vm
fi
ready=0
for _ in $(seq 1 120); do
 if ssh "${sshopts[@]}" aios@127.0.0.1 'test -f /var/lib/aios-kernel-installed && . /etc/os-release && test "$VERSION_ID" = 26.10 && uname -r | grep -q "^7\.3\.1"' 2>/dev/null; then ready=1; break; fi
 kill -0 "$qemu_pid" 2>/dev/null || { echo 'QEMU arrêté prématurément'; exit 1; }; sleep 5
done
[[ "$ready" == 1 ]] || { echo 'Démarrage VM non confirmé'; exit 1; }
ssh "${sshopts[@]}" aios@127.0.0.1 'nohup Xvfb :99 -screen 0 1280x720x24 >/tmp/aios-xvfb.log 2>&1 </dev/null & nohup env DISPLAY=:99 xfce4-session >/tmp/aios-xfce.log 2>&1 </dev/null &'
export AIOS_SSH_KEY="$work/key" AIOS_KNOWN_HOSTS="$work/known_hosts"
node "$GITHUB_WORKSPACE/scripts/qemu-screenshot-bridge.cjs" & bridge_pid=$!
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared; chmod +x cloudflared
./cloudflared tunnel --url http://127.0.0.1:3001 --no-autoupdate > tunnel.log 2>&1 & tunnel_pid=$!
for _ in $(seq 1 90); do tunnel=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' tunnel.log | head -1 || true); [[ -n "$tunnel" ]] && break; sleep 2; done
[[ -n "${tunnel:-}" ]] || { echo 'Tunnel indisponible'; exit 1; }
export AIOS_TUNNEL="$tunnel"; node "$GITHUB_WORKSPACE/scripts/qemu-publish-tunnel.cjs"
echo 'VM prête. Le prochain cycle sera déclenché avant la sauvegarde.'
# Timings can be shortened only for a deliberate disposable end-to-end test.
trigger_seconds="${RELAY_TRIGGER_SECONDS:-18900}"; shutdown_seconds="${RELAY_SHUTDOWN_SECONDS:-19800}"
[[ "$trigger_seconds" =~ ^[0-9]+$ && "$shutdown_seconds" =~ ^[0-9]+$ && "$shutdown_seconds" -gt "$trigger_seconds" ]] || exit 2
start=$(date +%s); triggered=0
while :; do
 now=$(date +%s); elapsed=$((now-start))
 kill -0 "$qemu_pid" && kill -0 "$bridge_pid" && kill -0 "$tunnel_pid" || { echo 'VM ou tunnel arrêté sans checkpoint'; exit 1; }
 if (( !triggered && elapsed >= trigger_seconds )); then
  json=$(printf '{"ref":"main","inputs":{"predecessor_run_id":"%s"}}' "$GITHUB_RUN_ID")
  curl --fail-with-body -sS -X POST -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/qemu-durable.yml/dispatches" -d "$json"
  triggered=1; echo 'Cycle suivant déclenché : attente du checkpoint.'
 fi
 if (( elapsed >= shutdown_seconds )); then
  echo 'Arrêt propre du système invité avant sauvegarde chiffrée.'
  ssh "${sshopts[@]}" aios@127.0.0.1 'sudo sync && sudo shutdown -h now' || true
  stopped=0; for _ in $(seq 1 120); do if ! kill -0 "$qemu_pid" 2>/dev/null; then stopped=1; break; fi; sleep 2; done
  [[ "$stopped" == 1 ]] || { echo 'Arrêt non confirmé : sauvegarde annulée'; exit 1; }
  wait "$qemu_pid" || true; qemu_pid=''
  bash "$GITHUB_WORKSPACE/scripts/aios-data.sh" save "$image" "$GITHUB_RUN_ID"
  echo 'Checkpoint chiffré publié pour le prochain cycle.'; exit 0
 fi
 sleep 20
done
