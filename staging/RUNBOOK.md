# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only

# Loom staging runbook (R6, OBI-42)

Operational reference for the Docker Compose staging stack declared in this
directory. For the one-time host provisioning (OS, users, firewall, DNS,
Azure backup storage, age keypair, GitHub/GHCR tokens), see
[`SETUP.md`](SETUP.md); this document starts where that one hands off
(§9, "Bootstrap & verification").

**Design reference:** OBI-8 plan r4 §3.4 (D-P1.7-D-P1.14). **Naming:** the
host and every user/path on it use `loom`, not `loom-staging`; only this
repo directory is called `staging/` (a layout choice, not a host name).

## 1. Fill in secrets

```bash
sudo install -o root -g loom -m 0640 /opt/loom-gitops/staging/secrets.env.example /etc/loom/secrets.env
sudoedit /etc/loom/secrets.env
```

Fill in at least `POSTGRES_SUPERUSER_PASSWORD`, `LOOM_OWNER_PASSWORD`,
`LOOM_APP_PASSWORD` (each its own `openssl rand -hex 24`, OBI-130 DB role
separation -- see `secrets.env.example` for what each login is for),
`GITHUB_STATUS_TOKEN` (SETUP.md §8.1) and `GITHUB_ALERTS_TOKEN`
(SETUP.md §8.1b, OBI-175 -- a separately-scoped token for the alerting
timer in §9 below; loom-alerts.timer runs and logs without it, it just
doesn't deliver anything). Leave the `AZURE_STORAGE_*` and
`GHCR_TOKEN` lines commented out until they're provisioned (OBI-109);
`staging/backup.sh` and `staging/reconcile.sh` both tolerate that as a
documented no-op, not a failure.

Never `cat` this file to a shared screen or paste its contents anywhere.
`secrets.env.example` in this repo holds names only.

## 2. Install the timer (and run the first reconcile)

```bash
sudo /opt/loom-gitops/staging/bootstrap.sh
```

This installs `loom-reconcile.service`/`.timer` (every 2 min),
`loom-backup.service`/`.timer` (nightly, 02:30 UTC -- 2h clear of the
04:30 UTC unattended-upgrade reboot window) and `loom-alerts.service`/`.timer`
(every minute, OBI-175), all `User=loom`, then runs the reconciler once
synchronously so first-boot failures are visible immediately. It refuses to proceed (rather than silently fixing things) if
`/etc/loom`/`secrets.env` have the wrong owner/mode, or if
`/opt/loom-gitops` isn't already owned by `loom`.

Manual equivalents, if you need to run a step by hand:

```bash
sudo systemctl start loom-reconcile.service   # one reconcile, right now
journalctl -u loom-reconcile.service -n 100   # what it did
systemctl list-timers | grep loom             # next scheduled runs
sudo systemctl start loom-backup.service      # manual first backup trigger
                                               # (same script the timer uses)
```

## 3. Run migrations (loom_owner)

**Automatic (OBI-130/OBI-138):** `LOOM_IMAGE` ships the `loom migrate`
subcommand (loom#51), and `compose.yaml`'s `loom: depends_on:` gates on
`migrate: {condition: service_completed_successfully}`, the same way it
already gates on `mudlib-sync`. A default

```bash
sudo docker compose --project-directory /opt/loom-gitops/staging \
  --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
  -f /opt/loom-gitops/staging/compose.yaml up -d
```

applies every pending `loom_owner` migration before `loom` starts --
there is no separate manual step. `migrate` authenticates as `loom_owner`
(`LOOM_DB_MIGRATE_URL`, compose.yaml), never the superuser or `loom_app`.
It's idempotent (`sqlx migrate` tracks applied migrations in
`_sqlx_migrations`), so it's a fast no-op on every reconcile once nothing
is pending. To run it by hand (e.g. to inspect its output outside a full
`up -d`):

```bash
sudo docker compose --project-directory /opt/loom-gitops/staging \
  --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
  -f /opt/loom-gitops/staging/compose.yaml run --rm migrate
```

## 4. Check it's up

```bash
sudo docker compose --project-directory /opt/loom-gitops/staging \
  --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
  -f /opt/loom-gitops/staging/compose.yaml ps
```
Expect `loom`, `caddy`, `postgres` `Up ... (healthy)` and `mudlib-sync`
`Exited (0)`. Then the full checklist in `SETUP.md` §9.4 (DNS, firewall,
TLS, telnet, web client, commit status).

## 5. Rebuild a lost host from git + the last dump

If the host is gone (disk failure, terminated instance, etc.), and Azure
Blob backups are configured and have at least one nightly run:

1. Re-provision a host per `SETUP.md` §1-8 (OS, users, firewall, DNS,
   Azure storage already exists and doesn't need recreating, age keypair
   already exists offline).
2. `sudo /opt/loom-gitops/staging/bootstrap.sh`. This brings up `loom` with
   an **empty** `pgdata` volume (a fresh `postgres:17-alpine` container) --
   accounts and world state are gone until you restore.
3. Run the restore drill (§5 below) against the **real** bucket and the
   **real** age private key, restoring into the actual `postgres` service
   this time (not a scratch container): stop `loom`, `pg_restore` into the
   running `postgres` container, restart `loom`.
   ```bash
   sudo docker compose --project-directory /opt/loom-gitops/staging \
     --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
     -f /opt/loom-gitops/staging/compose.yaml stop loom
   # decrypt + pg_restore the fetched dump directly into the postgres
   # container (adapt staging/restore.sh's docker-cp/pg_restore lines --
   # this is the one drill step that intentionally does NOT use a scratch
   # container, because the point here is to repopulate the real one).
   sudo docker compose --project-directory /opt/loom-gitops/staging \
     --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
     -f /opt/loom-gitops/staging/compose.yaml start loom
   ```
4. Untar the mudlib backup over the `mudlib` volume if `mudlib-sync`'s
   pinned `WARP_REF` no longer exists upstream; otherwise `mudlib-sync`
   already repopulated it from `staging/images.env`'s `WARP_REPO`/`WARP_REF`
   in step 2, and the tarball is only needed for anything not in that ref
   (there shouldn't be any -- the mudlib volume is git-sourced by design).

## 6. Restore drill

```bash
# on an admin workstation, or the host, with age/rclone/docker available
source /etc/loom/secrets.env   # or export AZURE_STORAGE_* by hand
export AZURE_STORAGE_ACCOUNT AZURE_STORAGE_CONTAINER AZURE_STORAGE_SAS_TOKEN
staging/restore.sh --age-key /path/to/loom-backup.agekey --prefix daily --date 2026-10-01
```

This fetches the two blobs for that date, decrypts them with the age
**private** key (a 0600 file you provide; never written into the repo or
`/etc/loom`, and the copy in `$WORKDIR` is `shred`-ed on exit), restores
the dump into a **throwaway** `postgres:17-alpine` container (never the
real `postgres` service), and runs a smoke query. Exit code 0 and a
printed row count means the drill passed.

**Local dry run (no real Azure account, no board credentials needed):**
run an Azurite container (the Azure Storage emulator) plus a throwaway
age key, then point `backup.sh`/`restore.sh` at it by setting
`AZURE_STORAGE_ACCOUNT`/`AZURE_STORAGE_SAS_TOKEN` to Azurite's fixed dev
credentials and `AZURE_STORAGE_CONTAINER` to a container you create with
`az storage container create --connection-string "$AZURITE_CONN"`. This is
the drill referenced in the OBI-42 acceptance criteria; its output belongs
in the OBI-42 evidence, not here (it doesn't touch the real host or
secrets, so it can be re-run at will).

## 7. Roll back

Every deploy is a git commit. To roll back:

```bash
git revert <bump-commit-sha>   # e.g. the merge commit from a bump-staging PR
git push origin main
```

The reconciler fast-forwards to the reverted `main` on its next run (up to
2 minutes) and recreates `loom` at the previous digest (or, for a `WARP_REF`
revert, after `mudlib-sync` has reset the volume to the previous ref). No host access is
needed for a rollback -- it's a normal PR/revert against `loom-gitops`.

## 8. Post-deploy checklist (OBI-42/OBI-157)

Run this after every merged bump (`bump-staging` PR merge, a manual
`images.env` edit, or a `WARP_REF` bump) once the reconciler has picked it
up (up to 2 minutes; `H9`/`H10` in `SETUP.md` §9.4 show whether it has).
It's the same telnet/web-client walk-through as `SETUP.md` §9.4 rows
X9-X12, trimmed to what changes on a routine deploy (not a fresh-host
bootstrap -- skip DNS/firewall/TLS-cert rows, those don't move on a
container recreate).

| # | Check | Command | Expect |
|---|---|---|---|
| D1 | Reconcile status | `gh api repos/LoomMud/loom-gitops/commits/main/statuses --jq '[.[] \| select(.context=="staging/reconcile")][0] \| .state + " " + .description'` | `success deployed <sha> (loom @ <digest>)` at the new merge commit |
| D2 | Containers healthy | `sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'` | `loom`, `caddy`, `postgres` `Up … (healthy)`; `mudlib-sync` exited 0 |
| D3 | Telnet banner | `telnet system.loommud.com 4000` (quit with `Ctrl-]` then `quit`) | Loom banner / login prompt |
| D4 | Character round-trip | log in (or create a throwaway character), walk somewhere or set a variable, quit, reconnect | state persisted (proves the recreate was a graceful SIGTERM, D-P1.10, not a data-losing crash) |
| D5 | Web client, HTTPS | open `https://loommud.com/` in a browser, or `curl -sS https://loommud.com/` | `200` and the client's `index.html` (a real page, not a `404`) -- since OBI-158, `loom-http` serves the built web client itself as its router fallback (`LOOM_WEB_ROOT`, defaulted in the image), same origin as `/ws` |
| D6 | Origin not reachable around Cloudflare | `curl -sS --max-time 8 -o /dev/null -w '%{http_code}\n' --resolve loommud.com:443:PUBLIC_IPV4 https://loommud.com/` | `000` (timeout) -- this is the **expected**, correct result of the §4.5 Cloudflare-only firewall rule, not a bug. If you instead get a real HTTP response here, the firewall rule has regressed. |
| D7 | Metrics not public | `curl -s -o /dev/null -w '%{http_code}\n' https://loommud.com/metrics` | `403` or `404`, **not** `200` |

If `D1` isn't green within a couple of reconcile cycles (4 minutes), don't
wait for the next scheduled `bump-staging` run to notice -- go straight to
`journalctl -u loom-reconcile.service -n 100` on the host and §7
(rollback) if the fix isn't quick. `bump-staging.yml` also now checks the
current `staging/reconcile` status before opening a new bump PR (OBI-157):
if reconcile is broken, its scheduled runs go red every 15 minutes instead
of silently stacking a new bump on top of a broken deploy -- treat a red
`bump-staging` Actions run as the same signal as a red `D1` here.

## 9. OBI-148: rolling the S2 tier policy onto staging

Order matters: warp `a50a002` (and later) reads tiers **only** from the
roles tables (§5.11.3). Bumping `WARP_REF` before the staff rows exist
turns every account into tier 0 and hides every staff tool. Do this in
order, not in parallel:

1. Merge a `LOOM_IMAGE` bump to a digest built from `main` at or after
   loom#54 (`d4ba99e`) -- safe on its own, the roles snapshot loader is
   inert until warp's master actually reads it. Confirm the digest was
   cosign-verified in the release-image.yml run before recording it here
   (see the comment above `LOOM_IMAGE` in `images.env`).
2. On the host, as `loom_owner`, fill in the account UUIDs in
   `staging/seed-obi148-roles.sql` and run it (command in the file's
   header comment). This calls `roles_bootstrap_root` for the two roots
   and `roles_set_tier`/`roles_set_member` for the alpha staff and
   domains. Verify with the two `SELECT`s at the end of that file.
3. Only then merge a `WARP_REF` bump to `a50a002` (or later `main`).
   `mudlib-sync` resets the `mudlib` volume and the reconciler recreates
   `loom` on its next run (up to 2 minutes). The recreate comes from the
   `org.loommud.warp-ref` label in `compose.yaml`. Before that label
   existed, the volume changed under a running driver and `loom` had to be
   recreated by hand (`up -d --no-deps --force-recreate loom`, OBI-152).
4. Verify: staff can log in and `roles <name>` shows their tier; run
   `LOOM_SMOKE_DATABASE_URL=<staging loom_app url> tests/smoke.py tiers`
   from a host/workstation that can reach the staging Postgres, or the
   manual checks in OBI-148 (apprentice confinement, `promote`/`approve`
   two-root round trip, one `role_changes` row, one `audit_log` row).

**Rollback:** revert the `WARP_REF` bump commit first (per §7 -- this
alone restores the Phase 0 allow-all master without touching the roles
tables), then decide separately whether to also revert the `LOOM_IMAGE`
bump. Do not delete the seeded roles rows as part of a rollback; they are
harmless while the Phase 0 master is back in place and save re-seeding
when `WARP_REF` moves forward again.

## 10. Upgrades recreate the container, they don't restart the host

A `LOOM_IMAGE` digest bump (merged `bump-staging.yml` PR, or a hand-edited
`images.env` change) makes the next reconcile recreate **only** the `loom`
container. `stop_grace_period: 30s` gives it time to receive SIGTERM, save
state and close sockets before Compose sends SIGKILL; players reconnect
and keep their characters (D-P1.10). `caddy` and `postgres` are untouched
unless *their* pinned digests change.

To prove this locally (no host needed): edit `staging/images.env`'s
`LOOM_IMAGE` to a second digest (or `docker build` a `:dev` tag locally
and re-tag it), `docker compose -f staging/compose.yaml up -d loom` while
a `telnet localhost 4000` session is logged in and has, say, walked
somewhere or set a variable, then reconnect after the recreate and
confirm the character (location, any state set) persisted. See the OBI-42
issue for a recorded run of this drill.

## 11. Alerting (OBI-175/P2-O4)

Retro R3: a 68-minute staging outage on 09-28 went unnoticed because the
only failure signal was a GitHub commit status (`staging/reconcile`,
§8/§D1 above) nobody was watching live. `loom-alerts.timer` runs
`staging/alerts.sh` every minute (`docker compose --profile alerts run
--rm alerts`, on the same compose network as `loom`, so it can reach
`loom:8080` directly) and pushes a failure to the channel this team
already watches: **a GitHub issue, labeled `alert`, in
`LoomMud/loom-gitops`**. It opens one on the transition into "firing",
comments on it (throttled to once per 15 minutes) while the condition
keeps firing, and closes it on recovery. Needs `GITHUB_ALERTS_TOKEN` in
`secrets.env` (SETUP.md §8.1b) to actually deliver anything -- without
it, every check still runs and logs to `journalctl -u
loom-alerts.service`, it just doesn't open/update an issue.

Four checks, each independent:

| Alert | Condition | Source |
|---|---|---|
| `reconcile` | `staging/reconcile` commit status on `origin/main` is `failure`/`error` | GitHub commits API (unauthenticated read; public repo) |
| `readyz` | `GET http://loom:8080/readyz` has not returned `200` for >= 120s (`LOOM_ALERTS_READYZ_THRESHOLD_SECS`) | direct check against `loom`'s internal HTTP port |
| `backup` | `backup.sh`'s last run wrote `failure` to `./alerts-state/backup-status` | shared bind mount between the `backup` and `alerts` services |
| `error_rate` | the counter `loom_runtime_errors_total` (`LOOM_ALERTS_ERROR_METRIC`) increases faster than `LOOM_ALERTS_ERROR_RATE_THRESHOLD` (default 1/s, a placeholder) | `loom`'s `/metrics` |

**These are all on-host checks and cannot see a host outage** (the host
itself down, Docker dead, or the compose network unreachable): all four
run as `docker compose --profile alerts run --rm alerts` on the same
host they're checking, so if the host is down, nothing runs `alerts.sh`
at all and no alert fires for that. An off-host probe (pinging the host
from somewhere else entirely) is filed separately as
[OBI-196](https://github.com/LoomMud/loom-gitops/issues/196), not yet
built. Until then, a total host outage is this alerting system's blind
spot.

**`error_rate` is wired but inert until OBI-169 (P2-B4, the error inbox)
lands and exports that counter.** Until then, `alerts.sh` logs a skip
every run ("metric not present yet") and never fires. Once OBI-169 ships,
confirm the metric name matches `LOOM_ALERTS_ERROR_METRIC` (override it
in `secrets.env` or the service's `environment:` if it doesn't) and pick
a real threshold with Aragorn/Gimli instead of the placeholder `1/s`,
then fire it once on purpose the same way as the other three (below) and
record the issue link on OBI-175.

### Fire each one on purpose

```bash
compose() {
  docker compose --project-directory /opt/loom-gitops/staging \
    --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
    -f /opt/loom-gitops/staging/compose.yaml "$@"
}

# reconcile: there is no safe way to make a real staging/reconcile run
# fail on purpose without actually breaking the stack, so prove this one
# by pointing LOOM_ALERTS_RECONCILE_SHA at a commit you know carries a
# failure status (or temporarily post one by hand with GITHUB_STATUS_TOKEN,
# the same curl reconcile.sh itself uses, then revert it).
compose --profile alerts run --rm \
  -e LOOM_ALERTS_RECONCILE_SHA=<sha with a failure status> \
  alerts

# readyz: stop loom so /readyz stops answering, run alerts.sh past the
# 2-minute threshold (twice, >=120s apart), then restart it.
compose stop loom
compose --profile alerts run --rm alerts   # starts the down-since timer
sleep 130
compose --profile alerts run --rm alerts   # fires (opens the issue)
compose start loom
compose --profile alerts run --rm alerts   # resolves (closes the issue)

# backup: write a failure status by hand, run alerts.sh, then clear it.
echo "failure $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > /opt/loom-gitops/staging/alerts-state/backup-status
compose --profile alerts run --rm alerts
echo "success $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > /opt/loom-gitops/staging/alerts-state/backup-status
compose --profile alerts run --rm alerts
```

Evidence for each firing (the opened/closed issue URL, plus the relevant
`journalctl -u loom-alerts.service` lines) belongs in OBI-175, not here.

### Local dry run (no GitHub token, no staging host)

`LOOM_ALERTS_DRY_RUN=1` makes `alerts.sh` log what it would fire/resolve
instead of calling the GitHub API -- useful for checking the detection
logic (readyz timer math, backup status parsing) without a token or a
real repo. See `.github/workflows/ci.yml`'s `alerts-dry-run` job for a
worked example against a throwaway HTTP stub instead of a real `loom`.
