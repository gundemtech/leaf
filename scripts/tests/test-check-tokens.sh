#!/usr/bin/env bash
# Track 2 / D1+D2 — fixture-based test for scripts/check-tokens.sh.
# Spawns a tmp scope-tree (BASE + MIGRATION + file-level), drops good/bad
# files, runs the guard, asserts exit code. Cleans up via trap.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_ROOT}/scripts/check-tokens.sh"

assert_pass() {
    local label="$1"
    if "$GUARD" >/dev/null 2>&1; then
        echo "  ✓ pass: $label"
    else
        echo "  ✘ FAIL (expected pass): $label"
        "$GUARD" || true
        exit 1
    fi
}

assert_fail() {
    local label="$1"
    if "$GUARD" >/dev/null 2>&1; then
        echo "  ✘ FAIL (expected fail): $label"
        exit 1
    else
        echo "  ✓ fail-as-expected: $label"
    fi
}

assert_pass_with_extra() {
    local label="$1"
    local extras="$2"
    if LEAF_CHECK_TOKENS_EXTRA_FILES="$extras" "$GUARD" >/dev/null 2>&1; then
        echo "  ✓ pass: $label"
    else
        echo "  ✘ FAIL (expected pass): $label"
        LEAF_CHECK_TOKENS_EXTRA_FILES="$extras" "$GUARD" || true
        exit 1
    fi
}

assert_fail_with_extra() {
    local label="$1"
    local extras="$2"
    if LEAF_CHECK_TOKENS_EXTRA_FILES="$extras" "$GUARD" >/dev/null 2>&1; then
        echo "  ✘ FAIL (expected fail): $label"
        exit 1
    else
        echo "  ✓ fail-as-expected: $label"
    fi
}

TMP=$(mktemp -d)
FIXTURE_DIR_BASE="${REPO_ROOT}/Leaf/Theme/__test_fixture__"
FIXTURE_DIR_MIGR="${REPO_ROOT}/Leaf/Views/Window/Home/__test_fixture__"
FIXTURE_FILE_LEVEL="${TMP}/__test_fixture_root_view__.swift"

FIXTURE_ACTIVITY_DIR="${REPO_ROOT}/Leaf/Views/Window/Activity"
FIXTURE_CONNECTIONS_DIR="${REPO_ROOT}/Leaf/Views/Window/Connections"

trap 'rm -rf "$TMP" "$FIXTURE_DIR_BASE" "$FIXTURE_DIR_MIGR"; rm -f "$FIXTURE_ACTIVITY_DIR"/__fixture_*.swift "$FIXTURE_CONNECTIONS_DIR"/__fixture_*.swift' EXIT

mkdir -p "$FIXTURE_DIR_BASE"
mkdir -p "$FIXTURE_DIR_MIGR"

# Case 1 — empty fixtures pass.
assert_pass "empty fixtures"

# Case 2 — clean swift in BASE scope passes.
cat > "${FIXTURE_DIR_BASE}/Clean.swift" <<'EOF'
import SwiftUI
struct Clean: View {
    var body: some View {
        Text("hi")
            .foregroundStyle(LeafColor.text.primary)
            .padding(LeafSpace.lg)
    }
}
EOF
assert_pass "clean BASE swift"

# Case 3 — raw Color(red:...) in BASE fails.
cat > "${FIXTURE_DIR_BASE}/Raw.swift" <<'EOF'
import SwiftUI
let bad = Color(red: 0.5, green: 0.5, blue: 0.5)
EOF
assert_fail "raw Color(red:) in BASE"
rm "${FIXTURE_DIR_BASE}/Raw.swift"

# Case 4 — raw .padding(<int>) in BASE fails.
cat > "${FIXTURE_DIR_BASE}/Pad.swift" <<'EOF'
import SwiftUI
struct X: View { var body: some View { Text("x").padding(12) } }
EOF
assert_fail "raw .padding(12) in BASE"
rm "${FIXTURE_DIR_BASE}/Pad.swift"

# Case 5 — raw cornerRadius in BASE fails (regression for existing rule).
cat > "${FIXTURE_DIR_BASE}/Corner.swift" <<'EOF'
import SwiftUI
struct Y: View { var body: some View { Rectangle().cornerRadius(8) } }
EOF
assert_fail "raw cornerRadius:8 in BASE"
rm "${FIXTURE_DIR_BASE}/Corner.swift"

# Case 6 — RoundedRectangle(cornerRadius: <int>) in BASE fails.
cat > "${FIXTURE_DIR_BASE}/Rect.swift" <<'EOF'
import SwiftUI
let r = RoundedRectangle(cornerRadius: 16)
EOF
assert_fail "raw RoundedRectangle(cornerRadius: 16) in BASE"
rm "${FIXTURE_DIR_BASE}/Rect.swift"

# Case 7 — old-palette ref `.leafBody` in BASE PASSES (BASE allows palette).
cat > "${FIXTURE_DIR_BASE}/OldPaletteOK.swift" <<'EOF'
import SwiftUI
let f = Font.leafBody
EOF
assert_pass "old-palette ref allowed in BASE"
rm "${FIXTURE_DIR_BASE}/OldPaletteOK.swift"

# Case 8 — old-palette ref `.leafBody` in MIGRATION dir FAILS.
cat > "${FIXTURE_DIR_MIGR}/OldPaletteBad.swift" <<'EOF'
import SwiftUI
struct Bad: View { var body: some View { Text("hi").font(.leafBody) } }
EOF
assert_fail "old-palette ref forbidden in MIGRATION dir"
rm "${FIXTURE_DIR_MIGR}/OldPaletteBad.swift"

# Case 9 — GlassCard wrapper in MIGRATION dir FAILS.
cat > "${FIXTURE_DIR_MIGR}/GlassCardBad.swift" <<'EOF'
import SwiftUI
struct Bad: View { var body: some View { GlassCard { Text("x") } } }
EOF
assert_fail "GlassCard wrapper forbidden in MIGRATION dir"
rm "${FIXTURE_DIR_MIGR}/GlassCardBad.swift"

# Case 10 — clean migrated swift in MIGRATION dir passes.
cat > "${FIXTURE_DIR_MIGR}/CleanMigr.swift" <<'EOF'
import SwiftUI
struct Clean: View {
    var body: some View {
        Text("hi")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
            .padding(LeafSpace.lg)
    }
}
EOF
assert_pass "clean MIGRATION swift"
rm "${FIXTURE_DIR_MIGR}/CleanMigr.swift"

# Case 11 — file-level scope: clean fixture file via env override passes.
cat > "$FIXTURE_FILE_LEVEL" <<'EOF'
import SwiftUI
struct CleanFile: View {
    var body: some View {
        Text("hi")
            .padding(LeafSpace.lg)
            .foregroundStyle(LeafColor.text.primary)
    }
}
EOF
assert_pass_with_extra "file-level scope (clean)" "$FIXTURE_FILE_LEVEL"

# Case 12 — file-level scope: raw .padding(<int>) in fixture file fails.
cat > "$FIXTURE_FILE_LEVEL" <<'EOF'
import SwiftUI
struct BadFile: View {
    var body: some View {
        Text("hi").padding(40)
    }
}
EOF
assert_fail_with_extra "file-level scope (raw .padding)" "$FIXTURE_FILE_LEVEL"

# Case 13 — file-level scope: old-palette ref in fixture file fails.
cat > "$FIXTURE_FILE_LEVEL" <<'EOF'
import SwiftUI
struct BadFile: View { var body: some View { Text("hi").font(.leafBody) } }
EOF
assert_fail_with_extra "file-level scope (old-palette)" "$FIXTURE_FILE_LEVEL"

# === Track 2 / D3 — additional MIGRATION fixtures ===
#
# Verify the new MIGRATION paths from D3 are actually iterated:
#   • Activity dir (dir-level scope)
#   • Team file-level (TeamView.swift) — sheets in same dir must NOT
#     fail when they keep old-palette refs
#   • Connections dir (dir-level scope)

# Case 14 — Activity MIGRATION dir: clean migrated swift passes.
FIXTURE_ACTIVITY="${FIXTURE_ACTIVITY_DIR}/__fixture_clean_d3.swift"
cat > "$FIXTURE_ACTIVITY" <<'EOF'
import SwiftUI
struct CleanActivity: View {
    var body: some View {
        Text("hi")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.primary)
            .padding(LeafSpace.lg)
    }
}
EOF
assert_pass "clean Activity MIGRATION swift"
rm "$FIXTURE_ACTIVITY"

# Case 15 — Activity MIGRATION dir: old-palette ref triggers fail.
FIXTURE_ACTIVITY="${FIXTURE_ACTIVITY_DIR}/__fixture_bad_d3.swift"
cat > "$FIXTURE_ACTIVITY" <<'EOF'
import SwiftUI
struct BadActivity: View { var body: some View { Text("x").font(.leafBody) } }
EOF
assert_fail "old-palette ref in Activity MIGRATION dir"
rm "$FIXTURE_ACTIVITY"

# Case 16 — Team file-level scope: TeamView.swift listed file fails on old-palette.
# (Real TeamView.swift is migrated; reuse the env override mechanism with a
# fresh tmp file standing in for any file already listed in MIGRATION_PATHS.)
cat > "$FIXTURE_FILE_LEVEL" <<'EOF'
import SwiftUI
struct BadTeam: View { var body: some View { GlassCard { Text("x") } } }
EOF
assert_fail_with_extra "Team file-level scope (GlassCard)" "$FIXTURE_FILE_LEVEL"

# Case 17 — Connections MIGRATION dir: clean passes.
FIXTURE_CONN="${FIXTURE_CONNECTIONS_DIR}/__fixture_clean_d3.swift"
cat > "$FIXTURE_CONN" <<'EOF'
import SwiftUI
struct CleanConnections: View {
    var body: some View {
        VStack(spacing: LeafSpace.md) {
            Text("hi").font(LeafType.title.small)
        }
        .padding(LeafSpace.lg)
    }
}
EOF
assert_pass "clean Connections MIGRATION swift"
rm "$FIXTURE_CONN"

echo "All fixture cases passed."
