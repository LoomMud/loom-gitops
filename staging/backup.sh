#!/bin/sh
# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only
#
# staging/backup.sh (R6, OBI-42; D-P1.12, backend superseded to Azure Blob
# per OBI-62/R6-12). Runs inside the `backup` compose service (the LOOM_IMAGE
# runtime, debian:bookworm-slim + loom-cli; see the Dockerfile note below
# for what this script additionally needs).
#
# Nightly: pg_dump -Fc + a mudlib tarball, both age-encrypted to
# BACKUP_AGE_RECIPIENT, uploaded with rclone (azureblob backend, SAS,
# no_check_container) under daily/ and weekly/ prefixes. Never deletes
# (the SAS is rcwl, no d) -- retention is an Azure lifecycle policy
# (SETUP.md §6.3), not this script.
#
# Backups are deferred by the board (OBI-109): AZURE_STORAGE_ACCOUNT,
# AZURE_STORAGE_CONTAINER, AZURE_STORAGE_SAS_TOKEN and
# BACKUP_AGE_RECIPIENT are unset/empty until then. This is a documented
# no-op in that case, not a failure -- a reconcile or timer run must never
# fail just because backups aren't configured yet.
set -eu

log() { printf '%s backup: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if [ -z "${AZURE_STORAGE_ACCOUNT:-}" ] || [ -z "${AZURE_STORAGE_CONTAINER:-}" ] || \
   [ -z "${AZURE_STORAGE_SAS_TOKEN:-}" ] || [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
  log "backups not configured (AZURE_STORAGE_*/BACKUP_AGE_RECIPIENT unset) -- no-op, see OBI-109"
  exit 0
fi

# The BACKUP_IMAGE base (staging/images.env) is plain Alpine: install the
# three tools this script needs from Alpine's own repos. Idempotent
# (apk add is a no-op if already present); network access required.
apk add --no-cache postgresql16-client age rclone tar >/dev/null

for cmd in pg_dump age rclone tar; do
  command -v "$cmd" >/dev/null 2>&1 || { log "FATAL: missing required command: $cmd"; exit 1; }
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

stamp="$(date -u '+%Y%m%d-%H%M%S')"
dow="$(date -u '+%u')"  # 1=Monday .. 7=Sunday
prefix="daily"
[ "$dow" = "7" ] && prefix="weekly"  # one weekly snapshot, taken on the Sunday run

log "dumping postgres"
PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump -Fc -h postgres -U loom -d loom \
  -f "$WORKDIR/loom-${stamp}.dump"

log "archiving mudlib"
tar -C /mudlib -cf "$WORKDIR/mudlib-${stamp}.tar" .

log "age-encrypting"
age -r "$BACKUP_AGE_RECIPIENT" -o "$WORKDIR/loom-${stamp}.dump.age" "$WORKDIR/loom-${stamp}.dump"
age -r "$BACKUP_AGE_RECIPIENT" -o "$WORKDIR/mudlib-${stamp}.tar.age" "$WORKDIR/mudlib-${stamp}.tar"

# rclone azureblob backend via an inline remote config (SETUP.md Appendix
# A, R6-12): sas_url, no_check_container (the SAS can't create/inspect
# containers, only read/write/list within it).
sas_url="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}?${AZURE_STORAGE_SAS_TOKEN}"
export RCLONE_CONFIG_LOOMBACKUP_TYPE=azureblob
export RCLONE_CONFIG_LOOMBACKUP_SAS_URL="$sas_url"
export RCLONE_CONFIG_LOOMBACKUP_NO_CHECK_CONTAINER=true

log "uploading to ${prefix}/ (rclone copy, never sync/delete)"
rclone copy \
  "$WORKDIR/loom-${stamp}.dump.age" "loombackup:/${prefix}/" 2>&1 | sed 's/^/  /'
rclone copy \
  "$WORKDIR/mudlib-${stamp}.tar.age" "loombackup:/${prefix}/" 2>&1 | sed 's/^/  /'

log "done: ${prefix}/loom-${stamp}.dump.age, ${prefix}/mudlib-${stamp}.tar.age"
