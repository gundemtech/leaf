#!/usr/bin/env bash
# Self-test for check-bundle-split.sh — fixture-based, hermetic.
# Asserts: a split pbxproj passes; a re-unified / inverted / single-config one fails.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../check-bundle-split.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# GOOD — Debug uses .debug, Release stays prod.
cat > "$tmp/good" <<'EOF'
		isa = XCBuildConfiguration;
		PRODUCT_BUNDLE_IDENTIFIER = tech.gundem.leaf.debug;
		name = Debug;
		isa = XCBuildConfiguration;
		PRODUCT_BUNDLE_IDENTIFIER = tech.gundem.leaf;
		name = Release;
EOF
"$GUARD" "$tmp/good" >/dev/null || { echo "FAIL: split fixture was rejected"; exit 1; }

# BAD 1 — Debug re-unified to the prod id (the regression we guard against).
cat > "$tmp/bad1" <<'EOF'
		isa = XCBuildConfiguration;
		PRODUCT_BUNDLE_IDENTIFIER = tech.gundem.leaf;
		name = Debug;
		isa = XCBuildConfiguration;
		PRODUCT_BUNDLE_IDENTIFIER = tech.gundem.leaf;
		name = Release;
EOF
if "$GUARD" "$tmp/bad1" >/dev/null 2>&1; then echo "FAIL: re-unified Debug id passed"; exit 1; fi

# BAD 2 — .debug leaked into Release (would ship a debug id to prod).
cat > "$tmp/bad2" <<'EOF'
		isa = XCBuildConfiguration;
		PRODUCT_BUNDLE_IDENTIFIER = tech.gundem.leaf.debug;
		name = Debug;
		isa = XCBuildConfiguration;
		PRODUCT_BUNDLE_IDENTIFIER = tech.gundem.leaf.debug;
		name = Release;
EOF
if "$GUARD" "$tmp/bad2" >/dev/null 2>&1; then echo "FAIL: .debug in Release passed"; exit 1; fi

# BAD 3 — sanity floor: a parse that finds no Debug config must fail (not pass vacuously).
cat > "$tmp/bad3" <<'EOF'
		isa = XCBuildConfiguration;
		PRODUCT_BUNDLE_IDENTIFIER = tech.gundem.leaf;
		name = Release;
EOF
if "$GUARD" "$tmp/bad3" >/dev/null 2>&1; then echo "FAIL: missing-Debug fixture passed vacuously"; exit 1; fi

echo "✓ check-bundle-split self-test passed (split ok; re-unify / Release-.debug / no-Debug all caught)"
