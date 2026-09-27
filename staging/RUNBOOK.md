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

Fill in at least `POSTGRES_PASSWORD` (`openssl rand -hex 24`) and
`GITHUB_STATUS_TOKEN` (SETUP.md §8.1). Leave the `AZURE_STORAGE_*` and
`GHCR_TOKEN` lines commented out until they're provisioned (OBI-109);
`staging/backup.sh` and `staging/reconcile.sh` both tolerate that as a
documented no-op, not a failure.

Never `cat` this file to a shared screen or paste its contents anywhere.
`secrets.env.example` in this repo holds names only.

## 2. Install the timer (and run the first reconcile)

```bash
sudo /opt/loom-gitops/staging/bootstrap.sh
```

This installs `loom-reconcile.service`/`.timer` (every 2 min) and
`loom-backup.service`/`.timer` (nightly, 02:30 UTC -- 2h clear of the
04:30 UTC unattended-upgrade reboot window), both `User=loom`, then runs
the reconciler once synchronously so first-boot failures are visible
immediately. It refuses to proceed (rather than silently fixing things) if
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

## 3. Check it's up

```bash
sudo docker compose --project-directory /opt/loom-gitops/staging \
  --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
  -f /opt/loom-gitops/staging/compose.yaml ps
```
Expect `loom`, `caddy`, `postgres` `Up ... (healthy)` and `mudlib-sync`
`Exited (0)`. Then the full checklist in `SETUP.md` §9.4 (DNS, firewall,
TLS, telnet, web client, commit status).

## 4. Rebuild a lost host from git + the last dump

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

## 5. Restore drill

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

## 6. Roll back

Every deploy is a git commit. To roll back:

```bash
git revert <bump-commit-sha>   # e.g. the merge commit from a bump-staging PR
git push origin main
```

The reconciler fast-forwards to the reverted `main` on its next run (up to
2 minutes) and recreates `loom` at the previous digest. No host access is
needed for a rollback -- it's a normal PR/revert against `loom-gitops`.

## 7. Upgrades recreate the container, they don't restart the host

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
