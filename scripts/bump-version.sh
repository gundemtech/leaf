#!/usr/bin/env bash
# bump-version.sh — set the app version across the whole Xcode pbxproj in one shot.
#
# The PREP step of /release-leaf (Phase 2): before a build is archived the
# project must carry the new version in EVERY build-config slot. The real
# project.pbxproj holds MARKETING_VERSION + CURRENT_PROJECT_VERSION six times
# each (per build config). A hand-bump that misses a slot ships an inconsistent
# CFBundleVersion silently — Xcode's Release-only "Version" field shows one
# value, the half-bumped pbxproj another. So this rewrites all of them, then
# asserts every slot took the new value and exactly one distinct value remains.
#
# Build number: CURRENT_PROJECT_VERSION is an integer, derived from the alpha
# component — 1.0.0-alpha.N → N. Only the X.Y.Z-alpha.N form is accepted; a bare
# GA X.Y.Z is rejected (it has no alpha.N to map to a monotonic integer build —
# revisit this derivation at the GA cutover). Fail loud rather than guess.
#
# Idempotent: re-running with the same version is a no-op that still passes the
# asserts, so /release-leaf can skip-or-bump without branching.
#
# Test seam (mirrors derive-version.sh's LEAF_DERIVE_TAGS): LEAF_PBXPROJ overrides
# the file edited, so scripts/tests/test-bump-version.sh works on a fixture copy
# and never touches the real project.
# Bash 3.2 compatible (macOS default + ubuntu CI).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="${LEAF_PBXPROJ:-$REPO_ROOT/Leaf.xcodeproj/project.pbxproj}"

fail() { echo "✘ bump-version: $1" >&2; exit 1; }

VERSION="${1:-}"
[[ -n "$VERSION" ]] || fail "usage: bump-version.sh <version>   (e.g. 1.0.0-alpha.31)"
[[ -f "$PBXPROJ" ]] || fail "pbxproj not found: $PBXPROJ"

# Accept only X.Y.Z-alpha.N; capture N as the integer build. Bare GA (X.Y.Z) and
# anything else fail loud (see header).
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha\.([0-9]+)$ ]]; then
    BUILD="${BASH_REMATCH[1]}"
else
    fail "unrecognized version form '$VERSION' (expected X.Y.Z-alpha.N; bare GA X.Y.Z not yet supported — extend bump-version.sh at the GA cutover)"
fi

# Pre-edit counts: every slot must still carry the new value afterwards. `grep -c`
# exits 1 (prints 0) on no match — `|| true` keeps the count, the >=1 assert below
# rejects an empty/foreign pbxproj.
mv_count="$(grep -c 'MARKETING_VERSION = ' "$PBXPROJ" || true)"
cpv_count="$(grep -c 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" || true)"
[[ "$mv_count" -ge 1 ]] || fail "no MARKETING_VERSION entries in $PBXPROJ — wrong file?"
[[ "$cpv_count" -ge 1 ]] || fail "no CURRENT_PROJECT_VERSION entries in $PBXPROJ — wrong file?"

# Rewrite via a temp file (no `sed -i` — its in-place flag differs BSD vs GNU).
# MARKETING_VERSION is always quoted; CURRENT_PROJECT_VERSION is a bare integer.
tmp="$(mktemp)"
sed -E \
    -e "s/MARKETING_VERSION = \"[^\"]*\";/MARKETING_VERSION = \"$VERSION\";/g" \
    -e "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/g" \
    "$PBXPROJ" > "$tmp"
mv "$tmp" "$PBXPROJ"

# Post-edit: every counted slot took the new value (catches a slot the sed could
# not match — e.g. an unquoted MARKETING_VERSION left by a hand-edit → 5 of 6).
new_mv="$(grep -c "MARKETING_VERSION = \"$VERSION\";" "$PBXPROJ" || true)"
new_cpv="$(grep -c "CURRENT_PROJECT_VERSION = $BUILD;" "$PBXPROJ" || true)"
[[ "$new_mv" -eq "$mv_count" ]] || fail "MARKETING_VERSION bump incomplete: $new_mv/$mv_count now '$VERSION' (partial bump — fix the stray slot)"
[[ "$new_cpv" -eq "$cpv_count" ]] || fail "CURRENT_PROJECT_VERSION bump incomplete: $new_cpv/$cpv_count now $BUILD (partial bump — fix the stray slot)"

# Belt-and-suspenders: exactly one distinct value per key (a stray slot at a
# different value leaves two distinct values even if the count somehow matched).
distinct_mv="$(grep -oE 'MARKETING_VERSION = "[^"]*";' "$PBXPROJ" | sort -u | wc -l | tr -d ' ')"
distinct_cpv="$(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | sort -u | wc -l | tr -d ' ')"
[[ "$distinct_mv" -eq 1 ]] || fail "MARKETING_VERSION has $distinct_mv distinct values after bump (expected 1)"
[[ "$distinct_cpv" -eq 1 ]] || fail "CURRENT_PROJECT_VERSION has $distinct_cpv distinct values after bump (expected 1)"

echo "✓ bump-version: MARKETING_VERSION → $VERSION (×$mv_count), CURRENT_PROJECT_VERSION → $BUILD (×$cpv_count)"
