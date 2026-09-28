<!--
SPDX-FileCopyrightText: 2026 Oberfield
SPDX-License-Identifier: AGPL-3.0-only
-->

# loom-gitops

[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue.svg)](LICENSE)

GitOps source of truth for Loom deployments (FluxCD + Kustomize + SOPS-managed secrets).

## Remotes

- Canonical remote: `https://github.com/LoomMud/loom-gitops` (public).
- Interim local mirrors are read-only historical mirrors during Phase 0/1 migration.

## CI

GitHub Actions runs:
- DCO sign-off checks (`dco` job)
- Hygiene checks (`hygiene` job: gitleaks + REUSE lint)

Runner selection is switchable with repository/org variable `CI_RUNS_ON` (defaults to `ubuntu-latest`).

## Licence

Copyright 2026 Oberfield. Licensed under the [GNU Affero General Public License v3.0 only](LICENSE)
(`AGPL-3.0-only`). See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution policy.

<!-- OBI-136 loom-reviewer verification PR (b); do not merge -->
