#!/usr/bin/env bash
# gitleaks-scan.sh — belt-and-suspenders secret scan of the git-tracked tree.
#
# Layered over scripts/leak-guard.sh (which owns moat/name/pragma patterns).
# Run by `just preflight` and the CI leak-guard workflow — NOT by the pre-push
# hook (that stays leak-guard-only for speed).
#
# Scans a `git archive HEAD` export rather than `gitleaks dir .` so it covers
# EXACTLY the committed tracked tree — no .build / DerivedData / untracked noise
# (which makes a raw dir-scan slow) and identical to what a fresh CI checkout
# sees. Allowlist lives in .gitleaks.toml (public client_ids, Sparkle pubkey,
# synthetic test fixtures).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "✘ gitleaks not installed — run: brew install gitleaks" >&2
    exit 1
fi

tmp="$(mktemp -d -t leaf-gitleaks.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

git archive --format=tar HEAD | tar -x -C "$tmp"

gitleaks dir "$tmp" \
    --config "$REPO_ROOT/.gitleaks.toml" \
    --no-banner --redact --exit-code 1

echo "✓ gitleaks: no secrets in the tracked tree."
