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

# Idempotent Debug launch: kill stale agent, unregister /Applications hijack,
# lsregister Debug build, print CDHash, open, stream Agent log.
dev:
    @./scripts/dev-launch.sh

# Reset Accessibility TCC + remove /Applications/Leaf.app, then dev-launch.
# Use when CDHash drift has accumulated и нужен clean slate. Requires confirm.
dev-clean:
    @./scripts/dev-reset-tcc.sh && ./scripts/dev-launch.sh

# Stream both main app + agent logs (Ctrl-C to detach).
dev-log:
    @log stream --predicate 'subsystem CONTAINS "tech.gundem.leaf"' --info
