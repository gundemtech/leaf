#!/usr/bin/env bash
# test-bump-version.sh — fixture-based self-test for bump-version.sh.
#
# bump-version.sh rewrites every MARKETING_VERSION + CURRENT_PROJECT_VERSION in
# the Xcode pbxproj in one shot. The danger it guards against is a PARTIAL bump
# (e.g. 5 of 6 slots updated) — Xcode's Release-only version is one value, but
# the pbxproj carries the marketing/build version in six build-config slots, and
# a half-bumped project ships an inconsistent CFBundleVersion. So the asserts
# under test are: every slot took the new value (count match) AND exactly one
# distinct value remains for each key.
#
# All edits target a fixture copy via LEAF_PBXPROJ — the real project.pbxproj is
# never touched. Fixtures are PUBLIC-SAFE (leak-guard name-scans scripts/tests/*):
# no real names, no Developer-ID-shaped signing identity literals.
# Bash 3.2 compatible (macOS default + ubuntu CI).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/bump-version.sh"
pass=0; fail=0

check() {  # check <label> <condition-rc> — rc 0 = pass
    local label="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then echo "  ✓ $label"; pass=$((pass + 1));
    else echo "  ✘ $label"; fail=$((fail + 1)); fi
}

WORK="$(mktemp -d -t leaf-bump.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# A minimal pbxproj-shaped fixture: six build configs, each carrying both keys at
# the same starting version (mirrors the real project's ×6 layout). bump-version
# only greps/seds these two keys, so the surrounding structure can be skeletal.
make_fixture() {  # make_fixture <out-path>
    cat > "$1" <<'EOF'
// !$*UTF8*$!
{
	objects = {
		A1 /* Debug */ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = "1.0.0-alpha.30"; };
		A2 /* Release */ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = "1.0.0-alpha.30"; };
		B1 /* Debug */ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = "1.0.0-alpha.30"; };
		B2 /* Release */ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = "1.0.0-alpha.30"; };
		C1 /* Debug */ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = "1.0.0-alpha.30"; };
		C2 /* Release */ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = "1.0.0-alpha.30"; };
	};
}
EOF
}

# --- happy path: bump alpha.30 → alpha.31 ---------------------------------
PBX="$WORK/happy.pbxproj"; make_fixture "$PBX"
set +e
LEAF_PBXPROJ="$PBX" "$SCRIPT" 1.0.0-alpha.31 >/dev/null 2>&1
rc=$?
set -e
check "happy bump exits 0" "$rc"
[[ "$(grep -c 'MARKETING_VERSION = "1.0.0-alpha.31";' "$PBX")" -eq 6 ]]
check "all 6 MARKETING_VERSION → 1.0.0-alpha.31" $?
[[ "$(grep -c 'CURRENT_PROJECT_VERSION = 31;' "$PBX")" -eq 6 ]]
check "all 6 CURRENT_PROJECT_VERSION → 31 (build = alpha N)" $?
[[ "$(grep -c 'MARKETING_VERSION = "1.0.0-alpha.30";' "$PBX")" -eq 0 ]]
check "no stale MARKETING_VERSION left" $?
[[ "$(grep -c 'CURRENT_PROJECT_VERSION = 30;' "$PBX")" -eq 0 ]]
check "no stale CURRENT_PROJECT_VERSION left" $?

# --- idempotent: re-bump to the same version stays green ------------------
set +e
LEAF_PBXPROJ="$PBX" "$SCRIPT" 1.0.0-alpha.31 >/dev/null 2>&1
rc=$?
set -e
check "re-bump to same version idempotent (exits 0)" "$rc"
[[ "$(grep -c 'MARKETING_VERSION = "1.0.0-alpha.31";' "$PBX")" -eq 6 ]]
check "still 6 MARKETING_VERSION after re-bump" $?

# --- partial-bump detection ------------------------------------------------
# A hand-edit that left one MARKETING_VERSION slot unquoted: the line still
# counts as a MARKETING_VERSION entry (so the pre-edit count is 6) but the
# quoted-value sed can't touch it, so post-edit only 5 of 6 carry the new value
# → the count-match assert must fail loud rather than ship a half-bumped project.
PBX2="$WORK/partial.pbxproj"; make_fixture "$PBX2"
# Break one slot: drop the quotes so sed's "[^"]*" pattern skips it.
sed 's/C2 \/\* Release \*\/ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = "1.0.0-alpha.30"; }/C2 \/\* Release \*\/ = { CURRENT_PROJECT_VERSION = 30; MARKETING_VERSION = 1.0.0-alpha.30; }/' "$PBX2" > "$PBX2.tmp" && mv "$PBX2.tmp" "$PBX2"
set +e
LEAF_PBXPROJ="$PBX2" "$SCRIPT" 1.0.0-alpha.31 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "partial bump (one slot sed can't touch) fails loud" $?

# --- form rejection --------------------------------------------------------
PBX3="$WORK/form.pbxproj"; make_fixture "$PBX3"
set +e
LEAF_PBXPROJ="$PBX3" "$SCRIPT" 1.0.0 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "bare GA version (1.0.0) rejected — out of scope, fail loud" $?
# Fixture untouched after a rejected bump (fails before writing).
[[ "$(grep -c 'MARKETING_VERSION = "1.0.0-alpha.30";' "$PBX3")" -eq 6 ]]
check "rejected GA bump leaves pbxproj untouched" $?

set +e
LEAF_PBXPROJ="$PBX3" "$SCRIPT" "not-a-version" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "garbage version string rejected" $?

set +e
LEAF_PBXPROJ="$PBX3" "$SCRIPT" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "no-arg invocation fails (usage)" $?

# --- double-digit build number maps correctly -----------------------------
PBX4="$WORK/bigN.pbxproj"; make_fixture "$PBX4"
set +e
LEAF_PBXPROJ="$PBX4" "$SCRIPT" 1.0.0-alpha.128 >/dev/null 2>&1
rc=$?
set -e
check "bump to alpha.128 exits 0" "$rc"
[[ "$(grep -c 'CURRENT_PROJECT_VERSION = 128;' "$PBX4")" -eq 6 ]]
check "three-digit build number (128) applied to all 6" $?

# --- missing pbxproj fails loud --------------------------------------------
set +e
LEAF_PBXPROJ="$WORK/does-not-exist.pbxproj" "$SCRIPT" 1.0.0-alpha.31 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "missing pbxproj fails loud" $?

echo "bump-version self-test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
