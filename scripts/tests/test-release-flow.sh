#!/usr/bin/env bash
# test-release-flow.sh — self-test for the Phase 2 release.sh / upload-release.sh
# orchestration changes (NOT the signing/notary steps, which need a Mac + certs).
#
# Three seams keep this hermetic — no xcodebuild, no AWS, no network:
#   • LEAF_RELEASE_LIB_ONLY=1 sources release.sh as a library: every function is
#     defined, but the arg-parser + pipeline do NOT run. Lets us call run_pipeline
#     with stub steps, and assert_secrets / maybe_load_cached_secrets directly.
#   • LEAF_RELEASE_ENV_CACHE overrides the offline secrets-cache path so a stray
#     real ~/.config/leaf/release.env can never mask a dry-run.
#   • Structural greps over upload-release.sh codify the cp-ordering invariant
#     (releases.json uploaded LAST) and the CF purge set — the parts that have no
#     runnable assertion without a live R2 bucket.
#
# Public-safe (leak-guard name-scans scripts/tests/*): no real names, and the
# spaced-value cache fixture deliberately avoids any Developer-ID-shaped literal.
# Bash 3.2 compatible (macOS default + ubuntu CI).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/release.sh"
UPLOAD="$REPO_ROOT/scripts/upload-release.sh"
pass=0; fail=0

check() {  # check <label> <condition-rc>
    local label="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then echo "  ✓ $label"; pass=$((pass + 1));
    else echo "  ✘ $label"; fail=$((fail + 1)); fi
}

WORK="$(mktemp -d -t leaf-release-flow.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
NOPE="$WORK/no-cache.env"   # guaranteed-absent cache path for dry-runs

SECRET_VARS="R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY CF_ZONE_ID CF_API_TOKEN"

# ===========================================================================
# bash -n syntax (cheap regression guard on both scripts)
# ===========================================================================
bash -n "$SCRIPT";  check "release.sh parses (bash -n)" $?
bash -n "$UPLOAD";  check "upload-release.sh parses (bash -n)" $?

# ===========================================================================
# assert_secrets — dry-run with NO secrets fails fast (the Phase 2 dry-run test)
# ===========================================================================
set +e
DRY_OUT="$(
    unset $SECRET_VARS
    LEAF_RELEASE_ENV_CACHE="$NOPE" bash "$SCRIPT" 1.0.0-alpha.999 --until appcast 2>&1
)"
DRY_RC=$?
set -e
[[ "$DRY_RC" -ne 0 ]];                       check "no-secrets dry-run exits non-zero" $?
printf '%s' "$DRY_OUT" | grep -q 'R2_BUCKET'; check "dry-run names the missing R2/CF secrets" $?
# Proves fail-FAST: it bailed at assert_secrets before the archive step ran.
! printf '%s' "$DRY_OUT" | grep -qi 'archive →'; check "dry-run bails before archiving (fail-fast)" $?

# ===========================================================================
# --until validation — an unknown step name is rejected before any work
# ===========================================================================
set +e
BAD_OUT="$(
    unset $SECRET_VARS
    LEAF_RELEASE_ENV_CACHE="$NOPE" bash "$SCRIPT" 1.0.0-alpha.999 --until bogusstep 2>&1
)"
BAD_RC=$?
set -e
[[ "$BAD_RC" -ne 0 ]];                              check "--until <unknown> exits non-zero" $?
printf '%s' "$BAD_OUT" | grep -qi 'bogusstep';      check "--until <unknown> error names the bad step" $?

# ===========================================================================
# run_pipeline — empty UNTIL runs every step; UNTIL=<step> stops right after it
# (sourced as a library, real run_pipeline, stub steps)
# ===========================================================================
FULL_OUT="$(
    export LEAF_RELEASE_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "$SCRIPT"
    STEPS=(alpha bravo charlie); UNTIL=""
    step_alpha()   { echo "ran:alpha"; }
    step_bravo()   { echo "ran:bravo"; }
    step_charlie() { echo "ran:charlie"; }
    run_pipeline
)"
printf '%s' "$FULL_OUT" | grep -q 'ran:alpha' && \
printf '%s' "$FULL_OUT" | grep -q 'ran:bravo' && \
printf '%s' "$FULL_OUT" | grep -q 'ran:charlie'
check "empty UNTIL runs all steps" $?

STOP_OUT="$(
    export LEAF_RELEASE_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "$SCRIPT"
    STEPS=(alpha bravo charlie); UNTIL="bravo"
    step_alpha()   { echo "ran:alpha"; }
    step_bravo()   { echo "ran:bravo"; }
    step_charlie() { echo "ran:charlie"; }
    run_pipeline
)"
printf '%s' "$STOP_OUT" | grep -q 'ran:alpha' && printf '%s' "$STOP_OUT" | grep -q 'ran:bravo'
check "UNTIL=bravo runs alpha + bravo" $?
! printf '%s' "$STOP_OUT" | grep -q 'ran:charlie'
check "UNTIL=bravo stops before charlie" $?

# ===========================================================================
# assert_secrets — passes when all six are present
# ===========================================================================
OK_RC=0
(
    export LEAF_RELEASE_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "$SCRIPT"
    export R2_BUCKET=b R2_ENDPOINT=e R2_ACCESS_KEY_ID=k R2_SECRET_ACCESS_KEY=s CF_ZONE_ID=z CF_API_TOKEN=t
    assert_secrets
) >/dev/null 2>&1 || OK_RC=$?
check "assert_secrets passes when all six secrets present" "$OK_RC"

# ===========================================================================
# maybe_load_cached_secrets — empty live env + cache file → loads it (loud),
# tolerates spaced values, and assert_secrets then passes
# ===========================================================================
CACHE="$WORK/release.env"
cat > "$CACHE" <<'EOF'
# Generated by scripts/vault.sh from AWS SSM prefix /leaf/release/
# DO NOT COMMIT THIS FILE

R2_BUCKET=leaf-updates
R2_ENDPOINT=https://example.r2.cloudflarestorage.com
R2_ACCESS_KEY_ID=AKIAEXAMPLE
R2_SECRET_ACCESS_KEY=shh
CF_ZONE_ID=zone123
CF_API_TOKEN=tok123
SPACED_VALUE_KEY=one two three
EOF

CACHE_OUT="$(
    export LEAF_RELEASE_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "$SCRIPT"
    unset $SECRET_VARS
    export LEAF_RELEASE_ENV_CACHE="$CACHE"
    maybe_load_cached_secrets 2>&1   # warning goes to stderr → captured
    echo "R2_BUCKET=${R2_BUCKET:-<empty>}"
    echo "SPACED=[${SPACED_VALUE_KEY:-<empty>}]"
    assert_secrets >/dev/null 2>&1 && echo "ASSERT_OK" || echo "ASSERT_FAIL"
)"
printf '%s' "$CACHE_OUT" | grep -qi 'cached secrets'
check "cached-secrets load emits a loud warning" $?
printf '%s' "$CACHE_OUT" | grep -q 'R2_BUCKET=leaf-updates'
check "cache populates R2_BUCKET into the env" $?
printf '%s' "$CACHE_OUT" | grep -q 'SPACED=\[one two three\]'
check "cache parser preserves spaces in values" $?
printf '%s' "$CACHE_OUT" | grep -q 'ASSERT_OK'
check "assert_secrets passes after cache load" $?

# Live env present → cache is NOT consulted (primary path wins, no warning).
LIVE_OUT="$(
    export LEAF_RELEASE_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "$SCRIPT"
    export R2_BUCKET=live R2_ENDPOINT=e R2_ACCESS_KEY_ID=k R2_SECRET_ACCESS_KEY=s CF_ZONE_ID=z CF_API_TOKEN=t
    export LEAF_RELEASE_ENV_CACHE="$CACHE"
    maybe_load_cached_secrets 2>&1
    echo "R2_BUCKET=${R2_BUCKET}"
)"
! printf '%s' "$LIVE_OUT" | grep -qi 'cached secrets'
check "live env present → cache not loaded (no warning)" $?
printf '%s' "$LIVE_OUT" | grep -q 'R2_BUCKET=live'
check "live env value not clobbered by cache" $?

# ===========================================================================
# upload-release.sh — Ordering invariant + permalink + purge set (structural)
# ===========================================================================
appcast_ln="$(grep -nF 's3://$R2_BUCKET/appcast.xml' "$UPLOAD" | head -1 | cut -d: -f1)"
reljson_ln="$(grep -nF 's3://$R2_BUCKET/releases.json' "$UPLOAD" | tail -1 | cut -d: -f1)"
[[ -n "$appcast_ln" && -n "$reljson_ln" && "$reljson_ln" -gt "$appcast_ln" ]]
check "releases.json uploaded AFTER appcast.xml (Ordering invariant)" $?

grep -qF 'Leaf/Resources/releases.json' "$UPLOAD"
check "releases.json sourced from the committed copy (survives --clean)" $?

grep -qF 's3://$R2_BUCKET/Leaf.dmg' "$UPLOAD"
check "stable Leaf.dmg permalink uploaded to bucket root" $?
grep -qF 's3://$R2_BUCKET/Leaf.dmg.sha256' "$UPLOAD"
check "root Leaf.dmg.sha256 uploaded" $?

# CF purge must cover the three new cacheable surfaces (else 300s stale edge).
purge_block="$(grep -F 'updates.gundem.tech' "$UPLOAD")"
printf '%s' "$purge_block" | grep -qF 'releases.json'
check "CF purge includes releases.json" $?
printf '%s' "$purge_block" | grep -qF 'Leaf.dmg'
check "CF purge includes Leaf.dmg" $?
printf '%s' "$purge_block" | grep -qF 'Leaf.dmg.sha256'
check "CF purge includes Leaf.dmg.sha256" $?

# ===========================================================================
# release.sh step_appcast hardening (structural — the trap + embed + asserts
# have no runnable path without Sparkle + a real archive)
# ===========================================================================
grep -qF -- '--embed-release-notes' "$SCRIPT"
check "step_appcast forces --embed-release-notes" $?
grep -q 'appcast-hidden' "$SCRIPT" && grep -q 'trap' "$SCRIPT"
check "step_appcast restores hidden DMGs via a trap (interrupt-safe)" $?
grep -qF 'gen-release-notes.sh' "$SCRIPT"
check "step_appcast renders the What's New fragment" $?

echo "release-flow self-test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
