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

# Migration linearity guard (R3) — fails on duplicate/gap/out-of-order Mnnn.
check-migrations:
    @./scripts/check-migrations.sh

# gitleaks secret scan of the tracked tree (belt+suspenders over leak-guard).
# Needs `brew install gitleaks`. Allowlist in .gitleaks.toml.
gitleaks:
    @./scripts/gitleaks-scan.sh

# Run the fixture-based self-test for check-migrations.
check-migrations-self-test:
    @./scripts/tests/test-check-migrations.sh

# Run the fixture-based self-test for leak-guard.
leak-guard-self-test:
    @./scripts/tests/test-leak-guard.sh

# Point git at the tracked .githooks/ dir (run once per clone). The pre-push hook
# there runs leak-guard before every push to the public repo. This OVERWRITES any
# existing core.hooksPath and means per-clone .git/hooks/* no longer fire (we ship
# none that matter). Bypass a single push with `git push --no-verify`.
install-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    git config core.hooksPath .githooks
    echo "Set core.hooksPath → .githooks (pre-push runs scripts/leak-guard.sh)"

# Clone/refresh the private moat (gundemtech/leaf-private) into the gitignored
# build paths. Run once on a fresh clone; re-run to pull moat updates.
# `just moat-sync --force` overwrites local build-path edits (backed up first).
moat-sync *ARGS:
    @./scripts/moat-sync.sh {{ARGS}}

# Reverse-sync local moat edits from the build paths back into the leaf-private
# clone, then commit + push there.
moat-push:
    @./scripts/moat-push.sh

# Build all 5 Xcode schemes (Debug). Exit-honest: a BUILD FAILED in any scheme
# aborts non-zero (do NOT pipe xcodebuild→tail under set -e — the pipe's exit is
# tail's 0 and masks failure, giving preflight a false green). Full output is
# captured per-scheme; tail-3 on success, tail-40 + the kept logfile on failure.
build-all:
    #!/usr/bin/env bash
    set -euo pipefail
    for s in LeafCore LeafCorePrivate Leaf LeafAgent LeafMCP; do
        echo "=== $s ==="
        log="$(mktemp -t "leaf-build-$s.XXXXXX")"
        if xcodebuild -scheme "$s" -configuration Debug build -quiet >"$log" 2>&1; then
            tail -3 "$log"; rm -f "$log"
        else
            rc=$?
            echo "✘ BUILD FAILED ($s, exit $rc) — last 40 lines of $log:"
            tail -40 "$log"
            exit "$rc"
        fi
    done
    echo "✓ build-all: all 5 schemes built"

# Self-test build-all exit propagation: a stub xcodebuild that always fails must
# make `just build-all` exit non-zero (guards the pipe-to-tail masking regression).
build-all-self-test:
    @./scripts/tests/test-build-all-exit.sh

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
