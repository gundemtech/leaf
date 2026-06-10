#!/usr/bin/env bash
# test-gen-release-notes.sh — fixture-based self-test for gen-release-notes.sh.
#
# Feeds a controlled CHANGELOG via LEAF_CHANGELOG_FILE and asserts the three
# surfaces the release pipeline consumes:
#   • --json (stdout): the releases.json the dashboard + R2 root serve and the
#     freshness-guard diffs against the committed copy.
#   • default (no args): writes build/releases/releases.json AND the committed
#     Leaf/Resources/releases.json — both must be byte-identical to --json
#     (that identity is exactly what the freshness-guard enforces).
#   • --html-only <ver>: the bare Sparkle "What's New" fragment embedded into the
#     signed appcast — must carry <h2>/<h3>/<li> and must NOT contain a
#     <!DOCTYPE or <body (Sparkle 2.9.1 embeds only bare fragments).
#
# Fixtures are PUBLIC-SAFE: leak-guard.sh name-scans scripts/tests/* (the gitleaks
# allowlist for this dir does NOT cover leak-guard's name patterns). Placeholder
# names are Alice/Bob only. The HTML-escaping fixture deliberately uses & < > "
# to prove jq @html escaping (not the names).
# Bash 3.2 compatible (macOS default + ubuntu CI).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/gen-release-notes.sh"
pass=0; fail=0

check() {  # check <label> <condition-rc> — rc 0 = pass
    local label="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then echo "  ✓ $label"; pass=$((pass + 1));
    else echo "  ✘ $label"; fail=$((fail + 1)); fi
}

# --- scratch workspace ----------------------------------------------------
WORK="$(mktemp -d -t leaf-gen-notes.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
CHANGELOG="$WORK/CHANGELOG.md"
OUT="$WORK/build/releases"
RES="$WORK/Leaf/Resources/releases.json"

# Fixture CHANGELOG — exercises: Unreleased skip, prose-after-header ignore,
# intro-prose ignore, [YANKED] marker, continuation-line join, HTML-significant
# chars, empty categories, link-reference footer ignore, newest-first order.
cat > "$CHANGELOG" <<'EOF'
# Changelog

Intro prose before any version header — must be ignored entirely.

## [Unreleased]

### Added
- An unreleased feature that must NOT appear in releases.json.

## [1.0.0-alpha.3] — 2026-03-03 [YANKED]

### Fixed
- A bad build pulled from distribution.

## [1.0.0-alpha.2] — 2026-02-02

Free-text paragraph under a version header that must be ignored.

### Added
- Second feature with a continuation line that wraps across
  two source lines and should join into one item.
- A note with HTML chars: Alice & Bob <both> said "hi".

### Changed
- Tweaked an internal default.

## [1.0.0-alpha.1] — 2026-01-01

### Added
- First ever build.

[Unreleased]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.3...HEAD
[1.0.0-alpha.3]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.2...v1.0.0-alpha.3
[1.0.0-alpha.2]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.1...v1.0.0-alpha.2
[1.0.0-alpha.1]: https://github.com/gundemtech/leaf/releases/tag/v1.0.0-alpha.1
EOF

# --- run --json -----------------------------------------------------------
JSON="$(LEAF_CHANGELOG_FILE="$CHANGELOG" "$SCRIPT" --json)"

jqc() { printf '%s' "$JSON" | jq -e "$1" >/dev/null 2>&1; }

jqc '.schemaVersion == 1'; check "schemaVersion is 1 (top-level)" $?
jqc 'type == "object" and (.releases | type == "array")'; check "top-level object with releases array" $?
jqc '.releases | length == 3'; check "Unreleased excluded → exactly 3 released entries" $?

# newest-first order preserved from the document.
jqc '.releases[0].version == "1.0.0-alpha.3"'; check "releases[0] is newest (alpha.3)" $?
jqc '.releases[1].version == "1.0.0-alpha.2"'; check "releases[1] is alpha.2" $?
jqc '.releases[2].version == "1.0.0-alpha.1"'; check "releases[2] is oldest (alpha.1)" $?

# every record carries the full key set.
jqc '.releases[] | has("version") and has("date") and has("added") and has("fixed") and has("changed") and has("dmgURL") and has("zipURL")'
check "every record has version/date/added/fixed/changed/dmgURL/zipURL" $?

# yanked marker.
jqc '.releases[0].yanked == true'; check "[YANKED] header → yanked:true" $?
jqc '.releases[1] | has("yanked") | not'; check "non-yanked record omits yanked key" $?

# dates.
jqc '.releases[0].date == "2026-03-03"'; check "yanked entry date parsed (trailing [YANKED] stripped)" $?
jqc '.releases[1].date == "2026-02-02"'; check "alpha.2 date parsed" $?

# category arrays — empty vs populated.
jqc '.releases[0].added == [] and .releases[0].changed == []'; check "empty categories → empty arrays" $?
jqc '.releases[0].fixed == ["A bad build pulled from distribution."]'; check "single fixed item" $?
jqc '.releases[1].added | length == 2'; check "alpha.2 has 2 added items" $?
jqc '.releases[1].changed == ["Tweaked an internal default."]'; check "alpha.2 changed item" $?

# continuation-line join (wrapped source lines → one item, single space).
jqc '.releases[1].added[0] == "Second feature with a continuation line that wraps across two source lines and should join into one item."'
check "continuation lines joined with single space" $?

# HTML-significant chars survive RAW in JSON (no escaping at the JSON layer).
jqc '.releases[1].added[1] == "A note with HTML chars: Alice & Bob <both> said \"hi\"."'
check "HTML-significant chars stored raw in JSON" $?

# derived URLs (no hardcoded version literals — derived from CHANGELOG).
jqc '.releases[1].dmgURL == "https://updates.gundem.tech/releases/Leaf-1.0.0-alpha.2.dmg"'
check "dmgURL derived correctly" $?
jqc '.releases[1].zipURL == "https://updates.gundem.tech/releases/Leaf-1.0.0-alpha.2.zip"'
check "zipURL derived correctly" $?

# --- default mode writes both files, byte-identical to --json -------------
set +e
LEAF_CHANGELOG_FILE="$CHANGELOG" LEAF_RELEASES_OUT="$OUT" LEAF_RESOURCES_JSON="$RES" "$SCRIPT" >/dev/null 2>&1
rc=$?
set -e
check "default mode exits 0" "$rc"
[[ -f "$OUT/releases.json" ]]; check "default mode wrote build/releases/releases.json" $?
[[ -f "$RES" ]]; check "default mode wrote committed Leaf/Resources/releases.json" $?
diff <(printf '%s\n' "$JSON") "$RES" >/dev/null 2>&1
check "committed copy byte-identical to --json (freshness invariant)" $?
diff "$OUT/releases.json" "$RES" >/dev/null 2>&1
check "build copy byte-identical to committed copy" $?

# --- --html-only <ver> ----------------------------------------------------
set +e
LEAF_CHANGELOG_FILE="$CHANGELOG" LEAF_RELEASES_OUT="$OUT" "$SCRIPT" --html-only 1.0.0-alpha.2 >/dev/null 2>&1
rc=$?
set -e
check "--html-only known version exits 0" "$rc"
HTML_FILE="$OUT/Leaf-1.0.0-alpha.2.html"
[[ -f "$HTML_FILE" ]]; check "--html-only wrote Leaf-<ver>.html" $?
if [[ -f "$HTML_FILE" ]]; then
    grep -q '<h2>' "$HTML_FILE"; check "fragment has <h2> version header" $?
    grep -q '<h3>Added</h3>' "$HTML_FILE"; check "fragment has <h3>Added</h3>" $?
    grep -q '<h3>Changed</h3>' "$HTML_FILE"; check "fragment has <h3>Changed</h3>" $?
    grep -q '<li>' "$HTML_FILE"; check "fragment has <li> items" $?
    # No Fixed section for alpha.2 (it has no fixed items).
    ! grep -q '<h3>Fixed</h3>' "$HTML_FILE"; check "fragment omits empty Fixed section" $?
    # HTML escaping via jq @html.
    grep -q '&amp;' "$HTML_FILE"; check "fragment escapes & → &amp;" $?
    grep -q '&lt;both&gt;' "$HTML_FILE"; check "fragment escapes < > → &lt; &gt;" $?
    # Sparkle 2.9.1 embed condition: bare fragment, no document wrapper.
    ! grep -qi '<!DOCTYPE' "$HTML_FILE"; check "fragment has NO <!DOCTYPE (Sparkle embed)" $?
    ! grep -qi '<body' "$HTML_FILE"; check "fragment has NO <body (Sparkle embed)" $?
fi

# --- --html-only unknown version → fail loud ------------------------------
set +e
LEAF_CHANGELOG_FILE="$CHANGELOG" LEAF_RELEASES_OUT="$OUT" "$SCRIPT" --html-only 9.9.9 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "--html-only unknown version fails loud" $?

# --- empty: only [Unreleased] → graceful {releases: []} -------------------
EMPTY="$WORK/EMPTY.md"
cat > "$EMPTY" <<'EOF'
# Changelog

## [Unreleased]

### Added
- Something not yet shipped.
EOF
set +e
EJSON="$(LEAF_CHANGELOG_FILE="$EMPTY" "$SCRIPT" --json 2>/dev/null)"
rc=$?
set -e
check "empty (Unreleased-only) CHANGELOG exits 0" "$rc"
printf '%s' "$EJSON" | jq -e '.schemaVersion == 1 and (.releases == [])' >/dev/null 2>&1
check "empty CHANGELOG → {schemaVersion:1, releases:[]}" $?

# --- CRLF line endings → parsed, no \r leakage (no silent category drop) --
# A Windows-edited CHANGELOG must not silently lose every item (the category
# header "### Added\r" would otherwise miss the case match and drop the section).
CRLF="$WORK/CRLF.md"
printf '# Changelog\r\n\r\n## [2.0.0-rc.1] — 2027-07-07\r\n\r\n### Added\r\n- a crlf item\r\n- a second crlf item\r\n' > "$CRLF"
CRLFJSON="$(LEAF_CHANGELOG_FILE="$CRLF" "$SCRIPT" --json 2>/dev/null)"
printf '%s' "$CRLFJSON" | jq -e '.releases[0].version == "2.0.0-rc.1"' >/dev/null 2>&1
check "CRLF: version parsed clean (no trailing CR)" $?
printf '%s' "$CRLFJSON" | jq -e '.releases[0].added == ["a crlf item", "a second crlf item"]' >/dev/null 2>&1
check "CRLF: category + items survive (no silent drop, no \\r in text)" $?

# --- malformed version header (no closing bracket) → fail loud -------------
# Without validation, "## [1.0.0 — 2027-01-01" yields a garbage version with
# spaces/em-dash that flows into dmgURL/zipURL filenames.
MAL="$WORK/MAL.md"
printf '# Changelog\n\n## [1.0.0 — 2027-01-01\n\n### Added\n- oops\n' > "$MAL"
set +e
LEAF_CHANGELOG_FILE="$MAL" "$SCRIPT" --json >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "malformed version header (no ']') fails loud" $?

# --- HTML header escaping (defensive @html on version/date) ----------------
# The version form-assert blocks HTML chars upstream, so the header can only ever
# carry a clean version; assert the normal header still renders correctly through
# @html (regression guard against the escaping change breaking ordinary output).
LEAF_CHANGELOG_FILE="$CHANGELOG" LEAF_RELEASES_OUT="$OUT" "$SCRIPT" --html-only 1.0.0-alpha.1 >/dev/null 2>&1
grep -q '<h2>1.0.0-alpha.1 — 2026-01-01</h2>' "$OUT/Leaf-1.0.0-alpha.1.html"
check "header renders version+date intact through @html" $?

# --- missing CHANGELOG → fail loud ----------------------------------------
set +e
LEAF_CHANGELOG_FILE="$WORK/does-not-exist.md" "$SCRIPT" --json >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]]; check "missing CHANGELOG fails loud" $?

echo "gen-release-notes self-test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
