#!/usr/bin/env bash
# leak-guard.sh — OSS leak guard for gundemtech/leaf (public repo).
#
# Single source of truth for the forbidden-pattern set. Enforced by:
#   • .github/workflows/leak-guard.yml  — CI on PRs + pushes to main.
#   • .git/hooks/pre-push                — installed via `just install-hooks`.
# Automates the mechanical part of the manual /pre-push-leaf checklist.
#
# --- Self-leak avoidance (why the patterns look the way they do) ---
#   • Team-member first names are NOT secret (they appear in the public
#     whitepaper) but must not sit verbatim in source. Stored here as
#     base64 needles, decoded in-memory — keeps the script from being a
#     plaintext roster and avoids self-matching during the scan.
#   • Tuned moat NUMERICS (SQLCipher pragma values) ARE secret. They are
#     guarded STRUCTURALLY — `<pragma-key> = <digit>` — so the concrete
#     value never appears in this (public) file. The pragma key names are
#     public SQLCipher API; only the number is moat, and the regex matches
#     `[0-9]`, not a specific value.
#   • Structural secret regexes (IAM key ids, PEM blocks, provider tokens,
#     APNs ids) are generic, not secret → literal here.
#   • This script, its self-test, the workflow, and the OSS decision docs
#     are EXCLUDED from the scan (they legitimately reference patterns).
#
# Usage:
#   scripts/leak-guard.sh            # scan tracked tree; non-zero on any hit
#   scripts/leak-guard.sh --report   # same, with a summary header
#
# Self-test hook: LEAF_LEAK_GUARD_EXTRA_FILES=path1:path2 appends untracked
# files to every scan (used by scripts/tests/test-leak-guard.sh).
#
# Bash 3.2 compatible (macOS default + ubuntu CI). No mapfile / namerefs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

REPORT=0
[[ "${1:-}" == "--report" ]] && REPORT=1

# Self-test isolation: scan ONLY the extra fixtures, never the tracked tree.
# Lets the self-test pass/fail deterministically while the real tree is still
# being scrubbed. The real `just leak-guard` run leaves this unset (scans tree).
FIXTURES_ONLY="${LEAF_LEAK_GUARD_FIXTURES_ONLY:-0}"

EXIT=0

# Paths that legitimately reference forbidden patterns — never scanned.
SELF_EXCLUDE=(
    ':(exclude)scripts/leak-guard.sh'
    ':(exclude)scripts/tests/test-leak-guard.sh'
    ':(exclude)scripts/oss/rewrite-authors.sh'
    ':(exclude).github/workflows/leak-guard.yml'
    ':(exclude)docs/superpowers/decisions/*'
    ':(exclude)docs/superpowers/specs/*'
)

# Portable base64 decode (GNU `-d`, BSD `-D`).
b64d() { printf '%s' "$1" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; }; }

# Extra (untracked) files from the self-test, colon-separated.
EXTRA_FILES=()
if [[ -n "${LEAF_LEAK_GUARD_EXTRA_FILES:-}" ]]; then
    IFS=':' read -ra EXTRA_FILES <<< "$LEAF_LEAK_GUARD_EXTRA_FILES"
fi

# Collect matches into a single hit buffer per category, then report.
emit() {
    local label="$1" hits="$2"
    hits="$(printf '%s\n' "$hits" | grep -vE '^[[:space:]]*$' || true)"
    if [[ -n "$hits" ]]; then
        echo "❌ ${label}:"
        printf '%s\n' "$hits" | sed 's/^/    /'
        echo
        EXIT=1
    fi
}

# Scan tracked tree (git grep) + extra files (plain grep) for one or more
# needles, reporting all hits under a single category label.
# $1 label  $2 mode(word|lit|regex)  $3.. needle/pattern ...
scan() {
    local label="$1" mode="$2"; shift 2
    local out="" needle gargs gflags
    case "$mode" in
        word)  gargs=(-nI -w -F);  gflags="-nIwF" ;;   # whole-word, fixed, case-sensitive
        lit)   gargs=(-nI -F);     gflags="-nIF"  ;;   # substring, fixed, case-sensitive
        ilit)  gargs=(-nI -F -i);  gflags="-nIFi" ;;   # substring, fixed, case-INsensitive (surnames in emails/logins)
        regex) gargs=(-nIE);       gflags="-nIE"  ;;   # extended regex
    esac
    for needle in "$@"; do
        if [[ "$FIXTURES_ONLY" != "1" ]]; then
            local g
            g="$(git grep "${gargs[@]}" -e "$needle" -- . "${SELF_EXCLUDE[@]}" 2>/dev/null || true)"
            [[ -n "$g" ]] && out+=$'\n'"$g"
        fi
        if [[ ${#EXTRA_FILES[@]} -gt 0 ]]; then
            local f extra
            for f in "${EXTRA_FILES[@]}"; do
                [[ -f "$f" ]] || continue
                extra="$(grep $gflags -e "$needle" "$f" 2>/dev/null | sed "s|^|${f}:|" || true)"
                [[ -n "$extra" ]] && out+=$'\n'"$extra"
            done
        fi
    done
    emit "$label" "$out"
}

# ---------------------------------------------------------------------------
# Category 1 — team-member names (base64; not secret, but not in source).
# ---------------------------------------------------------------------------
NAME_WORD_B64=(            # Latin: whole-word, case-sensitive (skips to="dima")
    RG1pdHJpaQ== RGltYQ== RGVtaWRvdg== Qm9jaGthcmV2 QW50b24=
)
NAME_LIT_B64=(             # Cyrillic incl. declensions: substring, case-sensitive
    0JTQvNC40YLRgNC40Lk= 0JTQuNC80LA= 0JTQuNC80LU= 0JTQuNC80YM= 0JTQuNC80Ys=
    0JTQtdC80LjQtNC+0LI= 0JDQvdGC0L7QvQ== 0JDQvdGC0L7QvdCw
    0JHQvtGH0LrQsNGA0ZHQsg== 0JHQvtGH0LrQsNGA0LXQsg==
)
NAME_WORD=(); for b in "${NAME_WORD_B64[@]}"; do NAME_WORD+=("$(b64d "$b")"); done
NAME_LIT=();  for b in "${NAME_LIT_B64[@]}";  do NAME_LIT+=("$(b64d "$b")");  done
# Surnames / formal first name — case-INsensitive substring: catches a lowercase
# surname embedded in an email local-part, a login, or a hyphenated handle that
# the case-sensitive whole-word pass above misses. Safe (these tokens have no
# legit lowercase use); short first names stay whole-word case-sensitive above
# to avoid matching them inside common substrings.
NAME_ILIT_B64=( RG1pdHJpaQ== RGVtaWRvdg== Qm9jaGthcmV2 )
NAME_ILIT=(); for b in "${NAME_ILIT_B64[@]}"; do NAME_ILIT+=("$(b64d "$b")"); done
scan "Team-member name (use a neutral placeholder)" word "${NAME_WORD[@]}"
scan "Team-member name (use a neutral placeholder)" lit  "${NAME_LIT[@]}"
scan "Team-member name (use a neutral placeholder)" ilit "${NAME_ILIT[@]}"

# ---------------------------------------------------------------------------
# Category 2 — tuned SQLCipher pragma numerics (structural; value never here).
# ---------------------------------------------------------------------------
scan "Tuned SQLCipher pragma value (move the number to LeafCorePrivate/Prod/Configs)" \
    regex '(cipher_plaintext_header_size|busy_timeout)[[:space:]]*=[[:space:]]*[0-9]'

# ---------------------------------------------------------------------------
# Category 3 — cloud / IAM credentials (structural).
# ---------------------------------------------------------------------------
scan "AWS IAM access key id"            regex '(AKIA|ASIA)[0-9A-Z]{16}'
scan "PEM private key block"            regex '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan "GitHub personal access token"     regex 'gh[ps]_[A-Za-z0-9]{36}'
scan "OpenAI-style secret key"          regex 'sk-[A-Za-z0-9]{20,}'
scan "Personal email address (use a synthetic / team address)" \
    regex '[A-Za-z0-9._%+-]+@(gmail|yandex|outlook|icloud|proton|hotmail|mail)\.(com|ru|me)'
scan "Apple APNs identifier (use <APNS_TEAM_ID> / <APNS_KEY_ID>)" \
    regex 'APNS_(TEAM|KEY)_ID[[:space:]]*=[[:space:]]*[A-Z0-9]{10}'
scan "Hardcoded code-signing identity with name+team (use \$LEAF_SIGN_ID)" \
    regex 'Developer ID [A-Za-z]+: [^(<]*\([A-Z0-9]{10}\)'

# ---------------------------------------------------------------------------
# Category 4 — moat source code accidentally tracked.
# Only Placeholder.swift may be tracked under the gitignored moat dirs.
# ---------------------------------------------------------------------------
moat_hits=""
if [[ "$FIXTURES_ONLY" != "1" ]]; then
    moat_hits="$(git ls-files \
            'Packages/LeafCore/Sources/LeafCorePrivate/*.swift' \
            'Packages/LeafCore/Sources/LeafCorePrivate/**/*.swift' \
            'Packages/LeafCore/Tests/LeafCorePrivateTests/*.swift' \
            'Packages/LeafCore/Tests/LeafCorePrivateTests/**/*.swift' 2>/dev/null \
        | grep -v '/Placeholder\.swift$' || true)"
fi
# Self-test hook: an extra path that looks like tracked moat source.
if [[ ${#EXTRA_FILES[@]} -gt 0 ]]; then
    for f in "${EXTRA_FILES[@]}"; do
        case "$f" in
            *LeafCorePrivate*.swift|*LeafCorePrivateTests*.swift)
                [[ "$f" == *Placeholder.swift ]] || moat_hits+=$'\n'"$f" ;;
        esac
    done
fi
emit "Moat source tracked (must stay gitignored; only Placeholder.swift allowed)" "$moat_hits"

# ---------------------------------------------------------------------------
if [[ $EXIT -ne 0 ]]; then
    echo "✘ leak-guard failed — the lines above must be redacted before pushing."
    echo "  Names → neutral placeholder. Pragma numbers → LeafCorePrivate/Prod/Configs."
    echo "  Secrets → never commit (see .claude/commands/pre-push-leaf.md)."
    exit 1
fi

[[ $REPORT -eq 1 ]] && echo "leak-guard --report: scanned tracked tree + ${#EXTRA_FILES[@]} extra file(s)."
echo "✓ leak-guard passed — no forbidden patterns in the tracked tree."
