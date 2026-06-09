#!/usr/bin/env bash
# gen-release-notes.sh — single source of truth: CHANGELOG.md → release notes.
#
# Parses the repo-root CHANGELOG.md (Keep-a-Changelog, newest-first) and emits
# the two artifacts the release pipeline consumes. No consumer is wired into the
# release flow yet (that is Phase 2) — this is the standalone primitive, mirroring
# scripts/derive-version.sh: one parser, one place, fixture-tested.
#
# Modes:
#   gen-release-notes.sh                  Write build/releases/releases.json AND the
#                                         committed Leaf/Resources/releases.json
#                                         (the PREP step of /release-leaf; the
#                                         committed copy is what step_archive bundles
#                                         and step_upload pushes to the R2 root).
#   gen-release-notes.sh --json           Print releases.json to stdout, no writes.
#                                         Used by the freshness-guard (diff vs the
#                                         committed copy) and the self-test.
#   gen-release-notes.sh --html-only VER  Write build/releases/Leaf-VER.html — the
#                                         bare Sparkle "What's New" fragment for VER
#                                         (Phase 2 step_appcast embeds it).
#
# releases.json shape (schemaVersion top-level; tolerant Swift decoder lands in
# Phase 3 — unknown future keys must not break already-shipped binaries):
#   { "schemaVersion": 1,
#     "releases": [ { version, date, added[], fixed[], changed[],
#                     dmgURL, zipURL, yanked? }, ... ] }   # newest-first
# No raw htmlBody (the dashboard renders from the string arrays; Sparkle notes live
# in the .html). No dmgSha256 (it is uncomputable before staple, and the JSON must
# exist before step_archive; checksums ship as .sha256 sidecars on R2).
#
# URLs are DERIVED, never hardcoded — versions come only from the CHANGELOG:
#   https://updates.gundem.tech/releases/Leaf-<ver>.{dmg,zip}
#
# Test seams (mirror derive-version.sh): LEAF_CHANGELOG_FILE overrides the input,
# LEAF_RELEASES_OUT overrides the build dir, LEAF_RESOURCES_JSON overrides the
# committed copy — so the self-test never touches the real tree.
# Bash 3.2 compatible (macOS default + ubuntu CI). jq required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CHANGELOG_FILE="${LEAF_CHANGELOG_FILE:-$REPO_ROOT/CHANGELOG.md}"
RELEASES_OUT="${LEAF_RELEASES_OUT:-$REPO_ROOT/build/releases}"
RESOURCES_JSON="${LEAF_RESOURCES_JSON:-$REPO_ROOT/Leaf/Resources/releases.json}"

URL_PREFIX="https://updates.gundem.tech/releases"

fail() { echo "✘ gen-release-notes: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq not installed — run: brew install jq (macOS) / apt-get install jq (CI)"
[[ -f "$CHANGELOG_FILE" ]] || fail "CHANGELOG not found: $CHANGELOG_FILE"

# --- build releases.json (to stdout) --------------------------------------
# Parses the CHANGELOG line by line into one compact JSON object per released
# version, then `jq -s` wraps them into {schemaVersion, releases}. jq does all
# string escaping (--arg) and array splitting, so item text with quotes /
# backslashes / HTML chars round-trips safely.
build_json() {
    local cur_version="" cur_date="" cur_yanked="false" cur_cat=""
    local cur_added="" cur_fixed="" cur_changed=""
    local pending_item="" pending_active=0
    local release_objs=()

    flush_item() {
        [[ $pending_active -eq 1 ]] || return 0
        case "$cur_cat" in
            Added)   cur_added+="${cur_added:+$'\n'}$pending_item" ;;
            Fixed)   cur_fixed+="${cur_fixed:+$'\n'}$pending_item" ;;
            Changed) cur_changed+="${cur_changed:+$'\n'}$pending_item" ;;
            # Unknown / unset category: item is dropped (warned at header time).
        esac
        pending_item=""; pending_active=0
    }

    flush_release() {
        # Skip the running '[Unreleased]' bucket and any empty state.
        [[ -n "$cur_version" && "$cur_version" != "Unreleased" ]] || return 0
        local obj
        obj=$(jq -nc \
            --arg version "$cur_version" \
            --arg date "$cur_date" \
            --arg added "$cur_added" \
            --arg fixed "$cur_fixed" \
            --arg changed "$cur_changed" \
            --arg dmgURL "$URL_PREFIX/Leaf-$cur_version.dmg" \
            --arg zipURL "$URL_PREFIX/Leaf-$cur_version.zip" \
            --argjson yanked "$cur_yanked" \
            '{
               version: $version,
               date: $date,
               added:   ($added   | if . == "" then [] else split("\n") end),
               fixed:   ($fixed   | if . == "" then [] else split("\n") end),
               changed: ($changed | if . == "" then [] else split("\n") end),
               dmgURL: $dmgURL,
               zipURL: $zipURL
             }
             | if $yanked then . + {yanked: true} else . end')
        release_objs+=("$obj")
    }

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Tolerate a CRLF-edited CHANGELOG: a trailing \r would otherwise make
        # "### Added\r" miss the category match and SILENTLY drop the section.
        line="${line%$'\r'}"
        case "$line" in
            '## ['*)
                # New version section: close the prior item + release, reset state.
                flush_item
                flush_release
                local inner ver rest
                inner="${line#'## ['}"
                ver="${inner%%]*}"
                rest="${inner#*]}"
                # Fail loud on a malformed header (e.g. a missing ']' leaves the
                # whole "1.0.0 — 2026-01-01" as the version) instead of silently
                # emitting spaces/em-dashes into dmgURL/zipURL filenames. The
                # char class is semver-friendly (digits, letters, . + -) so it
                # never rejects a legitimate "1.0.0-alpha.30"/"Unreleased".
                [[ "$ver" =~ ^[0-9A-Za-z.+-]+$ ]] || fail "malformed version header (expected a semver-like token inside '[]', got '$ver'): $line"
                cur_version="$ver"
                cur_cat=""; cur_added=""; cur_fixed=""; cur_changed=""
                cur_date=""; cur_yanked="false"
                if [[ "$rest" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                    cur_date="${BASH_REMATCH[1]}"
                fi
                case "$rest" in
                    *'[YANKED]'*|*'[yanked]'*|*'[Yanked]'*) cur_yanked="true" ;;
                esac
                ;;
            '### '*)
                flush_item
                local name="${line#'### '}"
                case "$name" in
                    Added|Fixed|Changed) cur_cat="$name" ;;
                    *)
                        cur_cat=""
                        # Schema carries only added/fixed/changed; anything else
                        # (Security/Removed/Deprecated) is dropped — loudly, never
                        # silently misattributed to the prior category.
                        [[ -n "$cur_version" && "$cur_version" != "Unreleased" ]] && \
                            echo "! gen-release-notes: dropping unsupported '### $name' section in [$cur_version] (schema is added/fixed/changed)" >&2
                        ;;
                esac
                ;;
            '- '*)
                # New list item under the current category.
                flush_item
                pending_item="${line#- }"
                pending_active=1
                ;;
            '  '*)
                # Continuation of the current item (wrapped source line): join with
                # a single space after trimming the leading indent.
                if [[ $pending_active -eq 1 ]]; then
                    local cont="${line#"${line%%[![:space:]]*}"}"  # strip leading ws
                    pending_item+=" $cont"
                fi
                ;;
            '')
                # Blank line terminates the current item (categories/versions never
                # split an item with a blank line in this format).
                flush_item
                ;;
            *)
                # Prose / intro / link-reference footer ([ver]: https://...): ignore.
                flush_item
                ;;
        esac
    done < "$CHANGELOG_FILE"
    flush_item
    flush_release

    if [[ ${#release_objs[@]} -eq 0 ]]; then
        jq -n '{schemaVersion: 1, releases: []}'
    else
        printf '%s\n' "${release_objs[@]}" | jq -s '{schemaVersion: 1, releases: .}'
    fi
}

# --- render bare HTML fragment for one version ----------------------------
render_html() {
    local ver="$1" json
    json="$(build_json)"
    local found
    found="$(printf '%s' "$json" | jq -r --arg v "$ver" '[.releases[] | select(.version == $v)] | length')"
    [[ "$found" == "1" ]] || fail "version '$ver' not found in CHANGELOG ($CHANGELOG_FILE) — cannot render notes"
    printf '%s' "$json" | jq -r --arg v "$ver" '
        def section(title; arr):
            if (arr | length) > 0
            then ["<h3>\(title)</h3>", "<ul>"]
                 + (arr | map("  <li>\(. | @html)</li>"))
                 + ["</ul>"]
            else [] end;
        (.releases[] | select(.version == $v)) as $r
        | (["<h2>\($r.version | @html) — \($r.date | @html)</h2>"]
           + section("Added";   $r.added)
           + section("Fixed";   $r.fixed)
           + section("Changed"; $r.changed))
        | join("\n")
    '
}

# --- mode dispatch --------------------------------------------------------
case "${1:-}" in
    --json)
        build_json
        ;;
    --html-only)
        VER="${2:-}"
        [[ -n "$VER" ]] || fail "--html-only requires a version argument"
        mkdir -p "$RELEASES_OUT"
        out="$RELEASES_OUT/Leaf-$VER.html"
        render_html "$VER" > "$out"
        echo "✓ gen-release-notes: wrote $out" >&2
        ;;
    "")
        # Default: write build copy + committed copy, byte-identical to --json so
        # the freshness-guard's `diff <(--json) committed` stays clean.
        json="$(build_json)"
        mkdir -p "$RELEASES_OUT" "$(dirname "$RESOURCES_JSON")"
        printf '%s\n' "$json" > "$RELEASES_OUT/releases.json"
        printf '%s\n' "$json" > "$RESOURCES_JSON"
        echo "✓ gen-release-notes: wrote $RELEASES_OUT/releases.json + $RESOURCES_JSON" >&2
        ;;
    -h|--help)
        sed -n '2,40p' "$0"
        ;;
    *)
        fail "unknown arg: $1 (use --json | --html-only <ver> | no args)"
        ;;
esac
