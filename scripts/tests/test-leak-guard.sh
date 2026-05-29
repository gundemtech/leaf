#!/usr/bin/env bash
# Fixture-based self-test for scripts/leak-guard.sh.
#
# Runs the guard in FIXTURES_ONLY mode against synthetic temp files so the
# result is independent of the working tree's scrub state. One detect-case
# per forbidden category + negative controls proving the carve-outs.
#
# Sensitive needles (names, real pragma value) are base64-decoded at runtime —
# this test file holds no plaintext PII. Structural secrets use fake values.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${REPO_ROOT}/scripts/leak-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

b64d() { printf '%s' "$1" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; }; }

# run <content> [basename] — write a fixture, scan it fixtures-only, return guard exit.
run() {
    local content="$1" name="${2:-fixture.txt}" fx
    fx="$TMP/$name"
    mkdir -p "$(dirname "$fx")"
    printf '%s\n' "$content" > "$fx"
    LEAF_LEAK_GUARD_FIXTURES_ONLY=1 LEAF_LEAK_GUARD_EXTRA_FILES="$fx" "$GUARD" >/dev/null 2>&1
}

assert_detect() {  # guard must FAIL (exit non-zero)
    local label="$1" content="$2" name="${3:-fixture.txt}"
    if run "$content" "$name"; then
        echo "  ✘ FAIL (expected detect): $label"; exit 1
    else
        echo "  ✓ detected: $label"
    fi
}

assert_allow() {   # guard must PASS (exit zero)
    local label="$1" content="$2" name="${3:-fixture.txt}"
    if run "$content" "$name"; then
        echo "  ✓ allowed:  $label"
    else
        echo "  ✘ FAIL (expected allow): $label"; exit 1
    fi
}

echo "leak-guard self-test:"

# --- Detect cases: one per forbidden category ---
assert_detect "Latin team-member name"     "let sender = \"$(b64d QW50b24=)\""           # Anton
assert_detect "Cyrillic team-member name"  "спроси $(b64d 0JTQuNC80YM=) про это"          # Диму
assert_detect "tuned pragma value"         "busy_timeout=9"                               # fake number, real key
assert_detect "AWS IAM access key id"      "key = AKIAQWERTYUIOPASDFGH"
assert_detect "PEM private key block"      "-----BEGIN RSA PRIVATE KEY-----"
assert_detect "GitHub PAT"                 "token ghp_0123456789abcdefABCDEF0123456789abcd"
assert_detect "OpenAI-style key"           "sk-0123456789abcdefghijKLMN"
assert_detect "APNs identifier"            "APNS_TEAM_ID=ABCDE12345"
assert_detect "hardcoded signing identity" 'SIGN_ID="Developer ID Application: Foo Bar (ABCDE12345)"'
assert_detect "moat source tracked"        "import Foundation"  "sub/LeafCorePrivate_Secret.swift"
assert_detect "personal email address"     "let owner = \"someone@gmail.com\""

# --- Negative controls: carve-outs and placeholders must pass ---
assert_allow  "clean fixture"              "let greeting = \"hello world\""
assert_allow  "lowercase MCP handles"      'leaf_ask_question(to="dima"/"anton")'
assert_allow  "APNs placeholder"           "APNS_TEAM_ID=<APNS_TEAM_ID>"
assert_allow  "pragma without a value"     "cipher_plaintext_header_size — см. moat config"
assert_allow  "neutral placeholder name"   "let sender = \"Sasha\""
assert_allow  "team / example email"       "contact dev@gundem.tech or owner@example.com"
assert_allow  "Placeholder moat file ok"   "enum Placeholder {}"  "sub/LeafCorePrivate/Placeholder.swift"

echo "All leak-guard self-test cases passed."
