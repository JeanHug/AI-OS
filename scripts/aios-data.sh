#!/usr/bin/env bash
# Encrypted cold snapshots of QEMU disks in JeanHug/ai-os-data-private.
set -Eeuo pipefail
: "${GH_TOKEN:?missing GH_TOKEN}" "${AIOS_BACKUP_KEY:?missing AIOS_BACKUP_KEY}"
repo="${AIOS_DATA_REPO:-JeanHug/ai-os-data-private}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || exit 2
command -v gpg >/dev/null; command -v git >/dev/null
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ask="$work/askpass"; cat > "$ask" <<'ASK'
#!/bin/sh
case "$1" in *sername*) printf '%s\n' x-access-token;; *) printf '%s\n' "$GH_TOKEN";; esac
ASK
chmod 700 "$ask"; export GIT_ASKPASS="$ask" GIT_TERMINAL_PROMPT=0
remote="${AIOS_DATA_REMOTE:-https://github.com/$repo.git}"
action=${1:?missing action}; disk=${2:?missing disk}; checkpoint=${3:-}
if [[ "$action" == save ]]; then
 [[ -f "$disk" && -n "$checkpoint" ]] || { echo 'Missing disk or checkpoint' >&2; exit 2; }
 # The caller MUST have shut down QEMU; a live disk is not a safe checkpoint.
 qemu-img check "$disk"
 mkdir "$work/repo"; cd "$work/repo"; git init -q; git checkout -q --orphan snapshot
 git config user.name 'AI OS backup'; git config user.email 'ai-os@users.noreply.github.com'
 printf '%s' "$AIOS_BACKUP_KEY" > "$work/pass"; chmod 600 "$work/pass"
 echo 'Compressing and encrypting the VM disk...'
 gzip -1 -c "$disk" | gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/pass" --symmetric --cipher-algo AES256 --s2k-mode 3 --compress-algo none --output "$work/snapshot.gpg"
 split -b 45m -d -a 4 "$work/snapshot.gpg" part-
 sha256sum part-* > SHA256SUMS
 printf '%s\n' "$checkpoint" > CHECKPOINT
 date -u '+%Y-%m-%dT%H:%M:%SZ' > CREATED_AT
 git add part-* SHA256SUMS CHECKPOINT CREATED_AT
 git -c core.hooksPath=/dev/null commit -qm 'Encrypted QEMU checkpoint'
 git remote add origin "$remote"
 git -c core.hooksPath=/dev/null push --force origin HEAD:refs/heads/snapshot
 echo 'Encrypted checkpoint published.'
elif [[ "$action" == restore ]]; then
 [[ -n "$checkpoint" ]] || { echo 'Missing expected checkpoint' >&2; exit 2; }
 git clone --quiet --depth 1 --single-branch --branch snapshot "$remote" "$work/repo"
 cd "$work/repo"
 [[ "$(cat CHECKPOINT)" == "$checkpoint" ]] || { echo 'Unexpected checkpoint; refusing stale restore.' >&2; exit 3; }
 sha256sum -c SHA256SUMS
 printf '%s' "$AIOS_BACKUP_KEY" > "$work/pass"; chmod 600 "$work/pass"
 cat part-* | gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/pass" --decrypt | gzip -dc > "$disk.tmp"
 qemu-img check "$disk.tmp"
 mv "$disk.tmp" "$disk"
 echo 'Encrypted checkpoint restored.'
else echo 'Usage: aios-data.sh save|restore DISK CHECKPOINT' >&2; exit 2; fi
