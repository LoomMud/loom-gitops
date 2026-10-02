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

# OBI-175 (P2-O4): a one-line status (success|failure|disabled plus a
# timestamp), written on every run. compose.yaml bind-mounts the same
# ./alerts-state directory into this service and into the `alerts`
# one-shot, so alerts.sh's check_backup can read it without a shared
# database or message bus. Best-effort: a write failure here (missing
# mount, read-only fs) must never fail the backup itself.
STATUS_FILE="${LOOM_ALERTS_BACKUP_STATUS_FILE:-/alerts-state/backup-status}"
write_status() {
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || return 0
  printf '%s %s\n' "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$STATUS_FILE" 2>/dev/null || true
}
# EXIT trap, not ERR: `/bin/sh` on the BACKUP_IMAGE base is busybox ash
# (Alpine), which doesn't support `trap ... ERR` (a bash/ksh extension) --
# an EXIT trap that inspects $? works on every POSIX shell. STATUS
# (below) is set explicitly on the two intentional `exit 0` paths
# (disabled, success) so the trap is a no-op there; it only fires
# "failure" when `set -e` kills the script somewhere unexpected.
STATUS=""
WORKDIR=""
on_exit() {
  rc=$?
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
  if [ -n "$STATUS" ]; then
    write_status "$STATUS"
  elif [ "$rc" -ne 0 ]; then
    write_status failure
  fi
}
trap on_exit EXIT

if [ -z "${AZURE_STORAGE_ACCOUNT:-}" ] || [ -z "${AZURE_STORAGE_CONTAINER:-}" ] || \
   [ -z "${AZURE_STORAGE_SAS_TOKEN:-}" ] || [ -z "${BACKUP_AGE_RECIPIENT:-}" ]; then
  log "backups not configured (AZURE_STORAGE_*/BACKUP_AGE_RECIPIENT unset) -- no-op, see OBI-109"
  STATUS=disabled
  exit 0
fi

# The BACKUP_IMAGE base (staging/images.env) is plain Alpine: install the
# three tools this script needs from Alpine's own repos. Idempotent
# (apk add is a no-op if already present); network access required.
# postgresql17-client (not postgresql16-client, OBI-164): must match
# POSTGRES_IMAGE's major version (postgres:17-alpine, staging/images.env)
# -- pg_dump refuses to dump from a newer major server version
# ("aborting because of server version mismatch"), found by the OBI-164
# CI restore drill against a real postgres:17-alpine. BACKUP_IMAGE is
# pinned to an Alpine release that carries postgresql17-client
# (Alpine's own 16/17 packaging follows Postgres's release cadence, so
# this pin moves in step with POSTGRES_IMAGE, not independently).
apk add --no-cache postgresql17-client age rclone tar >/dev/null

for cmd in pg_dump age rclone tar; do
  command -v "$cmd" >/dev/null 2>&1 || { log "FATAL: missing required command: $cmd"; exit 1; }
done

WORKDIR="$(mktemp -d)"

stamp="$(date -u '+%Y%m%d-%H%M%S')"
dow="$(date -u '+%u')"  # 1=Monday .. 7=Sunday
prefix="daily"
[ "$dow" = "7" ] && prefix="weekly"  # one weekly snapshot, taken on the Sunday run

log "dumping postgres"
# loom_owner (D-27.4, OBI-130): it owns every table/function, so a dump
# from this login captures the full schema, not just what loom_app can
# SELECT. Never the superuser (only used once, at first init, by
# postgres/init/01-create-roles.sh) and never loom_app (least privilege,
# no need for backup access).
PGPASSWORD="${LOOM_OWNER_PASSWORD}" pg_dump -Fc -h postgres -U loom_owner -d loom \
  -f "$WORKDIR/loom-${stamp}.dump"

log "archiving mudlib"
tar -C /mudlib -cf "$WORKDIR/mudlib-${stamp}.tar" .

# Character saves (OBI-172/OBI-241): mounted :ro, same as /mudlib, so a
# compromised/buggy backup.sh can never write into the live saves volume.
log "archiving saves"
tar -C /saves -cf "$WORKDIR/saves-${stamp}.tar" .

log "archiving mudlib-git"
# OBI-192/B3.5 (D-B3.6): the driver's Git history, a second copy of
# `live/<env>` on GitHub but also the fastest way to rebuild a host
# without a network dependency -- restore it with `tar -C /mudlib-git -xf
# mudlib-git-<stamp>.tar` after decrypting, same as the mudlib tarball.
tar -C /mudlib-git -cf "$WORKDIR/mudlib-git-${stamp}.tar" .

log "age-encrypting"
age -r "$BACKUP_AGE_RECIPIENT" -o "$WORKDIR/loom-${stamp}.dump.age" "$WORKDIR/loom-${stamp}.dump"
age -r "$BACKUP_AGE_RECIPIENT" -o "$WORKDIR/mudlib-${stamp}.tar.age" "$WORKDIR/mudlib-${stamp}.tar"
age -r "$BACKUP_AGE_RECIPIENT" -o "$WORKDIR/saves-${stamp}.tar.age" "$WORKDIR/saves-${stamp}.tar"
age -r "$BACKUP_AGE_RECIPIENT" -o "$WORKDIR/mudlib-git-${stamp}.tar.age" "$WORKDIR/mudlib-git-${stamp}.tar"

# rclone azureblob backend via an inline remote config (SETUP.md Appendix
# A, R6-12): sas_url, no_check_container (the SAS can't create/inspect
# containers, only read/write/list within it).
sas_url="https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}?${AZURE_STORAGE_SAS_TOKEN}"
export RCLONE_CONFIG_LOOMBACKUP_TYPE=azureblob
export RCLONE_CONFIG_LOOMBACKUP_SAS_URL="$sas_url"
export RCLONE_CONFIG_LOOMBACKUP_NO_CHECK_CONTAINER=true

log "uploading to ${prefix}/ (rclone copy, never sync/delete)"
# The container name must be repeated here even though sas_url already
# scopes the remote to it (OBI-164): rclone's azureblob backend parses
# the first path segment after `remote:` as the target container and
# rejects a container-scoped SAS URL whose container doesn't match it
# ("container name in SAS URL ... and container provided in command ...
# do not match"), so a bare "loombackup:/${prefix}/" always fails --
# found by the OBI-164 CI restore drill, a real rclone against a real
# container-scoped SAS, not by inspection.
rclone copy \
  "$WORKDIR/loom-${stamp}.dump.age" "loombackup:${AZURE_STORAGE_CONTAINER}/${prefix}/" 2>&1 | sed 's/^/  /'
rclone copy \
  "$WORKDIR/mudlib-${stamp}.tar.age" "loombackup:${AZURE_STORAGE_CONTAINER}/${prefix}/" 2>&1 | sed 's/^/  /'
rclone copy \
  "$WORKDIR/saves-${stamp}.tar.age" "loombackup:${AZURE_STORAGE_CONTAINER}/${prefix}/" 2>&1 | sed 's/^/  /'
rclone copy \
  "$WORKDIR/mudlib-git-${stamp}.tar.age" "loombackup:${AZURE_STORAGE_CONTAINER}/${prefix}/" 2>&1 | sed 's/^/  /'

log "done: ${prefix}/loom-${stamp}.dump.age, ${prefix}/mudlib-${stamp}.tar.age, ${prefix}/saves-${stamp}.tar.age, ${prefix}/mudlib-git-${stamp}.tar.age"
STATUS=success
