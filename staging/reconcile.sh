#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only
#
# staging/reconcile.sh (R6, OBI-42; D-P1.8). Run by loom-reconcile.timer
# every 2 minutes as User=loom. Idempotent: a no-op run (nothing changed
# on `main`, same images already running) makes no container changes and
# still posts a fresh `staging/reconcile` success status.
#
# Steps: fast-forward main -> cosign verify every loom digest -> docker
# compose pull && up -d --remove-orphans -> wait for healthy -> post a
# GitHub commit status on the reconciled SHA.
set -euo pipefail

REPO_DIR="${LOOM_GITOPS_DIR:-/opt/loom-gitops}"
STAGING_DIR="$REPO_DIR/staging"
SECRETS_FILE="${LOOM_SECRETS_FILE:-/etc/loom/secrets.env}"
STATUS_CONTEXT="staging/reconcile"
STATUS_REPO="LoomMud/loom-gitops"
LOOM_RELEASE_WORKFLOW="release-image.yml"
LOOM_RELEASE_REPO="LoomMud/loom"
HEALTH_WAIT_SECS="${LOOM_HEALTH_WAIT_SECS:-120}"

log() { printf '%s reconcile: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# Secrets: GITHUB_STATUS_TOKEN (required for step 5), optional GHCR_TOKEN
# (step 3 fallback), POSTGRES_SUPERUSER_PASSWORD / LOOM_OWNER_PASSWORD /
# LOOM_APP_PASSWORD / AZURE_* (read by compose itself via env_file, not by
# this script). Never echoed, never logged.
if [ -r "$SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$SECRETS_FILE"; set +a
else
  log "WARNING: $SECRETS_FILE not readable; commit-status posting will fail"
fi

sha_before=""
sha_after=""
post_status() {
  # post_status <state> <description>
  local state="$1" description="$2"
  if [ -z "${GITHUB_STATUS_TOKEN:-}" ] || [ -z "$sha_after" ]; then
    log "skip status post (state=$state): missing token or SHA"
    return 0
  fi
  curl -fsS -X POST \
    -H "Authorization: Bearer ${GITHUB_STATUS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${STATUS_REPO}/statuses/${sha_after}" \
    -d "$(printf '{"state":"%s","context":"%s","description":"%s"}' \
          "$state" "$STATUS_CONTEXT" "$description")" \
    >/dev/null || log "WARNING: failed to post commit status ($state)"
}

fail() {
  local msg="$1"
  log "FAILED: $msg"
  post_status "failure" "${msg:0:140}"
  exit 1
}

cd "$REPO_DIR"

# 1. Fast-forward main. Fails loudly (not silently) on local changes or a
# non-fast-forward history, per SETUP.md Appendix B: this clone is
# reconciler-owned, and any drift means a human edited it by hand.
log "fetching origin/main"
git fetch --quiet origin main
sha_before="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor HEAD origin/main; then
  fail "local HEAD is not an ancestor of origin/main (local changes or diverged history); see SETUP.md Appendix B"
fi
git merge --ff-only origin/main --quiet
sha_after="$(git rev-parse HEAD)"
log "at $sha_after (was $sha_before)"

# shellcheck disable=SC1091
set -a; . "$STAGING_DIR/images.env"; set +a

compose() {
  docker compose --project-directory "$STAGING_DIR" \
    --env-file "$STAGING_DIR/images.env" --env-file "$SECRETS_FILE" \
    -f "$STAGING_DIR/compose.yaml" "$@"
}

# 1.5. B3/OBI-192 (D-B3.11/D-B3.12, loom-gitops#36 review B2): compose's
# `secrets:` entries need *some* file at these host paths or `up` fails
# outright, and nothing installs the real ones automatically (they're
# gitignored, provisioned by hand once Q-P2.3 lands -- RUNBOOK.md §12).
# Install the tracked `*.example` placeholders the first time either real
# file is missing, so a fresh host's first reconcile doesn't fail on this.
# Never overwrites a file that's already there (real or previously
# installed). Owner is numeric uid 10001, not whatever uid this script's
# own `loom` user has (B3: plain non-swarm compose bind-mounts secrets
# as-is, so the container's `loom` user, uid 10001, can only read a file
# actually owned by that uid) -- `chown` via a throwaway root container on
# the already-pulled $GIT_SYNC_IMAGE, the same trick mudlib-sync itself
# uses to hand the seeded mudlib tree to that uid.
install_placeholder_secret() {
  local name="$1" real example
  real="$STAGING_DIR/secrets/$name"
  example="$STAGING_DIR/secrets/${name}.example"
  local uid="${LOOM_UID:-10001}"
  if [ ! -f "$real" ]; then
    install -m 0400 "$example" "$real"
    log "installed placeholder secret $name from ${name}.example (real App not yet provisioned, Q-P2.3; see RUNBOOK.md section 12)"
  fi
  # Ownership is checked on *every* run, not only right after install, so
  # a run that installed the file but died before the chown self-heals
  # (OBI-192 follow-up: the first rollout did exactly that). stat only
  # needs search permission on the directory, not read on the file.
  # `--entrypoint`: alpine/git's ENTRYPOINT is `git`, so without it
  # `docker run <img> sh -c ...` runs `git sh -c ...` and fails.
  [ "$(stat -c %u "$real")" = "$uid" ] && return 0
  docker run --rm --entrypoint chown -v "$STAGING_DIR/secrets:/s" \
    "$GIT_SYNC_IMAGE" "$uid:$uid" "/s/$name" \
    || fail "could not chown secret $name to uid $uid"
  log "chowned secret $name to uid $uid"
}
install_placeholder_secret warp_app.pem
install_placeholder_secret warp_webhook

# GHCR login fallback (SETUP.md §8.2/R6-7): only if the package is still
# private and a classic PAT was provisioned. A no-op, idempotent step.
if [ -n "${GHCR_TOKEN:-}" ]; then
  echo "$GHCR_TOKEN" | docker login ghcr.io -u loom --password-stdin >/dev/null
fi

# 2. cosign verify every loom digest against the release-image.yml OIDC
# identity. Refuses to deploy (exit before touching compose) on failure.
log "cosign verify $LOOM_IMAGE"
cosign verify "$LOOM_IMAGE" \
  --certificate-identity-regexp "^https://github.com/${LOOM_RELEASE_REPO}/\.github/workflows/${LOOM_RELEASE_WORKFLOW}@refs/tags/.*$" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  >/tmp/loom-cosign-verify.log 2>&1 \
  || fail "cosign verify failed for $LOOM_IMAGE (see /tmp/loom-cosign-verify.log on the host)"
log "cosign verify OK"

# 3. Pull + recreate what changed. `--remove-orphans` cleans up services
# removed from compose.yaml in a past PR. This is the idempotency point:
# if nothing changed (same digests, same compose.yaml, same images.env),
# `up -d` recreates nothing.
log "docker compose pull"
compose pull --quiet || fail "docker compose pull failed"

log "docker compose up -d --remove-orphans"
compose up -d --remove-orphans || fail "docker compose up failed"

# 4. Wait for healthy (loom, caddy, postgres all report "healthy"; the
# one-shot mudlib-sync is judged by exit code, not a healthcheck).
log "waiting up to ${HEALTH_WAIT_SECS}s for services to become healthy"
deadline=$(( $(date +%s) + HEALTH_WAIT_SECS ))
while true; do
  unhealthy=""
  for svc in loom caddy postgres; do
    cid="$(compose ps -q "$svc" || true)"
    [ -n "$cid" ] || { unhealthy="$unhealthy $svc(missing)"; continue; }
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
    [ "$status" = "healthy" ] || [ "$status" = "running" ] && continue
    unhealthy="$unhealthy $svc($status)"
  done
  if [ -z "$unhealthy" ]; then
    log "all services healthy"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    fail "timed out waiting for:$unhealthy"
  fi
  sleep 3
done

mudlib_sync_cid="$(compose ps -a -q mudlib-sync || true)"
if [ -z "$mudlib_sync_cid" ]; then
  fail "mudlib-sync container not found"
fi
mudlib_sync_exit="$(docker inspect --format '{{.State.ExitCode}}' "$mudlib_sync_cid")"
if [ "$mudlib_sync_exit" != "0" ]; then
  fail "mudlib-sync exited $mudlib_sync_exit"
fi

# One-shot saves-init (OBI-172/OBI-240): judged by exit code the same way
# as mudlib-sync, so a chown/chmod failure on the saves volume is
# attributed clearly in the reconcile log instead of surfacing later as a
# mysterious loom write failure.
saves_init_cid="$(compose ps -a -q saves-init || true)"
if [ -z "$saves_init_cid" ]; then
  fail "saves-init container not found"
fi
saves_init_exit="$(docker inspect --format '{{.State.ExitCode}}' "$saves_init_cid")"
if [ "$saves_init_exit" != "0" ]; then
  fail "saves-init exited $saves_init_exit"
fi

# 5. Post a GitHub commit status on the reconciled loom-gitops SHA.
if [ "$sha_before" = "$sha_after" ]; then
  post_status "success" "no-op reconcile at $sha_after"
else
  post_status "success" "deployed $sha_after (loom @ ${LOOM_IMAGE##*@sha256:})"
fi
log "success"
