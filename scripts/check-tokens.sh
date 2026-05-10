#!/usr/bin/env bash
# Track 2 / D1+D2+D3+D4 — token-discipline guard.
#
# Three-tier scope (final form post-D4):
#   • BASE scope        — Leaf/Theme/ + Leaf/Views/Tokens/. Bans raw colors,
#     raw padding ints, raw cornerRadius ints. Does NOT ban old-palette
#     references because the palette itself is defined here historically;
#     RETIRED tier (below) catches old-palette regardless of scope.
#   • MIGRATION scope   — Leaf/Views/ (entire directory minus Tokens/ which
#     lives under BASE). Inherits BASE checks AND additionally bans
#     old-palette references (defense-in-depth alongside RETIRED tier).
#   • RETIRED scope     — Leaf/ (entire tree). Bans old-palette names
#     anywhere in the codebase. Catches accidental re-introduction via
#     comments / strings / copy-paste from git history (compile-time
#     deletion is primary guard; this is secondary).
#
# Allowed inside any scope:
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

# ---- Tier 2: MIGRATION scope (whole Leaf/Views/ minus Tokens/) ----
# Single entry: entire Views/ directory. BASE_PATHS includes Views/Tokens/
# separately; check_pattern_in_paths over MIGRATION_PATHS still scans
# Views/Tokens/ but BASE rules already apply there — no ill effect, just
# duplicate-but-consistent enforcement.
MIGRATION_PATHS=(
    "${REPO_ROOT}/Leaf/Views"
)

# ---- Tier 3: RETIRED scope (whole Leaf/) ----
RETIRED_PATHS=(
    "${REPO_ROOT}/Leaf"
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
    '\.leaf(Background|Ink|Muted|Accent|AccentDeep|Signal|LabelStyle|Body|Title|Caption|Metric)\b' \
    "" \
    "${MIGRATION_PATHS[@]}"

check_pattern_in_paths \
    "Old wrapper component — migrated views must use LeafCard / LeafGlass.* (token) instead" \
    '\b(GlassCard|LeafGlassGroup)\b' \
    "" \
    "${MIGRATION_PATHS[@]}"

# ---- RETIRED checks (old palette names banned ANYWHERE in Leaf/) ----
# Defense-in-depth: compile-time deletion is primary guard (token files
# removed in D4 retirement); this catches accidental re-introduction
# via comments, strings, or copy-paste from git history.

check_pattern_in_paths \
    "RETIRED — old-palette Color name (Color.leafInk / leafBackground / etc) — use LeafColor.*" \
    'Color\.leaf(Ink|Background|Card|Accent|AccentDeep|Signal|Muted)\b' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — old-palette ShapeStyle name (.leafInk / .leafBackground / etc on foregroundStyle) — use LeafColor.*" \
    '\.leaf(Ink|Background|Card|Accent|AccentDeep|Signal|Muted)\b' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — old-palette Font name (Font.leafBody / leafHeadline / etc) — use LeafType.*" \
    'Font\.leaf(Body|Headline|Title|Caption|Label|Metric)\b' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — old-palette font call-site (.font(.leafBody) / etc) — use LeafType.*" \
    '\.font\(\.leaf(Body|Headline|Title|Caption|Label|Metric)\)' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — leafLabelStyle() helper — use Text.leafSectionLabel()" \
    '\.leafLabelStyle\(\)' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — GlassCard wrapper — use LeafCard variant" \
    '\bGlassCard\b' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — LeafProminentButton / LeafSecondaryButton / LeafGlassGroup wrappers — use LeafButton + LeafGlass.* token" \
    '\bLeafProminentButton\b|\bLeafSecondaryButton\b|\bLeafGlassGroup\b' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — old MetricCard wrapper — use LeafMetricCard" \
    '\bMetricCard\b' \
    'Leaf(MetricCard|MetricTokens|MetricAmbient|MetricDelta|MetricInline|MetricCardPreview)' \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — old EmptyStateView wrapper — use LeafEmptyState" \
    '\bEmptyStateView\b' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — old BannerView wrapper — use LeafBanner" \
    '\bBannerView\b' \
    "" \
    "${RETIRED_PATHS[@]}"

check_pattern_in_paths \
    "RETIRED — Color.leafCategory(_:) — categories no longer surfaced as user-facing signal" \
    'Color\.leafCategory\(|\.leafCategory\(' \
    "" \
    "${RETIRED_PATHS[@]}"

if [[ $EXIT -ne 0 ]]; then
    echo "✘ Token-discipline guard failed — see above."
    exit 1
fi

echo "✓ Token-discipline guard passed."
