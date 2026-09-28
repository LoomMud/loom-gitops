#!/bin/sh
# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only
#
# staging/postgres/init/01-create-roles.sh (R6, OBI-130). Mounted into
# /docker-entrypoint-initdb.d/ (the official postgres image's own
# bootstrap hook); runs exactly once, as the container's superuser, the
# very first time the `pgdata` volume is initialized -- never again on a
# restart or recreate against an existing volume.
#
# Creates the two logins loom-persist's migrations assume (D-27.4,
# migrations/0001_init.sql's header, tests/support/mod.rs): `loom_owner`
# (owns the database and every table/function; runs migrations) and
# `loom_app` (the world-runtime login; not an owner, no DDL rights).
# Neither is the Postgres superuser (`POSTGRES_USER`, staging/compose.yaml)
# -- the superuser password is used only here, at first init, and by the
# postgres image's own liveness tooling. It is never in DATABASE_URL or
# LOOM_DB_MIGRATE_URL.
#
# Idempotent within a single fresh-volume run (safe to re-source), but not
# across volumes: to rotate a password after this has already run, use
# `ALTER ROLE ... PASSWORD ...` by hand (see RUNBOOK.md), not a re-run of
# this script.
set -eu

: "${LOOM_OWNER_PASSWORD:?LOOM_OWNER_PASSWORD must be set (see staging/secrets.env.example)}"
: "${LOOM_APP_PASSWORD:?LOOM_APP_PASSWORD must be set (see staging/secrets.env.example)}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
	CREATE ROLE loom_owner LOGIN PASSWORD '$LOOM_OWNER_PASSWORD';
	CREATE ROLE loom_app LOGIN PASSWORD '$LOOM_APP_PASSWORD';
	ALTER DATABASE "$POSTGRES_DB" OWNER TO loom_owner;
	GRANT ALL ON DATABASE "$POSTGRES_DB" TO loom_owner;
SQL

echo "01-create-roles: loom_owner and loom_app created, $POSTGRES_DB owned by loom_owner"
