# Leaf — task runner.

default:
    @just --list

# Token-discipline guard — Track 2 D1+. Fails if Leaf/Theme/ or
# Leaf/Views/Tokens/ contain raw colours/spacing/radii.
check-tokens:
    @./scripts/check-tokens.sh

# Run the fixture-based self-test for check-tokens.
check-tokens-self-test:
    @./scripts/tests/test-check-tokens.sh

# Build all 5 Xcode schemes (Debug).
build-all:
    #!/usr/bin/env bash
    set -e
    for s in LeafCore LeafCorePrivate Leaf LeafAgent LeafMCP; do
        echo "=== $s ==="
        xcodebuild -scheme "$s" -configuration Debug build -quiet 2>&1 | tail -3
    done

# Run LeafCore SPM tests.
test-core:
    swift test --package-path Packages/LeafCore

# === Style — Phase 1+. См. STYLE.md, .swift-format, .swiftlint.yml. ===

# Apply swift-format in-place across all Swift sources.
format:
    xcrun swift-format format --in-place --recursive \
        Leaf LeafAgent LeafMCP \
        Packages/LeafCore/Sources Packages/LeafCore/Tests

# Validate format без записи. Non-zero exit on violations.
format-check:
    xcrun swift-format lint --strict --recursive \
        Leaf LeafAgent LeafMCP \
        Packages/LeafCore/Sources Packages/LeafCore/Tests

# Lint via SwiftLint, filter through baseline. Reports только новые violations.
lint:
    swiftlint lint --config .swiftlint.yml --baseline .swiftlint-baseline.json

# Auto-fix SwiftLint violations where rule supports --fix.
lint-fix:
    swiftlint lint --fix --config .swiftlint.yml --baseline .swiftlint-baseline.json

# Composite gate — оба check'а sequentially.
check-style: format-check lint
