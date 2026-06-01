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

# OSS leak guard — scan tracked tree for forbidden patterns (names, tuned
# pragma numerics, secrets, tracked moat source). Same set CI enforces.
leak-guard:
    @./scripts/leak-guard.sh --report

# Run the fixture-based self-test for leak-guard.
leak-guard-self-test:
    @./scripts/tests/test-leak-guard.sh

# Install the git pre-push hook (thin wrapper around leak-guard.sh).
# Run once per clone. Bypass a single push with `git push --no-verify`.
install-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    hook=.git/hooks/pre-push
    printf '#!/usr/bin/env bash\nexec "$(git rev-parse --show-toplevel)/scripts/leak-guard.sh"\n' > "$hook"
    chmod +x "$hook"
    echo "Installed $hook → scripts/leak-guard.sh"

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
