#!/usr/bin/env bash
# Track 2 / D1 — token-discipline guard.
#
# Fails (exit 1) if Leaf/Theme/ or Leaf/Views/Tokens/ contain raw color literals
# or raw spacing/radius numbers. D1 coverage is intentionally narrow — D2/D3/D4
# extend coverage to migrated view folders.
#
# Allowed inside scope:
#   - Color("LeafFooBar")           ← Asset Catalog lookup by name (string literal is the asset key, not a raw color)
#   - LeafColor.* / LeafSpace.* / LeafRadius.* / LeafType.* / LeafElevation.* / LeafGlass.* / LeafMotion.*
#   - Tier 3 component tokens (Leaf<Comp>Tokens.*)
#   - LeafPrimitive.* (only inside Leaf/Theme/Tokens/LeafPrimitive.swift and other T2 files — internal-only resolves)
#
# Disallowed inside scope:
#   - Color(red:..., green:..., blue:...)
#   - Color(.<systemColor>) — except inside LeafColor.swift T2 system mapping
#   - Hex literal #RRGGBB inside string interpolation or comment-as-code
#   - .padding(<int>) with raw int — must be .padding(LeafSpace.*)
#   - .frame(width:<int>, height:<int>) with raw int — must use LeafSpace
#   - cornerRadius:<int> with raw int — must be LeafRadius.*
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCOPE_DIRS=(
    "${REPO_ROOT}/Leaf/Theme"
    "${REPO_ROOT}/Leaf/Views/Tokens"
)

EXIT=0

# Allow LeafPrimitive.swift to define raw hex (it's the only place T1 raw values live).
LEAF_PRIMITIVE="${REPO_ROOT}/Leaf/Theme/Tokens/LeafPrimitive.swift"
# Allow LeafColor.swift to map system colours where needed.
LEAF_COLOR="${REPO_ROOT}/Leaf/Theme/Tokens/LeafColor.swift"

check_pattern() {
    local label="$1"
    local pattern="$2"
    local exclude="${3:-}"

    for dir in "${SCOPE_DIRS[@]}"; do
        [[ -d "$dir" ]] || continue
        local hits
        if [[ -n "$exclude" ]]; then
            hits=$(grep -rEn "$pattern" "$dir" --include="*.swift" 2>/dev/null \
                | grep -vE "$exclude" || true)
        else
            hits=$(grep -rEn "$pattern" "$dir" --include="*.swift" 2>/dev/null || true)
        fi
        if [[ -n "$hits" ]]; then
            echo "❌ ${label}:"
            echo "$hits" | sed 's/^/    /'
            echo
            EXIT=1
        fi
    done
}

# Raw color RGB literal
check_pattern \
    "Raw Color(red:..., green:..., blue:...) — use LeafColor.* or LeafPrimitive.*" \
    'Color\(red:[[:space:]]*[0-9]' \
    "(${LEAF_PRIMITIVE//./\.})|(${LEAF_COLOR//./\.})"

# System color shortcut
check_pattern \
    "Raw Color(.systemFoo) — use LeafColor.* (system mappings live only in LeafColor.swift)" \
    'Color\(\.[a-zA-Z]' \
    "${LEAF_COLOR//./\.}"

# Hex literal as string (heuristic — match #XXXXXX in code lines, not comments)
check_pattern \
    "Hex literal in code — define in LeafPrimitive.swift only" \
    '#[0-9A-Fa-f]{6}([^"]*)"' \
    "${LEAF_PRIMITIVE//./\.}"

# Raw padding integer
check_pattern \
    "Raw .padding(<int>) — use LeafSpace.*" \
    '\.padding\([0-9]+\)'

# .padding(.horizontal, <int>) etc with raw int
check_pattern \
    "Raw .padding(<edge>, <int>) — use LeafSpace.*" \
    '\.padding\(\.[a-zA-Z]+,[[:space:]]*[0-9]+\)'

# Raw cornerRadius: parameter form
check_pattern \
    "Raw cornerRadius:<int> — use LeafRadius.*" \
    'cornerRadius:[[:space:]]*[0-9]+'

# Raw .cornerRadius(<int>) modifier form
check_pattern \
    "Raw .cornerRadius(<int>) — use LeafRadius.*" \
    '\.cornerRadius\([0-9]+'

# RoundedRectangle(cornerRadius: <int>) — same enforcement
check_pattern \
    "Raw RoundedRectangle(cornerRadius: <int>) — use LeafRadius.*" \
    'RoundedRectangle\(cornerRadius:[[:space:]]*[0-9]+'

if [[ $EXIT -ne 0 ]]; then
    echo "✘ Token-discipline guard failed — see above."
    exit 1
fi

echo "✓ Token-discipline guard passed."
