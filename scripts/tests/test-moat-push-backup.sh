#!/usr/bin/env bash
# test-moat-push-backup.sh — moat-push.sh must back up the leaf-private clone's
# current moat BEFORE its reverse `rsync --delete` overwrites it, so an accidental
# wrong-direction or empty-build-path push can't destroy uncommitted clone edits.
# (moat-sync already auto-backs-up the build path; moat-push had no such guard.)
# Bash 3.2 compatible (macOS default).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUSH="$REPO_ROOT/scripts/moat-push.sh"

fail() { echo "✘ test-moat-push-backup: FAIL — $1"; exit 1; }

sandbox="$(mktemp -d -t leaf-moat-push.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

repo="$sandbox/repo"
clone="$sandbox/clone"
archive="$sandbox/archive"

# fake public repo with build-path moat (the source of the push)
git -C "$repo" init -q 2>/dev/null || { mkdir -p "$repo" && git -C "$repo" init -q; }
mkdir -p "$repo/Packages/LeafCore/Sources/LeafCorePrivate/Prod"
mkdir -p "$repo/Packages/LeafCore/Tests/LeafCorePrivateTests"
echo "// from build path" > "$repo/Packages/LeafCore/Sources/LeafCorePrivate/Prod/NewFromBuild.swift"

# fake leaf-private clone with PRE-EXISTING moat that reverse --delete would destroy
mkdir -p "$clone"; git -C "$clone" init -q
mkdir -p "$clone/Sources/LeafCorePrivate/Prod"
mkdir -p "$clone/Tests/LeafCorePrivateTests"
echo "// only in clone, uncommitted" > "$clone/Sources/LeafCorePrivate/Prod/OldClone.swift"

mkdir -p "$archive"
LEAF_PRIVATE_DIR="$clone" LEAF_MOAT_ARCHIVE_DIR="$archive" \
  bash -c "cd '$repo' && bash '$PUSH'" >/dev/null 2>&1 || fail "moat-push.sh exited non-zero"

# push worked: build-path file landed in the clone
[ -f "$clone/Sources/LeafCorePrivate/Prod/NewFromBuild.swift" ] \
  || fail "push did not copy build-path moat into clone"
# test premise: reverse --delete removed the clone-only file from the live clone
[ ! -f "$clone/Sources/LeafCorePrivate/Prod/OldClone.swift" ] \
  || fail "premise broken: --delete did not remove OldClone.swift"
# the safety guarantee: the destroyed file survives in a pre-delete backup
found="$(find "$archive" -path '*push-autobackup-*' -name 'OldClone.swift' 2>/dev/null | head -1)"
[ -n "$found" ] \
  || fail "clone moat NOT backed up before reverse --delete (OldClone.swift unrecoverable)"

echo "✓ test-moat-push-backup: clone moat is backed up before reverse --delete."
