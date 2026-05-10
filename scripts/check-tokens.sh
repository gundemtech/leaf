#!/usr/bin/env bash
# Track 2 / D1+D2 — token-discipline guard.
#
# Two-tier scope (Track 2 / D2+D3 extension):
#   • BASE scope        — Leaf/Theme/ + Leaf/Views/Tokens/. Bans raw
#     colors, raw padding ints, raw cornerRadius ints. Does NOT ban
#     old-palette references because the palette itself is defined here.
#   • MIGRATION scope   — D2: Leaf/Views/Window/Home/ + RootView.swift +
#     Sidebar.swift. D3: + Leaf/Views/Window/Activity/ + Team/TeamView.swift
#     + Team/PendingInvitesSection.swift + Team/PendingInviteRow.swift +
#     Leaf/Views/Window/Connections/. Inherits BASE checks AND
#     additionally bans old-palette references. Formalises 'migrated
#     file = zero old-palette refs'. Sheets (GenerateInviteSheet,
#     RemoveMemberSheet) deliberately excluded — D4 carry-over.
#
# Allowed inside scope (any tier):
#   - Color("LeafFooBar")           ← Asset Catalog lookup
#   - LeafColor.* / LeafSpace.* / LeafRadius.* / LeafType.* /
#     LeafElevation.* / LeafGlass.* / LeafMotion.*
#   - Tier 3 component tokens (Leaf<Comp>Tokens.*)
#
# Bash 3.2 compatible — no namerefs. Paths arrive as positional args.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---- Tier 1: BASE scope (T2 tokens / T3 component tokens) ----
BASE_PATHS=(
    "${REPO_ROOT}/Leaf/Theme"
    "${REPO_ROOT}/Leaf/Views/Tokens"
)

# ---- Tier 2: MIGRATION scope (D2-migrated app views) ----
MIGRATION_PATHS=(
    "${REPO_ROOT}/Leaf/Views/Window/Home"
    "${REPO_ROOT}/Leaf/Views/Window/RootView.swift"
    "${REPO_ROOT}/Leaf/Views/Window/Sidebar.swift"
    # Track 2 / D3 additions:
    "${REPO_ROOT}/Leaf/Views/Window/Activity"
    "${REPO_ROOT}/Leaf/Views/Window/Team/TeamView.swift"
    "${REPO_ROOT}/Leaf/Views/Window/Team/PendingInvitesSection.swift"
    "${REPO_ROOT}/Leaf/Views/Window/Team/PendingInviteRow.swift"
    "${REPO_ROOT}/Leaf/Views/Window/Connections"
)

# Optional self-test override: append extra paths via env var.
# Self-test sets LEAF_CHECK_TOKENS_EXTRA_FILES to a colon-separated list.
if [[ -n "${LEAF_CHECK_TOKENS_EXTRA_FILES:-}" ]]; then
    IFS=':' read -ra EXTRA <<< "$LEAF_CHECK_TOKENS_EXTRA_FILES"
    for p in "${EXTRA[@]}"; do
        MIGRATION_PATHS+=("$p")
    done
fi

EXIT=0
LEAF_PRIMITIVE="${REPO_ROOT}/Leaf/Theme/Tokens/LeafPrimitive.swift"
LEAF_COLOR="${REPO_ROOT}/Leaf/Theme/Tokens/LeafColor.swift"

# Iterate over remaining positional args; each can be either dir or file.
# Args: <label> <pattern> <exclude-regex> <path1> [<path2> ...]
check_pattern_in_paths() {
    local label="$1"
    local pattern="$2"
    local exclude="$3"
    shift 3

    local hits=""
    for path in "$@"; do
        local out=""
        if [[ -d "$path" ]]; then
            if [[ -n "$exclude" ]]; then
                out=$(grep -rEn "$pattern" "$path" --include="*.swift" 2>/dev/null \
                    | grep -vE "$exclude" || true)
            else
                out=$(grep -rEn "$pattern" "$path" --include="*.swift" 2>/dev/null || true)
            fi
        elif [[ -f "$path" ]]; then
            if [[ -n "$exclude" ]]; then
                out=$(grep -En "$pattern" "$path" 2>/dev/null \
                    | sed "s|^|${path}:|" \
                    | grep -vE "$exclude" || true)
            else
                out=$(grep -En "$pattern" "$path" 2>/dev/null \
                    | sed "s|^|${path}:|" || true)
            fi
        fi
        if [[ -n "$out" ]]; then hits+="${out}"$'\n'; fi
    done
    if [[ -n "$hits" ]]; then
        echo "❌ ${label}:"
        echo "$hits" | sed 's/^/    /'
        echo
        EXIT=1
    fi
}

# ---- BASE checks (apply to BASE + MIGRATION scopes) ----

run_base_checks() {
    check_pattern_in_paths \
        "Raw Color(red:..., green:..., blue:...) — use LeafColor.* or LeafPrimitive.*" \
        'Color\(red:[[:space:]]*[0-9]' \
        "(${LEAF_PRIMITIVE//./\.})|(${LEAF_COLOR//./\.})" \
        "$@"
    check_pattern_in_paths \
        "Raw Color(.systemFoo) — use LeafColor.* (system mappings live only in LeafColor.swift)" \
        'Color\(\.[a-zA-Z]' \
        "${LEAF_COLOR//./\.}" \
        "$@"
    check_pattern_in_paths \
        "Hex literal in code — define in LeafPrimitive.swift only" \
        '#[0-9A-Fa-f]{6}([^"]*)"' \
        "${LEAF_PRIMITIVE//./\.}" \
        "$@"
    check_pattern_in_paths \
        "Raw .padding(<int>) — use LeafSpace.*" \
        '\.padding\([0-9]+\)' \
        "" \
        "$@"
    check_pattern_in_paths \
        "Raw .padding(<edge>, <int>) — use LeafSpace.*" \
        '\.padding\(\.[a-zA-Z]+,[[:space:]]*[0-9]+\)' \
        "" \
        "$@"
    check_pattern_in_paths \
        "Raw cornerRadius:<int> — use LeafRadius.*" \
        'cornerRadius:[[:space:]]*[0-9]+' \
        "" \
        "$@"
    check_pattern_in_paths \
        "Raw .cornerRadius(<int>) — use LeafRadius.*" \
        '\.cornerRadius\([0-9]+' \
        "" \
        "$@"
    check_pattern_in_paths \
        "Raw RoundedRectangle(cornerRadius: <int>) — use LeafRadius.*" \
        'RoundedRectangle\(cornerRadius:[[:space:]]*[0-9]+' \
        "" \
        "$@"
}

run_base_checks "${BASE_PATHS[@]}"
run_base_checks "${MIGRATION_PATHS[@]}"

# ---- MIGRATION-only checks (old palette refs forbidden) ----

check_pattern_in_paths \
    "Old-palette reference — migrated views must use LeafColor.* / LeafType.* / LeafGlass.* exclusively" \
    '\.leaf(Background|Ink|Muted|Accent|AccentDeep|Signal|LabelStyle|Body|Title|Caption|Metric|Glass|GlassGroup)\b' \
    "" \
    "${MIGRATION_PATHS[@]}"

check_pattern_in_paths \
    "Old wrapper component — migrated views must use LeafCard / LeafGlass.* (token) instead" \
    '\b(GlassCard|LeafGlassGroup)\b' \
    "" \
    "${MIGRATION_PATHS[@]}"

if [[ $EXIT -ne 0 ]]; then
    echo "✘ Token-discipline guard failed — see above."
    exit 1
fi

echo "✓ Token-discipline guard passed."
