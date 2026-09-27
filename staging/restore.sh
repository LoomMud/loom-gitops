#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only
#
# staging/restore.sh (R6, OBI-42; D-P1.12). Run from an admin workstation
# or the host, with `age`, `rclone`, `docker` and `pg_restore`/`psql`
# available (the last two via a scratch postgres:17-alpine container, so
# the host itself doesn't need a Postgres client).
#
# Fetches one dated backup pair from Azure Blob, decrypts with the age
# PRIVATE key (never written anywhere but a 0600 scratch file, shredded on
# exit), restores into a throwaway `postgres:17-alpine` container (never
# the real `postgres` service) and runs a smoke query.
#
# Usage:
#   staging/restore.sh --age-key <path-to-private-key> --prefix daily --date YYYY-MM-DD
#
# Requires the same AZURE_STORAGE_ACCOUNT / AZURE_STORAGE_CONTAINER /
# AZURE_STORAGE_SAS_TOKEN as backup.sh, read from the environment (source
# /etc/loom/secrets.env yourself first, or export them by hand -- this
# script does not read secrets.env directly, so it also works from a
# workstation that doesn't have that file).
set -eu

log() { printf '%s restore: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
usage() { echo "usage: $0 --age-key <path> --prefix <daily|weekly> --date <YYYY-MM-DD>" >&2; exit 1; }

AGE_KEY=""
PREFIX=""
DATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --age-key) AGE_KEY="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$AGE_KEY" ] && [ -n "$PREFIX" ] && [ -n "$DATE" ] || usage
[ -r "$AGE_KEY" ] || { echo "cannot read age key: $AGE_KEY" >&2; exit 1; }
: "${AZURE_STORAGE_ACCOUNT:?set AZURE_STORAGE_ACCOUNT}"
: "${AZURE_STORAGE_CONTAINER:?set AZURE_STORAGE_CONTAINER}"
: "${AZURE_STORAGE_SAS_TOKEN:?set AZURE_STORAGE_SAS_TOKEN}"

for cmd in age rclone docker; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing required command: $cmd" >&2; exit 1; }
done

WORKDIR="$(mktemp -d)"
CONTAINER_NAME="loom-restore-drill-$$"
cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  # Shred the working directory (decrypted dump/tarball) and, if it was
  # copied here by mistake, any stray copy of the private key. The key
  # itself is never copied by this script; this is a belt-and-suspenders
  # cleanup of $WORKDIR only.
  find "$WORKDIR" -type f -exec shred -u {} \; 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

sas_url="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}?${AZURE_STORAGE_SAS_TOKEN}"
export RCLONE_CONFIG_LOOMBACKUP_TYPE=azureblob
export RCLONE_CONFIG_LOOMBACKUP_SAS_URL="$sas_url"
export RCLONE_CONFIG_LOOMBACKUP_NO_CHECK_CONTAINER=true

log "listing ${PREFIX}/ for ${DATE}"
dump_blob="$(rclone lsf "loombackup:/${PREFIX}/" | grep "^loom-${DATE//-/}" | sort | tail -1 || true)"
mudlib_blob="$(rclone lsf "loombackup:/${PREFIX}/" | grep "^mudlib-${DATE//-/}" | sort | tail -1 || true)"
[ -n "$dump_blob" ] || { echo "no dump found for ${DATE} under ${PREFIX}/" >&2; exit 1; }
[ -n "$mudlib_blob" ] || { echo "no mudlib tarball found for ${DATE} under ${PREFIX}/" >&2; exit 1; }

log "fetching $dump_blob and $mudlib_blob"
rclone copy "loombackup:/${PREFIX}/${dump_blob}" "$WORKDIR/"
rclone copy "loombackup:/${PREFIX}/${mudlib_blob}" "$WORKDIR/"

log "decrypting"
age -d -i "$AGE_KEY" -o "$WORKDIR/loom.dump" "$WORKDIR/$dump_blob"
age -d -i "$AGE_KEY" -o "$WORKDIR/mudlib.tar" "$WORKDIR/$mudlib_blob"

log "starting scratch postgres:17-alpine (not the real postgres service)"
docker run -d --name "$CONTAINER_NAME" \
  -e POSTGRES_USER=loom -e POSTGRES_PASSWORD=restore-drill -e POSTGRES_DB=loom \
  postgres:17-alpine >/dev/null
for _ in $(seq 1 30); do
  docker exec "$CONTAINER_NAME" pg_isready -U loom -d loom >/dev/null 2>&1 && break
  sleep 1
done

log "restoring"
docker cp "$WORKDIR/loom.dump" "$CONTAINER_NAME:/tmp/loom.dump"
docker exec -e PGPASSWORD=restore-drill "$CONTAINER_NAME" \
  pg_restore -U loom -d loom --no-owner --clean --if-exists /tmp/loom.dump

log "smoke query"
docker exec -e PGPASSWORD=restore-drill "$CONTAINER_NAME" \
  psql -U loom -d loom -c "select count(*) as accounts from accounts;" \
  || docker exec -e PGPASSWORD=restore-drill "$CONTAINER_NAME" \
     psql -U loom -d loom -c "\dt"   # fall back to listing tables if `accounts` doesn't exist in this dump

log "mudlib tarball: $(tar -tf "$WORKDIR/mudlib.tar" | wc -l) entries"
log "restore drill OK"
