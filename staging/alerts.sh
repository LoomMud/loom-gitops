#!/bin/sh
# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only
#
# staging/alerts.sh (OBI-175/P2-O4; retro R3 -- a 68-minute staging outage
# on 09-28 went unnoticed because the only failure signal was a GitHub
# commit status nobody was watching live). Runs inside the `alerts`
# compose service (profile "alerts"; see compose.yaml), on the same
# compose network as `loom`, so it can resolve the `loom` service name.
# Invoked every minute by loom-alerts.timer (`docker compose run --rm
# alerts`).
#
# Checks four conditions and delivers each one to the channel staff
# actually watch: a GitHub issue, labeled "alert", in LoomMud/loom-gitops
# (opened on the transition into "firing", commented on while it stays
# firing -- throttled -- and closed on recovery). That's the channel this
# team already watches (PRs/issues drive every deploy and every CTO
# review), not a new chat tool nobody has wired up yet.
#
#   1. reconcile/deploy failure: the `staging/reconcile` commit status on
#      origin/main (posted by reconcile.sh) is "failure"/"error".
#   2. /readyz down for >= LOOM_ALERTS_READYZ_THRESHOLD_SECS (default 120s):
#      curl http://loom:8080/readyz on the compose network.
#   3. backup job failure: backup.sh writes a one-line status (first
#      field: success|failure|disabled) to $STATE_DIR/backup-status on
#      every run (compose.yaml bind-mounts the same ./alerts-state
#      directory into both services).
#   4. runtime-error rate above a threshold: reads the counter
#      LOOM_ALERTS_ERROR_METRIC (default loom_runtime_errors_total,
#      OBI-169/P2-B4) off http://loom:8080/metrics. Until OBI-169 lands
#      and exports that counter, this check logs a skip and does nothing
#      -- there is nothing to alert on yet. If OBI-169 names the counter
#      differently, override LOOM_ALERTS_ERROR_METRIC rather than editing
#      this script.
#
# Dry run: set LOOM_ALERTS_DRY_RUN=1 to log what would fire/resolve
# without calling the GitHub API at all (no token needed) -- used by the
# CI job below and for local testing of the detection logic.
set -eu

STATE_DIR="${LOOM_ALERTS_STATE_DIR:-/alerts-state}"
REPO="${LOOM_ALERTS_REPO:-LoomMud/loom-gitops}"
LOOM_HTTP_BASE="${LOOM_ALERTS_LOOM_HTTP_BASE:-http://loom:8080}"
READYZ_THRESHOLD_SECS="${LOOM_ALERTS_READYZ_THRESHOLD_SECS:-120}"
RECONCILE_REPO="${LOOM_ALERTS_RECONCILE_REPO:-LoomMud/loom-gitops}"
RECONCILE_SHA="${LOOM_ALERTS_RECONCILE_SHA:-}"
BACKUP_STATUS_FILE="${LOOM_ALERTS_BACKUP_STATUS_FILE:-$STATE_DIR/backup-status}"
ERROR_METRIC="${LOOM_ALERTS_ERROR_METRIC:-loom_runtime_errors_total}"
ERROR_RATE_THRESHOLD="${LOOM_ALERTS_ERROR_RATE_THRESHOLD:-1}" # errors/sec, placeholder until OBI-169 sets a real SLO
COMMENT_THROTTLE_SECS="${LOOM_ALERTS_COMMENT_THROTTLE_SECS:-900}"
DRY_RUN="${LOOM_ALERTS_DRY_RUN:-0}"
GH_TOKEN="${GITHUB_ALERTS_TOKEN:-}"

# The BACKUP_IMAGE base (staging/images.env) is plain Alpine, same as
# backup.sh: install the two tools this script needs from Alpine's own
# repos. Idempotent; network access required (same outbound path the
# `backup` and `mudlib-sync` services already use). Guarded by `apk`
# existing at all, so this script also runs unmodified on a plain Linux
# box (CI's dry-run job, or a developer's workstation) that already has
# curl/jq from its own package manager.
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache curl jq >/dev/null
fi
for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "FATAL: missing required command: $cmd" >&2; exit 1; }
done

mkdir -p "$STATE_DIR"

log() { printf '%s alerts: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

gh_get() {
  # gh_get <url> -- unauthenticated is fine for public-repo reads
  # (commit + statuses); keeps the one token we do carry scoped to
  # Issues only (least privilege).
  curl -fsS -H "Accept: application/vnd.github+json" "$@"
}

gh_api() {
  # gh_api <method> <url> [curl-args...] -- authenticated (Issues: Read
  # and write; see SETUP.md §8.1b).
  [ -n "$GH_TOKEN" ] || { log "WARNING: GITHUB_ALERTS_TOKEN not set, cannot call GitHub"; return 1; }
  curl -fsS -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

json_str() {
  # json_str <raw> -- minimal JSON string escaping (backslash, quote,
  # newline) without a jq/python dependency beyond what's already apk-ed.
  printf '%s' "$1" | jq -Rs .
}

notify_fire() {
  # notify_fire <key> <title> <body>
  key="$1"; title="$2"; body="$3"
  marker="$STATE_DIR/$key.open-issue"
  last_comment="$STATE_DIR/$key.last-comment"
  now="$(date +%s)"

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would fire '$key': $title"
    echo "dry-run-issue" > "$marker"
    return 0
  fi

  if [ -f "$marker" ]; then
    number="$(cat "$marker")"
    since=0
    [ -f "$last_comment" ] && since="$(cat "$last_comment")"
    if [ "$((now - since))" -ge "$COMMENT_THROTTLE_SECS" ]; then
      gh_api -X POST "https://api.github.com/repos/${REPO}/issues/${number}/comments" \
        -d "{\"body\": $(json_str "still firing: $body")}" >/dev/null \
        && echo "$now" > "$last_comment" \
        || log "WARNING: failed to post a still-firing comment on #$number"
    fi
    log "alert '$key' still firing (issue #$number)"
    return 0
  fi

  resp="$(gh_api -X POST "https://api.github.com/repos/${REPO}/issues" \
    -d "{\"title\": $(json_str "$title"), \"body\": $(json_str "$body"), \"labels\": [\"alert\", \"bug\"]}")" \
    || { log "WARNING: failed to open alert issue for '$key'"; return 0; }
  number="$(printf '%s' "$resp" | jq -r '.number // empty')"
  if [ -z "$number" ]; then
    log "WARNING: opening alert issue for '$key' did not return a number: $resp"
    return 0
  fi
  echo "$number" > "$marker"
  echo "$now" > "$last_comment"
  log "alert '$key' fired: opened issue #$number"
}

notify_resolve() {
  key="$1"; note="$2"
  marker="$STATE_DIR/$key.open-issue"
  [ -f "$marker" ] || return 0

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would resolve '$key': $note"
    rm -f "$marker" "$STATE_DIR/$key.last-comment"
    return 0
  fi

  number="$(cat "$marker")"
  gh_api -X POST "https://api.github.com/repos/${REPO}/issues/${number}/comments" \
    -d "{\"body\": $(json_str "resolved: $note")}" >/dev/null || true
  gh_api -X PATCH "https://api.github.com/repos/${REPO}/issues/${number}" -d '{"state":"closed"}' >/dev/null || true
  rm -f "$marker" "$STATE_DIR/$key.last-comment"
  log "alert '$key' resolved (closed issue #$number)"
}

check_reconcile() {
  sha="$RECONCILE_SHA"
  if [ -z "$sha" ]; then
    sha="$(gh_get "https://api.github.com/repos/${RECONCILE_REPO}/commits/main" 2>/dev/null | jq -r '.sha // empty')"
  fi
  if [ -z "$sha" ]; then
    log "WARNING: could not resolve origin/main sha for ${RECONCILE_REPO}; skipping reconcile check"
    return 0
  fi
  statuses="$(gh_get "https://api.github.com/repos/${RECONCILE_REPO}/commits/${sha}/statuses" 2>/dev/null || echo '[]')"
  state="$(printf '%s' "$statuses" | jq -r '[.[] | select(.context=="staging/reconcile")][0].state // "unknown"')"
  desc="$(printf '%s' "$statuses" | jq -r '[.[] | select(.context=="staging/reconcile")][0].description // ""')"
  case "$state" in
    failure|error)
      notify_fire reconcile "[ALERT] staging/reconcile is failing" \
        "Latest staging/reconcile commit status is '$state' at ${sha}: ${desc}. See journalctl -u loom-reconcile.service on the host, and RUNBOOK.md §7 (rollback)."
      ;;
    success)
      notify_resolve reconcile "staging/reconcile is 'success' again at ${sha}"
      ;;
    *)
      log "reconcile status is '$state' at ${sha}; no action"
      ;;
  esac
}

check_readyz() {
  marker="$STATE_DIR/readyz-down-since"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${LOOM_HTTP_BASE}/readyz" 2>/dev/null)" || true
  [ -n "$code" ] || code=000
  if [ "$code" = "200" ]; then
    rm -f "$marker"
    notify_resolve readyz "${LOOM_HTTP_BASE}/readyz is 200 again"
    return 0
  fi
  now="$(date +%s)"
  if [ ! -f "$marker" ]; then
    echo "$now" > "$marker"
    log "/readyz down (HTTP $code), starting timer"
    return 0
  fi
  since="$(cat "$marker")"
  down_for=$((now - since))
  if [ "$down_for" -ge "$READYZ_THRESHOLD_SECS" ]; then
    notify_fire readyz "[ALERT] staging /readyz has been down for ${down_for}s" \
      "Last check against ${LOOM_HTTP_BASE}/readyz returned HTTP ${code}; down since epoch ${since} (threshold ${READYZ_THRESHOLD_SECS}s)."
  else
    log "/readyz down for ${down_for}s (threshold ${READYZ_THRESHOLD_SECS}s), not firing yet"
  fi
}

check_backup() {
  if [ ! -f "$BACKUP_STATUS_FILE" ]; then
    log "no backup status file yet at $BACKUP_STATUS_FILE; skipping (first run not completed, or backups disabled per OBI-109)"
    return 0
  fi
  status="$(awk '{print $1}' "$BACKUP_STATUS_FILE")"
  ts="$(awk '{print $2}' "$BACKUP_STATUS_FILE")"
  case "$status" in
    failure)
      notify_fire backup "[ALERT] staging backup job failed" \
        "backup.sh reported failure at ${ts}. See journalctl -u loom-backup.service on the host."
      ;;
    success|disabled)
      notify_resolve backup "backup.sh reported '${status}' at ${ts}"
      ;;
    *)
      log "backup status file has unrecognised status '$status'; no action"
      ;;
  esac
}

check_error_rate() {
  metrics="$(curl -s --max-time 5 "${LOOM_HTTP_BASE}/metrics" 2>/dev/null || true)"
  line="$(printf '%s\n' "$metrics" | grep "^${ERROR_METRIC}" | head -1 || true)"
  if [ -z "$line" ]; then
    log "metric '${ERROR_METRIC}' not present yet (OBI-169/P2-B4 not landed); skipping error-rate check"
    return 0
  fi
  value="$(printf '%s' "$line" | awk '{print $2}')"
  prev_file="$STATE_DIR/error-rate-prev"
  now="$(date +%s)"
  if [ ! -f "$prev_file" ]; then
    echo "$now $value" > "$prev_file"
    log "error-rate: first sample ($value at $now), no rate yet"
    return 0
  fi
  prev_ts="$(awk '{print $1}' "$prev_file")"
  prev_value="$(awk '{print $2}' "$prev_file")"
  echo "$now $value" > "$prev_file"
  dt=$((now - prev_ts))
  [ "$dt" -gt 0 ] || return 0
  # Counters only go up; a drop means a restart, not a real rate -- skip
  # rather than report a bogus negative rate.
  dv=$(awk -v a="$value" -v b="$prev_value" 'BEGIN { d = a - b; if (d < 0) d = -1; print d }')
  if [ "$dv" = "-1" ]; then
    log "error-rate: counter went backwards (restart?), skipping this sample"
    return 0
  fi
  rate="$(awk -v d="$dv" -v t="$dt" 'BEGIN { printf "%.4f", d / t }')"
  over="$(awk -v r="$rate" -v th="$ERROR_RATE_THRESHOLD" 'BEGIN { print (r > th) ? 1 : 0 }')"
  if [ "$over" = "1" ]; then
    notify_fire error_rate "[ALERT] staging runtime-error rate is ${rate}/s (threshold ${ERROR_RATE_THRESHOLD}/s)" \
      "Metric ${ERROR_METRIC} increased by ${dv} over ${dt}s (rate ${rate}/s), above the ${ERROR_RATE_THRESHOLD}/s threshold. See the errors command / /api/v1/errors (OBI-169) for detail."
  else
    notify_resolve error_rate "runtime-error rate back to ${rate}/s"
  fi
}

log "starting pass (repo=$REPO, dry_run=$DRY_RUN)"
check_reconcile
check_readyz
check_backup
check_error_rate
log "pass complete"
