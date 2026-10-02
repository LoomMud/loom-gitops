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
#   staging/restore.sh --age-key <path-to-private-key> --prefix daily --date YYYY-MM-DD [--saves-volume <name>]
#
# --saves-volume (OBI-172/OBI-241, default: a disposable scratch volume
# removed on exit) names the docker volume the saves tarball is restored
# into. Pass it explicitly to target a real volume -- RUNBOOK.md §5 uses
# `loom_saves`, the actual named volume `compose.yaml`'s `loom` service
# mounts at /saves (project-prefixed by compose, `compose.yaml`'s
# top-level `name: loom`). Without the flag, this script never touches a
# persistent volume, so a routine drill run (or CI) can't collide with or
# corrupt a real one by accident.
#
# Requires the same AZURE_STORAGE_ACCOUNT / AZURE_STORAGE_CONTAINER /
# AZURE_STORAGE_SAS_TOKEN as backup.sh, read from the environment (source
# /etc/loom/secrets.env yourself first, or export them by hand -- this
# script does not read secrets.env directly, so it also works from a
# workstation that doesn't have that file).
set -eu

log() { printf '%s restore: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
usage() { echo "usage: $0 --age-key <path> --prefix <daily|weekly> --date <YYYY-MM-DD> [--saves-volume <name>]" >&2; exit 1; }

AGE_KEY=""
PREFIX=""
DATE=""
SAVES_VOLUME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --age-key) AGE_KEY="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --date) DATE="$2"; shift 2 ;;
    --saves-volume) SAVES_VOLUME="$2"; shift 2 ;;
    *) usage ;;
  esac
done
# An explicit --saves-volume is kept after the script exits (it's the
# real deploy's volume, or a drill's own disposable name it manages
# itself); the default is this script's own scratch volume, and it's the
# only one this script ever deletes.
SAVES_VOLUME_IS_SCRATCH=0
if [ -z "$SAVES_VOLUME" ]; then
  SAVES_VOLUME="loom-restore-scratch-saves-$$"
  SAVES_VOLUME_IS_SCRATCH=1
fi
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
  if [ "$SAVES_VOLUME_IS_SCRATCH" = "1" ]; then
    docker volume rm "$SAVES_VOLUME" >/dev/null 2>&1 || true
  fi
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
# The container name must be repeated here even though sas_url already
# scopes the remote to it (OBI-164, same issue/fix as backup.sh): rclone's
# azureblob backend rejects a bare "loombackup:/${PREFIX}/" against a
# container-scoped SAS URL ("container name in SAS URL ... and container
# provided in command ... do not match").
dump_blob="$(rclone lsf "loombackup:${AZURE_STORAGE_CONTAINER}/${PREFIX}/" | grep "^loom-${DATE//-/}" | sort | tail -1 || true)"
mudlib_blob="$(rclone lsf "loombackup:${AZURE_STORAGE_CONTAINER}/${PREFIX}/" | grep "^mudlib-${DATE//-/}" | sort | tail -1 || true)"
saves_blob="$(rclone lsf "loombackup:${AZURE_STORAGE_CONTAINER}/${PREFIX}/" | grep "^saves-${DATE//-/}" | sort | tail -1 || true)"
[ -n "$dump_blob" ] || { echo "no dump found for ${DATE} under ${PREFIX}/" >&2; exit 1; }
[ -n "$mudlib_blob" ] || { echo "no mudlib tarball found for ${DATE} under ${PREFIX}/" >&2; exit 1; }
[ -n "$saves_blob" ] || { echo "no saves tarball found for ${DATE} under ${PREFIX}/" >&2; exit 1; }

log "fetching $dump_blob, $mudlib_blob and $saves_blob"
rclone copy "loombackup:${AZURE_STORAGE_CONTAINER}/${PREFIX}/${dump_blob}" "$WORKDIR/"
rclone copy "loombackup:${AZURE_STORAGE_CONTAINER}/${PREFIX}/${mudlib_blob}" "$WORKDIR/"
rclone copy "loombackup:${AZURE_STORAGE_CONTAINER}/${PREFIX}/${saves_blob}" "$WORKDIR/"

log "decrypting"
age -d -i "$AGE_KEY" -o "$WORKDIR/loom.dump" "$WORKDIR/$dump_blob"
age -d -i "$AGE_KEY" -o "$WORKDIR/mudlib.tar" "$WORKDIR/$mudlib_blob"
age -d -i "$AGE_KEY" -o "$WORKDIR/saves.tar" "$WORKDIR/$saves_blob"

log "starting scratch postgres:17-alpine (not the real postgres service)"
docker run -d --name "$CONTAINER_NAME" \
  -e POSTGRES_USER=loom -e POSTGRES_PASSWORD=restore-drill -e POSTGRES_DB=loom \
  postgres:17-alpine >/dev/null
# OBI-164: this used to be a bare pg_isready loop with no assertion after
# it, AND pg_isready alone is the wrong check for a brand-new postgres
# container: on first run the official image starts a *temporary*
# instance to run initdb/init scripts, stops it, then starts the real
# long-running one ("PostgreSQL init process complete; ready for start
# up." in its logs marks that handoff) -- pg_isready can report success
# against the temporary instance an instant before it's stopped, so a
# single success is not enough. Found by the OBI-164 CI restore drill:
# pg_isready succeeded, then pg_restore immediately failed with
# "connection ... failed: No such file or directory" against the gap
# where the temporary instance had already stopped and the real one
# hadn't opened its socket yet.
ready=""
for _ in $(seq 1 60); do
  if docker logs "$CONTAINER_NAME" 2>&1 | grep -q 'PostgreSQL init process complete; ready for start up' \
      && docker exec "$CONTAINER_NAME" pg_isready -U loom -d loom >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "scratch postgres never became ready" >&2
  docker logs "$CONTAINER_NAME" 2>&1 | tail -50 >&2
  exit 1
fi

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

# Unlike the dump (restored into a throwaway scratch container above),
# the saves tarball goes straight into the real named docker volume
# (OBI-172/OBI-241): there's no equivalent "throwaway loom" to restore
# into, and files-on-a-volume restore is safe to do directly once nothing
# is using it (the volume itself is created by docker if missing). A
# helper alpine container does the extract + chown, the same uid/mode
# `saves-init` in compose.yaml uses.
log "checking docker volume '${SAVES_VOLUME}' isn't in use"
# docker ps --filter volume=<name> only matches *running* containers, so
# a volume with no containers (new, or everything already stopped --
# RUNBOOK.md §5's `stop loom` before this runs) always passes. This is a
# backstop against running this against a live `loom`, not a substitute
# for actually stopping it first.
in_use="$(docker ps -q --filter "volume=${SAVES_VOLUME}" || true)"
if [ -n "$in_use" ]; then
  echo "refusing to restore: docker volume '${SAVES_VOLUME}' is mounted by a running container ($in_use) -- stop it first" >&2
  exit 1
fi
log "restoring saves tarball into docker volume '${SAVES_VOLUME}'"
docker volume create "$SAVES_VOLUME" >/dev/null
# Best-effort safety net, not a substitute for a real backup: if the
# target volume already has anything in it, snapshot it next to $PWD
# (NOT inside $WORKDIR -- that gets shredded on exit, which would defeat
# the point) before overwriting, so an operator who restores the wrong
# date can recover what was there a moment ago instead of losing it
# outright.
if [ "$(docker run --rm -v "${SAVES_VOLUME}:/saves:ro" alpine:3.20 find /saves -mindepth 1 -print -quit)" != "" ]; then
  pre_restore_tar="./saves-pre-restore-$(date -u '+%Y%m%dT%H%M%SZ').tar"
  log "snapshotting existing contents of '${SAVES_VOLUME}' to ${pre_restore_tar} before overwriting"
  docker run --rm -v "${SAVES_VOLUME}:/saves:ro" -v "$PWD:/backup" \
    alpine:3.20 tar -C /saves -cf "/backup/${pre_restore_tar#./}" .
fi
docker run --rm \
  -v "${SAVES_VOLUME}:/saves" \
  -v "$WORKDIR/saves.tar:/tmp/saves.tar:ro" \
  alpine:3.20 /bin/sh -c '
    set -eu
    tar -C /saves -xf /tmp/saves.tar
    chown -R 10001:10001 /saves
    chmod 0700 /saves
  '
saves_entries="$(docker run --rm -v "${SAVES_VOLUME}:/saves:ro" alpine:3.20 find /saves -type f | wc -l)"
log "saves volume '${SAVES_VOLUME}': ${saves_entries} files restored, owned by 10001"

log "restore drill OK"
