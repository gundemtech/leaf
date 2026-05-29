#!/usr/bin/env bash
# rewrite-authors.sh — one-shot git-history author/email rewrite for OSS
# promotion (see docs/superpowers/decisions/2026-05-25-oss-promotion-decisions.md
# D1). Collapses every historic commit identity into one neutral identity and
# strips personal emails, so the public repo's history carries no PII.
#
# Safety: operates on a FRESH MIRROR you point it at — never the working clone —
# so the rewrite is fully reviewable before any force-push. This script hardcodes
# NO names or emails; it derives the existing identities dynamically.
#
# Usage:
#   git clone --mirror git@github.com:gundemtech/leaf.git /tmp/leaf-mirror.git
#   scripts/oss/rewrite-authors.sh /tmp/leaf-mirror.git "Leaf Team" "dev@gundem.tech"
#   # review /tmp/leaf-mirror.git, then:
#   git -C /tmp/leaf-mirror.git push --force --mirror
#
# Not executed automatically anywhere. Run by the maintainer at promotion time.
set -euo pipefail

MIRROR="${1:?usage: rewrite-authors.sh <mirror-dir> [neutral-name] [neutral-email]}"
NEUTRAL_NAME="${2:-Leaf Team}"
NEUTRAL_EMAIL="${3:-dev@gundem.tech}"

command -v git-filter-repo >/dev/null 2>&1 || {
    echo "error: git-filter-repo not found (brew install git-filter-repo)"; exit 1; }
[ -d "$MIRROR" ] || { echo "error: not a directory: $MIRROR"; exit 1; }

# Derive every existing identity dynamically → generated mailmap (temp, deleted).
MAILMAP="$(mktemp)"
trap 'rm -f "$MAILMAP"' EXIT
git -C "$MIRROR" log --all --format='%aN <%aE>%n%cN <%cE>' \
    | sort -u \
    | while IFS= read -r id; do
          [ -n "$id" ] && printf '%s <%s> %s\n' "$NEUTRAL_NAME" "$NEUTRAL_EMAIL" "$id"
      done > "$MAILMAP"

echo "Rewriting $(wc -l < "$MAILMAP" | tr -d ' ') identities → ${NEUTRAL_NAME} <${NEUTRAL_EMAIL}> in ${MIRROR}"
git -C "$MIRROR" filter-repo --mailmap "$MAILMAP" --force

echo "Done. Review the mirror, then: git -C ${MIRROR} push --force --mirror"
