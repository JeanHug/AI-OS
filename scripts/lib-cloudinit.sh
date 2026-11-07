#!/usr/bin/env bash
# lib-cloudinit.sh — génération du seed cloud-init (user-data + meta-data).
#
# Unique source du cloud-init des trois chemins QEMU (durable, live, validation).
# Le noyau est installé par un script séparé écrit via write_files : aucune
# citation YAML imbriquée, aucun échappement fragile.
#
# Usage : aios_write_cloudinit <clé-pub-ssh> <instance-id> <mode>
#   mode = full      → bureau XFCE + outils d'interaction
#          minimal   → validation seule (pas de bureau)
# Écrit user-data et meta-data dans le répertoire courant.

aios_write_cloudinit() {
  local pub=$1 iid=$2 mode=$3
  local kscript
  kscript="$(mktemp)"

  # --- Script d'installation du noyau, exécuté une seule fois (marqueur) ---
  sed -e "s/__KERNEL_ABBREV__/$AIOS_KERNEL_ABBREV/g" \
      -e "s/__KERNEL_VERSION__/$AIOS_KERNEL_VERSION/g" \
      -e "s/__KERNEL_BUILD__/$AIOS_KERNEL_BUILD/g" > "$kscript" <<'KSCRIPT'
#!/bin/bash
# Installation du noyau AI OS. Idempotent : verrouillée par le marqueur.
set -e
MARKER=/var/lib/aios-kernel-installed
if [ -f "$MARKER" ]; then exit 0; fi
KVER="__KERNEL_VERSION__"
BUILD="__KERNEL_BUILD__"
mkdir -p /root/kernel731 && cd /root/kernel731
base="https://kernel.ubuntu.com/mainline/v__KERNEL_ABBREV__/amd64"
for f in "linux-image-unsigned-${KVER}-generic_${KVER}.${BUILD}_amd64.deb" \
         "linux-modules-${KVER}-generic_${KVER}.${BUILD}_amd64.deb"; do
  curl -fSL --retry 3 -O "$base/$f"
done
curl -fsSLO "$base/CHECKSUMS"
esc="${KVER//./\\.}"
grep -E "^[a-f0-9]{64}  linux-(image-unsigned|modules)-${esc}-generic_${esc}\.${BUILD}_amd64\.deb$" CHECKSUMS | sha256sum -c -
apt-get install -y ./linux-modules-*.deb ./linux-image-unsigned-*.deb
touch "$MARKER"
reboot
KSCRIPT

  # --- user-data ---
  {
    cat <<EOF
#cloud-config
users:
  - name: $AIOS_GUEST_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $pub
write_files:
  - path: /root/aios-install-kernel.sh
    owner: root:root
    permissions: '0755'
    content: |
EOF
    sed 's/^/      /' "$kscript"
    cat <<'EOF'
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
EOF
    if [[ "$mode" == full ]]; then
      local -a pkgs; mapfile -t pkgs < <(aios_guest_packages)
    else
      local -a pkgs=(openssh-server curl ca-certificates)
    fi
    printf '  - %s\n' "${pkgs[@]}"
    cat <<'EOF'
runcmd:
  - [bash, /root/aios-install-kernel.sh]
EOF
  } > user-data

  # --- meta-data ---
  cat > meta-data <<EOF_META
instance-id: $iid
local-hostname: $AIOS_GUEST_USER
EOF_META

  rm -f "$kscript"
}
