#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: LicenseRef-Oberfield-Proprietary
set -euo pipefail

range="${1:-HEAD}"

commits=$(git rev-list "$range")
if [[ -z "$commits" ]]; then
  echo "No commits in range: $range"
  exit 0
fi

failed=0
for c in $commits; do
  author_name=$(git show -s --format='%an' "$c")
  author_email=$(git show -s --format='%ae' "$c")
  trailer=$(git show -s --format='%(trailers:key=Signed-off-by,valueonly)' "$c" | sed '/^$/d' | tail -n1)

  if [[ -z "$trailer" ]]; then
    echo "Missing Signed-off-by trailer: $c"
    failed=1
    continue
  fi

  expected="$author_name <$author_email>"
  if [[ "$trailer" != "$expected" ]]; then
    echo "Signed-off-by mismatch in $c"
    echo "  expected: $expected"
    echo "  actual:   $trailer"
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "DCO check passed for range: $range"
