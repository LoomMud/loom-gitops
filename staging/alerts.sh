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
ERROR_RATE_THRESHOLD="${LOOM_ALERTS_ERROR_RATE_THRESHOLD:-0.05}" # errors/sec; 3/min averaged over a pass (Aragorn, OBI-280)
COMMENT_THROTTLE_SECS="${LOOM_ALERTS_COMMENT_THROTTLE_SECS:-900}"
DRY_RUN="${LOOM_ALERTS_DRY_RUN:-0}"
GH_TOKEN="${GITHUB_ALERTS_TOKEN:-}"

# ALERTS_IMAGE (staging/images.env) already bakes curl+jq in (OBI-175/P2-O4
# follow-up, CTO review on PR #34 item 2) -- unlike backup.sh's once-a-night
# apk add, this runs every minute, so a per-pass Alpine CDN/DNS blip must
# never be able to silence all four checks under `set -e`. Only fall back
# to installing them here (best-effort, never fatal) for a plain Linux box
# that doesn't carry them yet: a developer workstation, CI's dry-run job,
# or ALERTS_IMAGE before its first bump. A failed install here degrades
# gracefully (checks that don't need curl/jq, i.e. backup, still run;
# reconcile/readyz/error_rate log a one-line skip instead of aborting the
# whole pass) rather than exiting nonzero.
HAVE_CURL=0; HAVE_JQ=0
command -v curl >/dev/null 2>&1 && HAVE_CURL=1
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
if [ "$HAVE_CURL" -eq 0 ] || [ "$HAVE_JQ" -eq 0 ]; then
  if command -v apk >/dev/null 2>&1; then
    if apk add --no-cache curl jq >/dev/null 2>&1; then
      HAVE_CURL=1; HAVE_JQ=1
    else
      echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') alerts: WARNING: apk add curl jq failed (network blip?); this pass will skip whatever checks need them" >&2
    fi
  fi
fi

mkdir -p "$STATE_DIR"

log() { printf '%s alerts: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

gh_get() {
  # gh_get <url> -- authenticated with GITHUB_ALERTS_TOKEN (Commit
  # statuses: Read-only; SETUP.md §8.1b). Unauthenticated reads are rate
  # limited to 60/h per IP; at 1 pass/min, check_reconcile's 2 calls alone
  # are 120/h, which starts silently skipping checks after ~30 min (CTO
  # review on PR #34 item 1). Authenticated gets 5000/h, which this never
  # gets close to. Falls back to unauthenticated only if GITHUB_ALERTS_TOKEN
  # isn't set yet (still works, just rate-limited the same old way).
  if [ -n "$GH_TOKEN" ]; then
    curl -fsS -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$@"
  else
    curl -fsS -H "Accept: application/vnd.github+json" "$@"
  fi
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
  if [ "$HAVE_CURL" -eq 0 ] || [ "$HAVE_JQ" -eq 0 ]; then
    log "reconcile check: curl/jq unavailable this pass; skipping"
    return 0
  fi
  # Combined-status endpoint (CTO review on PR #34 item 1): one GitHub
  # call instead of two (resolve main's sha, then list its statuses) --
  # it accepts a branch name directly as the ref and returns both the
  # resolved sha and every context's status together. Authenticated via
  # gh_get (GITHUB_ALERTS_TOKEN, Commit statuses: Read-only) to stay well
  # under the rate limit even on the override path below.
  ref="${RECONCILE_SHA:-main}"
  combined="$(gh_get "https://api.github.com/repos/${RECONCILE_REPO}/commits/${ref}/status" 2>/dev/null || echo '{}')"
  sha="$(printf '%s' "$combined" | jq -r '.sha // empty')"
  if [ -z "$sha" ]; then
    log "WARNING: could not resolve combined status for ${RECONCILE_REPO}@${ref}; skipping reconcile check"
    return 0
  fi
  state="$(printf '%s' "$combined" | jq -r '[.statuses[] | select(.context=="staging/reconcile")][0].state // "unknown"')"
  desc="$(printf '%s' "$combined" | jq -r '[.statuses[] | select(.context=="staging/reconcile")][0].description // ""')"
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
  if [ "$HAVE_CURL" -eq 0 ]; then
    log "readyz check: curl unavailable this pass; skipping"
    return 0
  fi
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
  # Staleness (CTO review on PR #34 item 3): backup.sh runs nightly, so a
  # good status should never be more than ~24h old. A dead loom-backup.timer
  # or a SIGKILLed backup.sh (no EXIT trap chance to write anything) leaves
  # the file's last status as 'success' forever -- without this, that reads
  # as healthy indefinitely. 26h (not 24h) gives slack for a run that
  # starts a bit late or runs long, same margin as the OBI-164 restore
  # drill's timing comments. file mtime, not the timestamp field, in case
  # clocks ever drift between the write and this check.
  age="$(( $(date +%s) - $(stat -c %Y "$BACKUP_STATUS_FILE" 2>/dev/null || stat -f %m "$BACKUP_STATUS_FILE") ))"
  stale_threshold=$((26 * 3600))
  if [ "$age" -ge "$stale_threshold" ]; then
    notify_fire backup "[ALERT] staging backup status is stale (${age}s old)" \
      "backup-status last written at ${ts} (file age ${age}s, >= ${stale_threshold}s threshold) reports '${status}'. Either loom-backup.timer stopped firing or the last backup.sh run never reached its EXIT trap (e.g. SIGKILLed). See journalctl -u loom-backup.timer and journalctl -u loom-backup.service on the host."
    return 0
  fi
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
  if [ "$HAVE_CURL" -eq 0 ] || [ "$HAVE_JQ" -eq 0 ]; then
    log "error-rate check: curl/jq unavailable this pass; skipping"
    return 0
  fi
  metrics="$(curl -s --max-time 5 "${LOOM_HTTP_BASE}/metrics" 2>/dev/null || true)"
  # TODO(OBI-169/P2-B4): once the real counter lands, confirm whether it's
  # single-series or carries labels. For now this: (a) excludes Prometheus
  # client libraries' auto-generated "<metric>_created" gauge, which starts
  # with the same name prefix and would otherwise be matched and misread as
  # a second/foreign sample of the counter itself (CTO review on PR #34
  # item 4); (b) if the real metric is labelled (multiple series, e.g. per
  # error kind), sums every matching series into one combined counter
  # rather than reading only the first -- a reasonable default for a
  # single alert threshold, revisit once OBI-169 defines the real SLO.
  value="$(printf '%s\n' "$metrics" | awk -v m="$ERROR_METRIC" '
    $1 == m || ($1 ~ "^" m "\\{") { sum += $2; found = 1 }
    END { if (found) printf "%.6f", sum }
  ')"
  if [ -z "$value" ]; then
    log "metric '${ERROR_METRIC}' not present yet (OBI-169/P2-B4 not landed); skipping error-rate check"
    return 0
  fi
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
