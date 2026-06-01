#!/usr/bin/env bash
# moat-push.sh — reverse-sync local moat edits from the build paths back into the
# leaf-private clone, so they can be committed + pushed there.
#
# Use this when you edited the moat in place (Packages/LeafCore/.../Prod or
# .../LeafCorePrivateTests) rather than in the leaf-private clone. It mirrors the
# build-path moat into the clone (protecting the public-tracked Placeholder.swift
# and *.disabled-* test), then prints the commit command.
#
# Usage: just moat-push   (or ./scripts/moat-push.sh)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PRIVATE_DIR="${LEAF_PRIVATE_DIR:-$(dirname "$REPO_ROOT")/leaf-private}"
SRC_DST="$REPO_ROOT/Packages/LeafCore/Sources/LeafCorePrivate/Prod"
TEST_DST="$REPO_ROOT/Packages/LeafCore/Tests/LeafCorePrivateTests"
SRC_SRC="$PRIVATE_DIR/Sources/LeafCorePrivate/Prod"
TEST_SRC="$PRIVATE_DIR/Tests/LeafCorePrivateTests"

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

if [[ ! -d "$PRIVATE_DIR/.git" ]]; then
    red "leaf-private clone not found at $PRIVATE_DIR — run 'just moat-sync' first."
    exit 1
fi

cyan "[1/2] Reverse-syncing build-path moat → leaf-private ($PRIVATE_DIR)..."
mkdir -p "$SRC_SRC" "$TEST_SRC"
rsync -a --delete "$SRC_DST/" "$SRC_SRC/"
# never carry the public-only Placeholder / *.disabled-* into the moat repo
rsync -a --delete --exclude 'Placeholder.swift' --exclude '*.disabled-*' "$TEST_DST/" "$TEST_SRC/"

cyan "[2/2] Pending changes in leaf-private:"
git -C "$PRIVATE_DIR" status --short || true
green "Reverse-sync done. Commit + push:"
echo "  git -C \"$PRIVATE_DIR\" add -A && git -C \"$PRIVATE_DIR\" commit -m \"<msg>\" && git -C \"$PRIVATE_DIR\" push"
