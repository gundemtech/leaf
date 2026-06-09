#!/usr/bin/env bash
# test-derive-version.sh — fixture-based self-test for derive-version.sh.
#
# Feeds controlled tag-lists via LEAF_DERIVE_TAGS and asserts the derived
# "latest shipped version" (grep ^v filter + sort -V + strict form-assert).
# Proves the ^v filter is load-bearing — a junk tag that sorts ABOVE the v-tags
# (a letter w..z byte-orders after 'v') must be filtered out before tail-1.
# Without the grep such a tag wins sort -V, trips the form-assert, and would
# FALSELY halt a release that has a perfectly good v-tag. Also covers prefixless
# rejection and a malformed highest v-tag failing loud rather than deriving from
# a lower valid one. (The real junk tags archive/*, phase-2-done, prefixless
# 1.0.0-* all byte-order BELOW 'v', so a fixture must use a w..z decoy to make
# the grep's protection observable.)
#
# All cases rely on unambiguous sort -V behaviour (numeric alpha.N ordering,
# major-version ordering, the ^v grep filter, the form regex) that is identical
# on BSD sort (macOS, where release.sh runs) and GNU sort (ubuntu CI). The
# bare-GA-vs-prerelease ordering — the one spot the two could diverge — is left
# as a documented NB in derive-version.sh, never asserted here.
# Bash 3.2 compatible (macOS default + ubuntu CI).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/derive-version.sh"
pass=0; fail=0

# expect_out <label> <expected-stdout> <tags-newline-separated>
expect_out() {
    local label="$1" want="$2" tags="$3" got rc
    set +e
    got="$(LEAF_DERIVE_TAGS="$tags" "$SCRIPT" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 && "$got" == "$want" ]]; then
        echo "  ✓ $label"; pass=$((pass + 1))
    else
        echo "  ✘ $label (rc=$rc, got='$got', want='$want')"; fail=$((fail + 1))
    fi
}

# expect_fail <label> <tags-newline-separated>
expect_fail() {
    local label="$1" tags="$2" rc
    set +e
    LEAF_DERIVE_TAGS="$tags" "$SCRIPT" >/dev/null 2>&1
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "  ✓ $label"; pass=$((pass + 1))
    else
        echo "  ✘ $label (expected non-zero exit, got 0)"; fail=$((fail + 1))
    fi
}

# Realistic messy set (mirrors the live repo: junk + prefixless + v-tags).
REAL='1.0.0-alpha.6
archive/code-style-foundation
dev-track7-source
integration-T10-phase-II-close
phase-2-done
v1.0.0-alpha.16
v1.0.0-alpha.23
v1.0.0-alpha.29
v1.0.0-alpha.30'
expect_out "messy real set → v1.0.0-alpha.30" "v1.0.0-alpha.30" "$REAL"

# Numeric (not lexical) alpha ordering: alpha.9 must NOT beat alpha.28.
expect_out "numeric alpha ordering (28 > 9)" "v1.0.0-alpha.28" 'v1.0.0-alpha.9
v1.0.0-alpha.28'

# Filter is load-bearing: a junk tag that sorts ABOVE the v-tags (letters w..z
# byte-order after 'v') must be filtered out, NOT win tail-1. Without the ^v
# grep, 'zz-snapshot' wins sort -V, then trips the form-assert and falsely halts
# the release even though v1.0.0-alpha.30 is right there. This case flips
# pass→fail if the grep is ever removed.
expect_out "junk tag sorting above v excluded → v1.0.0-alpha.30" "v1.0.0-alpha.30" 'v1.0.0-alpha.30
wip-release
zz-snapshot'

# Prefixless version-shaped tags (1.0.0-alpha.N, no leading v) are not accepted
# as shipped versions — a prefixless-only set yields nothing and fails loud.
expect_fail "prefixless-only set fails (no v-prefix accepted)" '1.0.0-alpha.6
1.0.0-alpha.99'

# Junk-only (no valid v-tag) → fail loud.
expect_fail "junk-only set fails" 'phase-2-done
archive/foo
dev-track7-source'

# Empty tag set → fail loud.
expect_fail "empty tag set fails" ''

# Malformed highest v-tag (passes ^v grep, fails strict form) → fail loud,
# NOT silently derive from a lower valid tag. v2.0 outranks v1.0.0-alpha.30
# on both BSD and GNU sort (major 2 > 1, no prerelease subtlety).
expect_fail "malformed highest v-tag (v2.0) fails" 'v1.0.0-alpha.30
v2.0'

echo "derive-version self-test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
