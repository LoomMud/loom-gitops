<!--
SPDX-FileCopyrightText: 2026 Oberfield
SPDX-License-Identifier: AGPL-3.0-only
-->

# Contributing to loom-gitops

## Status and licence

This repository is public and licensed under the **GNU Affero General Public License v3.0 only**
(`AGPL-3.0-only`). The full text is in [`LICENSE`](LICENSE) (REUSE copy: `LICENSES/AGPL-3.0-only.txt`).
Every file carries an SPDX header naming `AGPL-3.0-only` as its licence identifier.

**External pull requests are not accepted for now.** Please do not open pull requests from forks; they
will be closed unmerged. Issues, bug reports and feedback are welcome. We will revisit this (most likely
accepting contributions under AGPL-3.0-only with DCO sign-off) once the contribution governance is settled.

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
