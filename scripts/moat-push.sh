#!/usr/bin/env bash
# moat-push.sh — reverse-sync local moat edits from the build paths back into the
# leaf-private clone, so they can be committed + pushed there.
#
# Use this when you edited the moat in place (Packages/LeafCore/.../Prod or
# .../LeafCorePrivateTests) rather than in the leaf-private clone. It mirrors the
# build-path moat into the clone (protecting the public-tracked Placeholder.swift
# and *.disabled-* test), then prints the commit command.
#
# Before the destructive reverse `rsync --delete`, the clone's current moat is
# backed up to the moat archive (symmetric with moat-sync) — so a wrong-direction
# or empty-build-path push can't unrecoverably wipe uncommitted clone edits.
#
# Usage: just moat-push   (or ./scripts/moat-push.sh)

set -euo pipefail

# Shared archive/backup helpers — sourced relative to THIS script (not the repo
# root), so it resolves even when run against an arbitrary working tree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/moat-archive.sh"

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

# --- Step 1: back up the clone's current moat before the destructive sync ----
have_moat=0
if [ -d "$SRC_SRC" ]  && find "$SRC_SRC"  -name '*.swift' 2>/dev/null | grep -q .; then have_moat=1; fi
if [ -d "$TEST_SRC" ] && find "$TEST_SRC" -name '*.swift' 2>/dev/null | grep -q .; then have_moat=1; fi
if [ "$have_moat" -eq 1 ]; then
    ARCHIVE_DIR="$(leaf_moat_archive_dir)"
    BACKUP="$ARCHIVE_DIR/push-autobackup-$(date +%Y%m%d-%H%M%S)"
    cyan "[1/3] Backing up leaf-private clone moat → $BACKUP"
    mkdir -p "$BACKUP/Prod" "$BACKUP/Tests"
    rsync -a "$SRC_SRC/"  "$BACKUP/Prod/"  2>/dev/null || true
    rsync -a "$TEST_SRC/" "$BACKUP/Tests/" 2>/dev/null || true
    leaf_moat_gc_autobackups "$ARCHIVE_DIR" "$(leaf_moat_keep)"
else
    cyan "[1/3] Clone has no existing moat — nothing to back up."
fi

cyan "[2/3] Reverse-syncing build-path moat → leaf-private ($PRIVATE_DIR)..."
mkdir -p "$SRC_SRC" "$TEST_SRC"
rsync -a --delete "$SRC_DST/" "$SRC_SRC/"
# never carry the public-only Placeholder / *.disabled-* into the moat repo
rsync -a --delete --exclude 'Placeholder.swift' --exclude '*.disabled-*' "$TEST_DST/" "$TEST_SRC/"

cyan "[3/3] Pending changes in leaf-private:"
git -C "$PRIVATE_DIR" status --short || true
green "Reverse-sync done. Commit + push:"
echo "  git -C \"$PRIVATE_DIR\" add -A && git -C \"$PRIVATE_DIR\" commit -m \"<msg>\" && git -C \"$PRIVATE_DIR\" push"
