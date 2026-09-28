-- SPDX-FileCopyrightText: 2026 Oberfield
-- SPDX-License-Identifier: AGPL-3.0-only
--
-- OBI-148 (P1 S2f staging rollout): seed the roles tables on staging
-- *before* WARP_REF moves to warp#9 (a50a002), which reads tiers only
-- from these tables. Run as loom_owner, against the staging `loom` DB,
-- from the `loom` host (Postgres is not published -- see compose.yaml).
--
--   sudo docker compose --project-directory /opt/loom-gitops/staging \
--     --env-file /opt/loom-gitops/staging/images.env --env-file /etc/loom/secrets.env \
--     -f /opt/loom-gitops/staging/compose.yaml exec -T postgres \
--     psql -v ON_ERROR_STOP=1 -U loom_owner -d loom < staging/seed-obi148-roles.sql
--
-- Placeholders below (<AAAA-ACCOUNT-UUID>, etc.) MUST be replaced with the
-- real accounts.id for each named account before running. Look them up
-- first:
--   SELECT id, username FROM accounts WHERE username IN
--     ('aragorn', 'gandalf', 'gimli', 'legolas', 'builder', 'appr');
-- If an account doesn't exist yet, create it (or have the player register)
-- before running the matching block; do not invent a UUID.
--
-- Idempotent: roles_bootstrap_root and roles_set_tier both use
-- ON CONFLICT (uid) DO UPDATE, so re-running this file is safe.

BEGIN;

-- 1. Bootstrap the two roots (T5). roles_bootstrap_root is
--    REVOKE ALL FROM PUBLIC / not GRANTed to loom_app -- only loom_owner
--    (this script's role) may call it.
SELECT public.roles_bootstrap_root('aragorn', '<ARAGORN-ACCOUNT-UUID>');
SELECT public.roles_bootstrap_root('gandalf', '<GANDALF-ACCOUNT-UUID>');
-- If the board names someone other than gandalf as the second root,
-- swap the uid/account_id above and update OBI-148's evidence comment.

-- 2. Seed the alpha staff (T1-3), actor = a root, matching today's
--    /secure/staff intent (OBI-148 description). roles_set_tier is
--    SECURITY DEFINER and enforces the promotion rules itself; called as
--    'aragorn' here only to name the actor for role_changes, not because
--    loom_owner needs it -- loom_owner already bypasses RLS, but we still
--    go through the function so role_changes gets a real actor and a
--    correct old_tier compare.
SELECT public.roles_set_tier('aragorn', 'gimli',   2, 'OBI-148 alpha staff seed');
SELECT public.roles_set_tier('aragorn', 'legolas', 2, 'OBI-148 alpha staff seed (R6 staging)');
SELECT public.roles_set_tier('aragorn', 'builder', 2, 'OBI-148 alpha staff seed');
-- Seed-only assertion coverage (tests/smoke.py tiers expects a T1 'appr'
-- staff row): create the appr account first if it doesn't exist yet.
SELECT public.roles_set_tier('aragorn', 'appr',    1, 'OBI-148 seed-only apprentice for tier smoke suite');

-- 3. Domains: start, forest, test, with sensible members/leads.
--    domains has no security-definer wrapper in 0001/0002 for inserting
--    a domain row itself (roles_set_member below only manages
--    domain_members) -- domains rows are plain data, loom_owner may
--    insert them directly.
INSERT INTO public.domains (name, state) VALUES
    ('start',  'live'),
    ('forest', 'live'),
    ('test',   'wip')
ON CONFLICT (name) DO NOTHING;

-- roles_set_member(actor, domain, target_uid, role) -- see 0001_init.sql.
-- legolas leads forest and start per the OBI-148 description's "(or 3 +
-- lead of forest/start)" option; adjust if the board picks plain T2 with
-- no lead instead.
SELECT public.roles_set_member('aragorn', 'start',  'legolas', 'lead',   'OBI-148 alpha staff seed');
SELECT public.roles_set_member('aragorn', 'forest', 'legolas', 'lead',   'OBI-148 alpha staff seed');
SELECT public.roles_set_member('aragorn', 'test',   'gimli',   'member', 'OBI-148 alpha staff seed');
SELECT public.roles_set_member('aragorn', 'test',   'builder', 'member', 'OBI-148 alpha staff seed');

COMMIT;

-- Verify before bumping WARP_REF:
--   SELECT uid, tier FROM staff ORDER BY tier DESC, uid;
--   SELECT domain, uid, role FROM domain_members ORDER BY domain, role;
-- Only once every intended staff row is present should WARP_REF move to
-- a50a002 -- see RUNBOOK.md §9 and OBI-148.
