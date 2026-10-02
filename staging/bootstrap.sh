#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only
#
# staging/bootstrap.sh (R6, OBI-42; plan §3.4.4 item 8). One-time setup on
# the Loom host, run once as root (`sudo /opt/loom-gitops/staging/bootstrap.sh`)
# after SETUP.md §1-8 are done and /etc/loom/secrets.env is filled in.
#
# What it does:
#   1. Sanity-checks prerequisites (docker, docker compose, cosign, git,
#      the `loom` service user, the /opt/loom-gitops clone ownership).
#   2. Enforces /etc/loom (root:loom 0750) and /etc/loom/secrets.env
#      (root:loom 0640) -- refuses to proceed if they're missing or
#      differently owned, rather than silently fixing a hand-edited file.
#   3. Installs the reconciler and backup systemd units + timers
#      (staging/systemd/*), all User=loom.
#   4. Runs the reconciler once, synchronously, so first-boot failures are
#      visible immediately instead of waiting up to 2 minutes for the timer.
#
# Never runs the loom/caddy/postgres containers as root: the units it
# installs carry User=loom, and this script itself never invokes
# `docker compose up` outside of triggering the reconciler.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "bootstrap.sh must run as root (sudo /opt/loom-gitops/staging/bootstrap.sh)" >&2
  exit 1
fi

REPO_DIR="/opt/loom-gitops"
SECRETS_DIR="/etc/loom"
SECRETS_FILE="$SECRETS_DIR/secrets.env"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf 'bootstrap: %s\n' "$*"; }
fatal() { printf 'bootstrap: FATAL: %s\n' "$*" >&2; exit 1; }

log "1/5 checking prerequisites"
for cmd in docker git cosign curl jq age; do
  command -v "$cmd" >/dev/null 2>&1 || fatal "missing required command: $cmd (see SETUP.md §2.3)"
done
docker compose version >/dev/null 2>&1 || fatal "docker compose v2 plugin not found"
id loom >/dev/null 2>&1 || fatal "service user 'loom' does not exist (see SETUP.md §3.3)"

[ -d "$REPO_DIR" ] || fatal "$REPO_DIR does not exist (see SETUP.md §3.5)"
repo_owner="$(stat -c '%U' "$REPO_DIR")"
[ "$repo_owner" = "loom" ] || fatal "$REPO_DIR is owned by '$repo_owner', expected 'loom' (see SETUP.md §3.5); this script does not take ownership of an existing clone"

log "2/5 checking /etc/loom and secrets.env"
if [ ! -d "$SECRETS_DIR" ]; then
  install -d -o root -g loom -m 0750 "$SECRETS_DIR"
  log "created $SECRETS_DIR (root:loom 0750)"
fi
[ -f "$SECRETS_FILE" ] || fatal "$SECRETS_FILE does not exist -- copy staging/secrets.env.example there and fill it in first (SETUP.md §9.2)"
sec_perms="$(stat -c '%U:%G %a' "$SECRETS_DIR")"
[ "$sec_perms" = "root:loom 750" ] || fatal "$SECRETS_DIR is $sec_perms, expected 'root:loom 750'"
file_perms="$(stat -c '%U:%G %a' "$SECRETS_FILE")"
[ "$file_perms" = "root:loom 640" ] || fatal "$SECRETS_FILE is $file_perms, expected 'root:loom 640'"
for required in POSTGRES_SUPERUSER_PASSWORD LOOM_OWNER_PASSWORD LOOM_APP_PASSWORD GITHUB_STATUS_TOKEN; do
  grep -q "^${required}=." "$SECRETS_FILE" || fatal "$SECRETS_FILE is missing a value for $required"
done
if ! grep -q '^GITHUB_ALERTS_TOKEN=.' "$SECRETS_FILE" 2>/dev/null; then
  log "WARNING: GITHUB_ALERTS_TOKEN not set in $SECRETS_FILE -- loom-alerts.timer will run but every check that fires will only log a warning instead of opening a GitHub issue (SETUP.md §8.1b, OBI-175)"
fi
log "secrets.env present with correct ownership/mode"

log "3/5 installing systemd units (reconciler + backup + alerts, User=loom)"
install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/loom-reconcile.service" "$SYSTEMD_DIR/"
install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/loom-reconcile.timer" "$SYSTEMD_DIR/"
install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/loom-backup.service" "$SYSTEMD_DIR/"
install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/loom-backup.timer" "$SYSTEMD_DIR/"
install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/loom-alerts.service" "$SYSTEMD_DIR/"
install -o root -g root -m 0644 "$SCRIPT_DIR/systemd/loom-alerts.timer" "$SYSTEMD_DIR/"
systemctl daemon-reload
systemctl enable --now loom-reconcile.timer
systemctl enable loom-backup.timer
systemctl enable --now loom-alerts.timer
if grep -q '^AZURE_STORAGE_ACCOUNT=.' "$SECRETS_FILE" 2>/dev/null; then
  systemctl start loom-backup.timer
  log "loom-backup.timer started (Azure Blob config present)"
else
  log "loom-backup.timer enabled but NOT started: no AZURE_STORAGE_* in secrets.env yet (OBI-109). Run 'systemctl start loom-backup.timer' once it's configured."
fi

log "4/5 running the reconciler once, synchronously"
systemctl start --no-block loom-reconcile.service
# --no-block above returns immediately; wait for the oneshot to actually finish.
for _ in $(seq 1 60); do
  state="$(systemctl show -p ActiveState --value loom-reconcile.service)"
  case "$state" in
    inactive|failed) break ;;
  esac
  sleep 2
done
result="$(systemctl show -p Result --value loom-reconcile.service)"
[ "$result" = "success" ] || fatal "first reconcile did not succeed (Result=$result); see 'journalctl -u loom-reconcile.service -n 100'"

log "5/5 done"
log "next: 'sudo docker ps' should show loom/caddy/postgres healthy and mudlib-sync exited 0"
log "next: check https://github.com/LoomMud/loom-gitops/commits/main for a green 'staging/reconcile' status"
