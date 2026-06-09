#!/usr/bin/env bash
# check-releases-fresh.sh — freshness guard for the committed releases.json.
#
# Regenerates releases.json from CHANGELOG.md (via gen-release-notes.sh --json)
# and diffs it against the committed Leaf/Resources/releases.json. Fails if they
# diverge — i.e. CHANGELOG.md was edited without re-running `just gen-notes`, so
# the bundled / R2-served copy would silently lag the changelog.
#
# Enforced in `just preflight` and the leak-guard CI workflow (ubuntu — cheap
# script job; jq is preinstalled there). Same belt-and-suspenders discipline as
# check-migrations.sh / check-tokens.sh: a generated artifact that ships must be
# provably regenerable from its source.
# Bash 3.2 compatible (macOS default + ubuntu CI). jq required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/scripts/gen-release-notes.sh"
COMMITTED="$REPO_ROOT/Leaf/Resources/releases.json"

fail() { echo "✘ check-releases-fresh: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq not installed — run: brew install jq (macOS) / apt-get install jq (CI)"
[[ -x "$GEN" ]] || fail "gen-release-notes.sh missing or not executable: $GEN"
[[ -f "$COMMITTED" ]] || fail "committed releases.json missing: $COMMITTED — run: just gen-notes && git add $COMMITTED"

# Regenerate to a temp first (not process substitution) so a generator failure
# surfaces as a generator error, not a misleading "stale" diff. `--json` is
# byte-identical (same jq, same trailing newline) to what default mode writes
# into the committed copy, so a plain diff is exact.
tmp="$(mktemp -t leaf-releases-fresh.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
"$GEN" --json > "$tmp" || fail "gen-release-notes.sh --json failed — fix the generator before checking freshness"

if ! diff -u "$COMMITTED" "$tmp"; then
    echo >&2
    fail "committed Leaf/Resources/releases.json is stale vs CHANGELOG.md (diff above).
  Regenerate and commit:  just gen-notes && git add Leaf/Resources/releases.json"
fi

echo "✓ check-releases-fresh: committed releases.json matches CHANGELOG.md."
