# SPDX-FileCopyrightText: 2026 Oberfield
# SPDX-License-Identifier: AGPL-3.0-only
#
# staging/alerts/Dockerfile (OBI-175/P2-O4 follow-up, CTO review on PR #34
# item 2). `alerts.sh` runs every minute via loom-alerts.timer; installing
# curl+jq from Alpine's repos on every single pass (the original approach,
# matching backup.sh's once-a-night pattern) means a transient Alpine CDN
# or DNS blip aborts the whole pass under `set -e` and silences all four
# alerts at once. Baking curl+jq into the image removes that per-minute
# network dependency entirely: the base layer is still pinned by digest
# (same alpine:3.22 base as BACKUP_IMAGE/staging/images.env), and only
# this image's own build (via .github/workflows/alerts-image.yml, on a
# push that touches this Dockerfile) touches Alpine's package repos.
#
# Built, signed (cosign, keyless OIDC) and SBOM'd by
# .github/workflows/alerts-image.yml; referenced by digest as
# ALERTS_IMAGE in staging/images.env, same pin discipline as every other
# image in that file.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

RUN apk add --no-cache curl jq && rm -rf /var/cache/apk/*
