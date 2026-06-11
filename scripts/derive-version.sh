#!/usr/bin/env bash
# derive-version.sh — single source of truth for "latest shipped version".
#
# Prints the highest shipped release tag (e.g. v1.0.0-alpha.30) to stdout, or
# exits non-zero with a message on stderr. No consumer is wired in yet — this is
# the primitive the release pipeline (release.sh / .claude/commands/release-leaf.md)
# derives N+1 from, so the grep-filter + form-assert live in exactly one place
# instead of being re-pasted (and re-broken) per caller.
#
# Why the ^v grep filter is load-bearing: a naive `git tag | sort -V | tail -1`
# lets a prefixless tag (1.0.0-alpha.6) or junk tag (phase-2-done,
# dev-track7-source, archive/*) win tail-1 if it ever sorts highest. We keep
# only v-prefixed semver tags, then assert the winner's form so a malformed tag
# halts the release loudly instead of silently shipping the wrong base version.
#
# NB (GA footgun): `sort -V` ranks a bare `v1.0.0` BELOW its own prereleases —
# {v1.0.0, v1.0.0-alpha.30} | sort -V | tail -1 == v1.0.0-alpha.30 (verified on
# BSD 2.3-Apple + GNU coreutils). Harmless pre-GA (no bare tag exists). At the
# GA cutover this derivation must be revisited so v1.0.0 wins over its alphas.
#
# Test seam: LEAF_DERIVE_TAGS overrides the tag source (newline-separated) so
# scripts/tests/test-derive-version.sh feeds fixtures without planting real tags.
# No-colon `-` expansion: the default applies only when the var is fully UNSET;
# an explicitly-empty override (LEAF_DERIVE_TAGS='') is a meaningful "no tags"
# fixture and must NOT fall back to the live `git tag`.
# Bash 3.2 compatible (macOS default + ubuntu CI).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "✘ derive-version: $1" >&2; exit 1; }

TAGS="${LEAF_DERIVE_TAGS-$(git -C "$REPO_ROOT" tag)}"

latest="$(printf '%s\n' "$TAGS" | grep -E '^v[0-9]+\.' | sort -V | tail -1 || true)"
[[ -n "$latest" ]] || fail "no v-prefixed release tag found (filtered tag set is empty)"

form='^v[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$'
[[ "$latest" =~ $form ]] || fail "latest tag '$latest' fails version-form assert ($form) — malformed/unexpected tag, human review needed before release"

printf '%s\n' "$latest"
