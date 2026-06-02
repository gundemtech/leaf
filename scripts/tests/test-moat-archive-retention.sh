#!/usr/bin/env bash
# test-moat-archive-retention.sh — unit test for leaf_moat_gc_autobackups.
# The moat-sync/moat-push autobackups accumulate in _moat-archive without bound
# (this was a flagged sprawl: copies of the secret source tree pile up forever).
# This guard asserts the retention GC keeps the newest N backup dirs and removes
# older ones — crucially by MTIME, not name, so the `push-autobackup-*` prefix
# (which sorts after `autobackup-*` lexically) can't keep a stale backup alive.
# Bash 3.2 compatible (macOS default).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO_ROOT/scripts/lib/moat-archive.sh"

fail() { echo "✘ test-moat-archive-retention: FAIL — $1"; exit 1; }

# --- Case A: keep newest 10 of 15 (aligned name+mtime) ----------------------
arc="$(mktemp -d -t leaf-moat-retention.XXXXXX)"
trap 'rm -rf "$arc"' EXIT

i=1
while [ "$i" -le 15 ]; do
  d="$arc/autobackup-$(printf '%05d' "$i")"
  mkdir -p "$d"
  touch -t "202606010000.$(printf '%02d' "$i")" "$d"   # strictly increasing mtime
  i=$((i + 1))
done

leaf_moat_gc_autobackups "$arc" 10

remaining=$(find "$arc" -maxdepth 1 -type d -name '*autobackup-*' | wc -l | tr -d ' ')
[ "$remaining" -eq 10 ] || fail "expected 10 dirs after GC, got $remaining"
[ -d "$arc/autobackup-00015" ]  || fail "newest (00015) was deleted"
[ -d "$arc/autobackup-00006" ]  || fail "keep-boundary (00006) should remain"
[ ! -d "$arc/autobackup-00005" ] || fail "drop-boundary (00005) should be gone"
[ ! -d "$arc/autobackup-00001" ] || fail "oldest (00001) was NOT deleted"

# --- Case B: MTIME governs, not name (push-* sorts last lexically) ----------
arc2="$(mktemp -d -t leaf-moat-retention2.XXXXXX)"
trap 'rm -rf "$arc" "$arc2"' EXIT
mkdir -p "$arc2/autobackup-newer" "$arc2/autobackup-middle" "$arc2/push-autobackup-zzz"
touch -t 202606011200.00 "$arc2/autobackup-newer"
touch -t 202606011100.00 "$arc2/autobackup-middle"
touch -t 202606010900.00 "$arc2/push-autobackup-zzz"   # OLDEST mtime, name sorts LAST

leaf_moat_gc_autobackups "$arc2" 2

[ -d "$arc2/autobackup-newer" ]   || fail "Case B: newest-by-mtime deleted"
[ -d "$arc2/autobackup-middle" ]  || fail "Case B: middle-by-mtime deleted"
[ ! -d "$arc2/push-autobackup-zzz" ] || fail "Case B: oldest-by-mtime survived — GC sorted by name, not mtime"

# --- Case C: keep >= count is a no-op ---------------------------------------
arc3="$(mktemp -d -t leaf-moat-retention3.XXXXXX)"
trap 'rm -rf "$arc" "$arc2" "$arc3"' EXIT
mkdir -p "$arc3/autobackup-x" "$arc3/autobackup-y"
leaf_moat_gc_autobackups "$arc3" 10
[ -d "$arc3/autobackup-x" ] && [ -d "$arc3/autobackup-y" ] || fail "Case C: deleted dirs when under keep limit"

echo "✓ test-moat-archive-retention: GC keeps newest N by mtime across both prefixes."
