# Leaf — task runner.

default:
    @just --list

# Phase-done gate (R1): every guard + full build + SPM tests must pass. Fail-fast,
# cheap guards first so a leak/token/migration slip aborts before the slow build.
# Green here ⟺ the phase may merge. gitleaks needs `brew install gitleaks`.
preflight:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "▶ preflight 1/7 — leak-guard";              ./scripts/leak-guard.sh --report
    echo "▶ preflight 2/7 — check-tokens";            ./scripts/check-tokens.sh
    echo "▶ preflight 3/7 — check-migrations";        ./scripts/check-migrations.sh
    echo "▶ preflight 4/7 — gitleaks";                ./scripts/gitleaks-scan.sh
    echo "▶ preflight 5/7 — bundle-split guard";      ./scripts/check-bundle-split.sh
    echo "▶ preflight 6/7 — build-all (5 schemes)";   just build-all
    echo "▶ preflight 7/7 — SPM tests";               just test-core
    echo "✅ preflight: all 7 checks green — phase may merge."

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

# Regression guard (#26): Debug configs must use a distinct .debug bundle id and
# Release must not — keeps dev builds out of the prod LaunchServices/DB namespace
# (the post-Sparkle launch-breakage root cause). Fails if ever re-unified.
check-bundle-split:
    @./scripts/check-bundle-split.sh

# Fixture-based self-test for check-bundle-split.
check-bundle-split-self-test:
    @./scripts/tests/test-check-bundle-split.sh

# Run the fixture-based self-test for check-migrations.
check-migrations-self-test:
    @./scripts/tests/test-check-migrations.sh

# Run the fixture-based self-test for leak-guard.
leak-guard-self-test:
    @./scripts/tests/test-leak-guard.sh

# Print the latest shipped release tag (v-prefixed semver, sort -V, form-asserted).
# Single source of truth the release pipeline derives N+1 from.
derive-version:
    @./scripts/derive-version.sh

# Fixture-based self-test for derive-version (filter is load-bearing; malformed
# highest tag fails loud; empty/junk sets rejected).
derive-version-self-test:
    @./scripts/tests/test-derive-version.sh

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
# clone, then commit + push there. Backs up the clone's moat before the
# reverse --delete (recoverable in the moat archive).
moat-push:
    @./scripts/moat-push.sh

# Fixture-based self-tests for the moat tooling: retention GC (mtime-based),
# moat-push pre-delete clone backup, moat-sync archive override + GC. Fast and
# hermetic — sandboxed, no network, xcodebuild/swift stubbed.
moat-self-test:
    @./scripts/tests/test-moat-archive-retention.sh
    @./scripts/tests/test-moat-push-backup.sh
    @./scripts/tests/test-moat-sync-archive.sh

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

# Break-glass: un-wedge LaunchServices when `open Leaf` / Spotlight / a Sparkle
# relaunch resolve a stale phantom bundle (post-update / dev-build pollution).
# Removes only regenerable DerivedData + repo build/ Leaf.app copies, rebuilds
# the LS database, restarts lsd, re-registers /Applications. Idempotent.
fix-launch:
    @./scripts/fix-launch.sh

# AI Coworker P1 — provision the BYOK Anthropic key (no UI). Reads the key from
# the ANTHROPIC_API_KEY env var (NOT a recipe arg — keeps it out of `ps` / shell
# history; supply it inline with `! export ANTHROPIC_API_KEY=...`), writes it
# 0600 to the keystore. `variant` = "Leaf" (prod ship build, default) or
# "Leaf-Debug" (a `.debug` MCP build). The key is never echoed.
set-byok-key variant="Leaf":
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "✘ set ANTHROPIC_API_KEY first, e.g.:  ! export ANTHROPIC_API_KEY=sk-ant-..." >&2
        exit 1
    fi
    dir="$HOME/Library/Application Support/{{variant}}/keystore"
    mkdir -p "$dir"
    printf '%s' "$ANTHROPIC_API_KEY" > "$dir/anthropic-byok.key"
    chmod 600 "$dir/anthropic-byok.key"
    echo "✓ BYOK key written 0600 to $dir/anthropic-byok.key (not echoed)"

# AI Coworker P1 — toggle §4.3 strict mode (withhold the user's own authored
# labels from the default Q&A path). Writes the shared cross-process suite key
# the read-only MCP process reads (StrictModeReader).
ai-strict-mode mode:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in
      on)  defaults write tech.gundem.leaf leaf.ai.strict_mode -bool true
           echo "✓ AI strict mode ON — self-authored labels withheld (escalation-only)";;
      off) defaults write tech.gundem.leaf leaf.ai.strict_mode -bool false
           echo "✓ AI strict mode OFF — self-authored labels go by default (§4.3)";;
      *)   echo "usage: just ai-strict-mode on|off" >&2; exit 1;;
    esac
