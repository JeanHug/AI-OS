#!/usr/bin/env bash
# aios-data.sh — checkpoints chiffrés du disque QEMU dans JeanHug/ai-os-data-private.
#
# Sauvegarde : qemu-img check → gzip -1 → GPG AES256 (s2k-mode 3) → fragments
# de 45 Mo → SHA256 + CHECKPOINT + CREATED_AT → publication sur la branche
# orpheline « snapshot ».
# Restauration : vérification CHECKPOINT + SHA256, puis déchiffrement.
#
# Génération unique : la branche est réécrite à chaque cycle (pas de version
# antérieure). Le secret AIOS_BACKUP_KEY est irrécupérable : s'il est perdu,
# les checkpoints sont indéchiffrables.
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"
aios_require_env GH_TOKEN AIOS_BACKUP_KEY

[[ "$AIOS_DATA_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || aios_die "AIOS_DATA_REPO invalide"
command -v gpg >/dev/null || aios_die 'gpg requis'
command -v git >/dev/null || aios_die 'git requis'

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ask="$work/askpass"; cat > "$ask" <<'ASK'
#!/bin/sh
case "$1" in *sername*) printf '%s\n' x-access-token;; *) printf '%s\n' "$GH_TOKEN";; esac
ASK
chmod 700 "$ask"; export GIT_ASKPASS="$ask" GIT_TERMINAL_PROMPT=0
remote="${AIOS_DATA_REMOTE:-https://github.com/$AIOS_DATA_REPO.git}"
action=${1:?missing action}; disk=${2:?missing disk}; checkpoint=${3:-}

if [[ "$action" == save ]]; then
  [[ -f "$disk" && -n "$checkpoint" ]] || aios_die 'Disque ou checkpoint manquant'
  # L'appelant DOIT avoir arrêté QEMU : un disque vivant n'est pas un checkpoint.
  qemu-img check "$disk"
  # Garde-fou disque : la sauvegarde triple l'empreinte (chiffré + fragments +
  # objets git). Sans marge, la publication meurt au milieu avec "No space left".
  free_kb=$(df -PK "$work" | awk 'NR==2 {print $4}')
  if (( free_kb < AIOS_MIN_FREE_KB )); then
    aios_die "Espace disque insuffisant : ${free_kb} Ko libres, ${AIOS_MIN_FREE_KB} Ko requis."
  fi
  mkdir "$work/repo"; cd "$work/repo"; git init -q; git checkout -q --orphan "$AIOS_DATA_BRANCH"
  git config user.name 'AI OS backup'; git config user.email 'ai-os@users.noreply.github.com'
  printf '%s' "$AIOS_BACKUP_KEY" > "$work/pass"; chmod 600 "$work/pass"
  aios_log 'Compression et chiffrement du disque...'
  gzip -1 -c "$disk" | gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/pass" --symmetric --cipher-algo AES256 --s2k-mode 3 --compress-algo none --output "$work/snapshot.gpg"
  split -b 45m -d -a 4 "$work/snapshot.gpg" part-
  sha256sum part-* > SHA256SUMS
  printf '%s\n' "$checkpoint" > CHECKPOINT
  date -u '+%Y-%m-%dT%H:%M:%SZ' > CREATED_AT
  git add part-* SHA256SUMS CHECKPOINT CREATED_AT
  git -c core.hooksPath=/dev/null commit -qm 'Encrypted QEMU checkpoint'
  git remote add origin "$remote"
  git -c core.hooksPath=/dev/null push --force origin "HEAD:refs/heads/$AIOS_DATA_BRANCH"
  aios_log "Checkpoint $checkpoint publié ($(du -ch part-* | tail -1 | cut -f1), $(ls part-* | wc -l) fragments)."
elif [[ "$action" == restore ]]; then
  [[ -n "$checkpoint" ]] || aios_die 'Checkpoint attendu manquant'
  git clone --quiet --depth 1 --single-branch --branch "$AIOS_DATA_BRANCH" "$remote" "$work/repo"
  cd "$work/repo"
  [[ "$(cat CHECKPOINT)" == "$checkpoint" ]] || { echo "Checkpoint inattendu : restauration refusée." >&2; exit 3; }
  sha256sum -c SHA256SUMS
  printf '%s' "$AIOS_BACKUP_KEY" > "$work/pass"; chmod 600 "$work/pass"
  cat part-* | gpg --batch --yes --pinentry-mode loopback --passphrase-file "$work/pass" --decrypt | gzip -dc > "$disk.tmp"
  qemu-img check "$disk.tmp"
  mv "$disk.tmp" "$disk"
  aios_log "Checkpoint $checkpoint restauré."
else
  echo 'Usage: aios-data.sh save|restore DISK CHECKPOINT' >&2; exit 2
fi
