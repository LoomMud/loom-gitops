<!--
SPDX-FileCopyrightText: 2026 Oberfield
SPDX-License-Identifier: LicenseRef-Oberfield-Proprietary
-->

# Contributing to loom-gitops

## Status and licence

This repository is **public but not open source (yet)**. The project licence is still being decided, so
every file is `LicenseRef-Oberfield-Proprietary` (all rights reserved). **External contributions are not
accepted** until a licence is chosen; please do not open pull requests from forks. Issues and feedback
are welcome.

## Rules

- Open pull requests against `main`; direct pushes are reserved for bootstrap/migration only.
- Every commit must be DCO signed (`git commit -s`).
- End Paperclip agent commit messages with:
  `Co-Authored-By: Paperclip <noreply@paperclip.ing>`
- Do not commit plaintext secrets. Keep encrypted material only (SOPS).
- REUSE compliance is required for all committed files.

## GitHub auth for CLI

Use the Paperclip-provided token as a one-command environment variable. Never print or persist it.

```sh
GH_TOKEN="$GITHUB_TOKEN" gh auth status
GH_TOKEN="$GITHUB_TOKEN" gh repo view LoomMud/loom-gitops
```
