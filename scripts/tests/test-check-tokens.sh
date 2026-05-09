#!/usr/bin/env bash
# Track 2 / D1 — fixture-based test for scripts/check-tokens.sh.
# Spawns a tmp scope-tree, drops good/bad files, runs the guard, asserts exit code.
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

# Test workspace — replace SCOPE_DIRS contents temporarily.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -rf "${REPO_ROOT}/Leaf/Theme/__test_fixture__" "${REPO_ROOT}/Leaf/Views/Tokens/__test_fixture__"' EXIT

mkdir -p "${REPO_ROOT}/Leaf/Theme/__test_fixture__"
mkdir -p "${REPO_ROOT}/Leaf/Views/Tokens/__test_fixture__"

# Case 1 — empty scope passes.
assert_pass "empty fixture"

# Case 2 — clean swift code passes.
cat > "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Clean.swift" <<'EOF'
import SwiftUI
struct Clean: View {
    var body: some View {
        Text("hi")
            .foregroundStyle(LeafColor.text.primary)
            .padding(LeafSpace.lg)
    }
}
EOF
assert_pass "clean swift"

# Case 3 — raw Color(red:...) fails.
cat > "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Raw.swift" <<'EOF'
import SwiftUI
let bad = Color(red: 0.5, green: 0.5, blue: 0.5)
EOF
assert_fail "raw Color(red:)"
rm "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Raw.swift"

# Case 4 — raw .padding(<int>) fails.
cat > "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Pad.swift" <<'EOF'
import SwiftUI
struct X: View { var body: some View { Text("x").padding(12) } }
EOF
assert_fail "raw .padding(12)"
rm "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Pad.swift"

# Case 5 — raw cornerRadius fails.
cat > "${REPO_ROOT}/Leaf/Views/Tokens/__test_fixture__/Corner.swift" <<'EOF'
import SwiftUI
struct Y: View { var body: some View { Rectangle().cornerRadius(8) } }
EOF
assert_fail "raw cornerRadius:8"
rm "${REPO_ROOT}/Leaf/Views/Tokens/__test_fixture__/Corner.swift"

# Case 6 — RoundedRectangle(cornerRadius: <int>) fails.
cat > "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Rect.swift" <<'EOF'
import SwiftUI
let r = RoundedRectangle(cornerRadius: 16)
EOF
assert_fail "raw RoundedRectangle(cornerRadius: 16)"
rm "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Rect.swift"

# Case 7 — file with LeafColor.* token reference passes (regression).
cat > "${REPO_ROOT}/Leaf/Theme/__test_fixture__/Token.swift" <<'EOF'
import SwiftUI
let surface = LeafColor.surface.canvas
let pad: CGFloat = LeafSpace.lg
let r: CGFloat = LeafRadius.md
EOF
assert_pass "tokenized swift"

echo "All fixture cases passed."
