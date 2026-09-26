<!--
SPDX-FileCopyrightText: 2026 Oberfield
SPDX-License-Identifier: LicenseRef-Oberfield-Proprietary
-->

# loom-gitops

GitOps source of truth for Loom deployments (FluxCD + Kustomize + SOPS-managed secrets).

## Remotes

- Canonical remote: `https://github.com/LoomMud/loom-gitops` (private).
- Interim local mirrors are read-only historical mirrors during Phase 0/1 migration.

## CI

GitHub Actions runs:
- DCO sign-off checks (`dco` job)
- Hygiene checks (`hygiene` job: gitleaks + REUSE lint)

Runner selection is switchable with repository/org variable `CI_RUNS_ON` (defaults to `ubuntu-latest`).
