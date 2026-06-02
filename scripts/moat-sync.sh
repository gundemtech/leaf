#!/usr/bin/env bash
# moat-sync.sh — vendor the private implementation moat into the gitignored build paths.
#
# Clones (or pulls) gundemtech/leaf-private — the private repo holding the real
# LeafCorePrivate Prod sources + their tests — and rsyncs them into:
#   Packages/LeafCore/Sources/LeafCorePrivate/Prod/   (source moat)
#   Packages/LeafCore/Tests/LeafCorePrivateTests/      (test moat; Placeholder.swift preserved)
# Both targets are already gitignored in the public repo → zero leak. No git submodule.
#
# The clone lives as a sibling of the repo by default (~/Desktop/Leaf/leaf-private);
# override with LEAF_PRIVATE_DIR. Placeholder.swift (the public anchor that keeps the
# SPM targets non-empty) and any tracked *.disabled-* test are never overwritten/deleted.
#
# Editing the moat: edit in the leaf-private clone then re-run `just moat-sync`, OR edit
# in the build paths and run `just moat-push` to send changes back to the clone before
# committing there. Before any destructive sync, the current build-path moat is backed up;
# if it diverges from the clone the sync aborts (run moat-push, or `just moat-sync --force`).
#
# Usage: just moat-sync   (or ./scripts/moat-sync.sh [--force])

set -euo pipefail

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# Shared archive/backup helpers — sourced relative to THIS script (not the repo
# root), so it resolves even when run against an arbitrary working tree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/moat-archive.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PRIVATE_DIR="${LEAF_PRIVATE_DIR:-$(dirname "$REPO_ROOT")/leaf-private}"
PRIVATE_SLUG="gundemtech/leaf-private"
PRIVATE_URL="https://github.com/${PRIVATE_SLUG}.git"
SRC_DST="$REPO_ROOT/Packages/LeafCore/Sources/LeafCorePrivate/Prod"
TEST_DST="$REPO_ROOT/Packages/LeafCore/Tests/LeafCorePrivateTests"
SRC_SRC="$PRIVATE_DIR/Sources/LeafCorePrivate/Prod"
TEST_SRC="$PRIVATE_DIR/Tests/LeafCorePrivateTests"

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

# --- Step 1: clone-or-pull leaf-private --------------------------------------
if [[ -d "$PRIVATE_DIR/.git" ]]; then
    cyan "[1/5] Pulling leaf-private ($PRIVATE_DIR)..."
    git -C "$PRIVATE_DIR" pull --ff-only
else
    cyan "[1/5] Cloning $PRIVATE_SLUG → $PRIVATE_DIR ..."
    gh repo clone "$PRIVATE_SLUG" "$PRIVATE_DIR" 2>/dev/null \
        || git clone "$PRIVATE_URL" "$PRIVATE_DIR"
fi
if [[ ! -d "$SRC_SRC" || ! -d "$TEST_SRC" ]]; then
    red "  leaf-private layout unexpected — missing Sources/LeafCorePrivate/Prod or Tests/LeafCorePrivateTests"
    exit 1
fi

# --- Step 2: back up existing build-path moat + divergence guard -------------
if find "$SRC_DST" "$TEST_DST" -name '*.swift' ! -name 'Placeholder.swift' 2>/dev/null | grep -q .; then
    ARCHIVE_DIR="$(leaf_moat_archive_dir)"
    BACKUP="$ARCHIVE_DIR/autobackup-$(date +%Y%m%d-%H%M%S)"
    cyan "[2/5] Existing build-path moat found → backup to $BACKUP"
    mkdir -p "$BACKUP/Prod" "$BACKUP/Tests"
    rsync -a "$SRC_DST/" "$BACKUP/Prod/" 2>/dev/null || true
    rsync -a -f 'P Placeholder.swift' "$TEST_DST/" "$BACKUP/Tests/" 2>/dev/null || true
    leaf_moat_gc_autobackups "$ARCHIVE_DIR" "$(leaf_moat_keep)"
    if ! diff -rq "$SRC_SRC" "$SRC_DST" >/dev/null 2>&1 \
       || ! diff -rq -x 'Placeholder.swift' -x '*.disabled-*' "$TEST_SRC" "$TEST_DST" >/dev/null 2>&1; then
        yellow "  build-path moat DIFFERS from leaf-private (backed up to $BACKUP)."
        if [[ "$FORCE" != 1 ]]; then
            red "  abort: run 'just moat-push' to save local edits, or 'just moat-sync --force' to overwrite."
            exit 1
        fi
        yellow "  --force: overwriting local edits with leaf-private."
    fi
else
    cyan "[2/5] No existing build-path moat (fresh) — skipping backup."
fi

# --- Step 3: vendor source + test moat (protect Placeholder + *.disabled-*) --
cyan "[3/5] Vendoring moat into build paths..."
mkdir -p "$SRC_DST" "$TEST_DST"
rsync -a --delete "$SRC_SRC/" "$SRC_DST/"                       # Placeholder.swift is one level up → safe
rsync -a --delete -f 'P Placeholder.swift' -f 'P *.disabled-*' "$TEST_SRC/" "$TEST_DST/"

# --- Step 4: clear stale build caches so new files are picked up -------------
cyan "[4/5] Clearing stale SPM + xcodebuild caches..."
swift package clean --package-path "$REPO_ROOT/Packages/LeafCore" 2>/dev/null || true
( cd "$REPO_ROOT" && xcodebuild -scheme LeafCorePrivate clean -quiet 2>/dev/null ) || true

# --- Step 5: assert no moat leak into the public repo ------------------------
cyan "[5/5] Verifying public repo stays moat-clean..."
cd "$REPO_ROOT"
if git status --porcelain -- Packages/LeafCore/Sources/LeafCorePrivate Packages/LeafCore/Tests/LeafCorePrivateTests | grep -q .; then
    red "  LEAK: moat paths appear in git status — check .gitignore"
    git status --porcelain -- Packages/LeafCore/Sources/LeafCorePrivate Packages/LeafCore/Tests/LeafCorePrivateTests
    exit 1
fi
if git ls-files -d | grep -q .; then
    red "  ERROR: tracked files were deleted by sync:"
    git ls-files -d
    exit 1
fi

SRC_N=$(find "$SRC_DST" -name '*.swift' | wc -l | tr -d ' ')
TEST_N=$(find "$TEST_DST" -name '*.swift' ! -name 'Placeholder.swift' | wc -l | tr -d ' ')
green "moat-sync OK — $SRC_N source + $TEST_N test files vendored; public git status clean."
