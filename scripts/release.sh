#!/usr/bin/env bash
# release.sh — Leaf release orchestrator (archive → export → notary → staple → appcast → upload).
#
# Phase 3.3 — local-first signed/notarized/stapled distribution pipeline.
# Idempotent через stamp-файлы под build/releases/.stamps/. Re-run пропускает completed steps.
#
# Usage:
#     bash scripts/release.sh <version>                 # default: stamp-aware skip
#     bash scripts/release.sh <version> --redo-from <step>
#     bash scripts/release.sh <version> --clean
#     bash scripts/release.sh -h | --help
#
# Steps (in order): archive export verify dmg notary staple zip appcast upload

set -euo pipefail

# --- pretty prints --------------------------------------------------------
C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
info() { echo "${C_INFO}→${C_OFF} $*"; }
ok()   { echo "${C_OK}✓${C_OFF} $*"; }
err()  { echo "${C_ERR}✗${C_OFF} $*" >&2; }
warn() { echo "${C_WARN}!${C_OFF} $*" >&2; }

usage() {
    cat <<'EOF'
Usage: release.sh <version> [--redo-from <step> | --clean]

Steps in order: archive export verify dmg notary staple zip appcast upload

Default: re-run skips completed steps (stamp-aware under build/releases/.stamps/).
Flags:
  --redo-from <step>   rm stamps от <step> и далее, форсит re-do tail
  --clean              rm -rf build/releases/, full rebuild

Iteration на notary fail (entitlements/signing fix):
  bash scripts/release.sh 1.0.0-alpha.1 --clean
  (entitlements изменения требуют re-archive — full clean)

На notary success ретрай (network blip и т.п.):
  bash scripts/release.sh 1.0.0-alpha.1 --redo-from notary

Required env vars (для step_upload):
  R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY CF_ZONE_ID CF_API_TOKEN
  Загрузить локально: gh secret list → export ... в shell

Required tools: xcodebuild, codesign, jq, xmllint, create-dmg, ditto,
                ~/bin/sparkle/generate_appcast, ~/bin/sparkle/sign_update
                xcrun notarytool (keychain-profile "leaf-notary" из Phase 3.0)
EOF
}

# --- arg parsing ----------------------------------------------------------
[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

VERSION="$1"; shift
REDO_FROM=""; CLEAN_FIRST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --redo-from) REDO_FROM="${2:?--redo-from requires step name}"; shift 2 ;;
        --clean)     CLEAN_FIRST=1; shift ;;
        *)           err "unknown arg: $1"; usage; exit 1 ;;
    esac
done

# --- paths ----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES="$REPO_ROOT/build/releases"
STAMPS="$RELEASES/.stamps"
ARCHIVE="$RELEASES/Leaf-$VERSION.xcarchive"
EXPORTED="$RELEASES/exported"
APP="$EXPORTED/Leaf.app"
DMG="$RELEASES/Leaf-$VERSION.dmg"
ZIP="$RELEASES/Leaf-$VERSION.zip"

SIGN_ID="Developer ID Application: Dmitrii Demidov (4LZ84Z78M7)"
NOTARY_PROFILE="leaf-notary"

STEPS=(archive export verify dmg notary staple zip appcast upload)

# --- pre-flight -----------------------------------------------------------
require_tools() {
    local missing=()
    for t in xcodebuild codesign jq xmllint create-dmg ditto; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [[ -x ~/bin/sparkle/generate_appcast ]] || missing+=("~/bin/sparkle/generate_appcast")
    [[ -x ~/bin/sparkle/sign_update ]] || missing+=("~/bin/sparkle/sign_update")
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "missing required tools: ${missing[*]}"
        exit 1
    fi
}

assert_signing_identity() {
    if ! security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
        err "signing identity not in Keychain: $SIGN_ID"
        err "Phase 3.0 prerequisite — install Developer ID Application cert."
        exit 1
    fi
}

assert_version_matches_pbxproj() {
    local pbx_version
    pbx_version=$(xcodebuild -showBuildSettings -scheme Leaf -configuration Release 2>/dev/null \
        | grep -m1 "MARKETING_VERSION = " | sed 's/.*= //' | tr -d ' ')
    if [[ "$pbx_version" != "$VERSION" ]]; then
        err "version mismatch: arg=$VERSION, pbxproj MARKETING_VERSION=$pbx_version"
        err "Bump pbxproj first (git commit), then re-run."
        exit 1
    fi
    ok "version $VERSION matches pbxproj"
}

require_env_for_upload() {
    local missing=()
    for v in R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY CF_ZONE_ID CF_API_TOKEN; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "missing env vars for upload: ${missing[*]}"
        err "See: bash scripts/upload-release.sh --help"
        exit 1
    fi
}

# --- stamp helpers --------------------------------------------------------
stamp_path() { echo "$STAMPS/$1"; }

is_done() { [[ -f "$(stamp_path "$1")" ]]; }

mark_done() { mkdir -p "$STAMPS" && touch "$(stamp_path "$1")"; }

apply_flags() {
    if [[ -n "$CLEAN_FIRST" ]]; then
        info "--clean: rm -rf $RELEASES"
        rm -rf "$RELEASES"
    fi
    if [[ -n "$REDO_FROM" ]]; then
        local found=0
        for s in "${STEPS[@]}"; do
            [[ "$s" == "$REDO_FROM" ]] && found=1
            [[ $found -eq 1 ]] && rm -f "$(stamp_path "$s")"
        done
        if [[ $found -eq 0 ]]; then
            err "--redo-from $REDO_FROM: not a known step (${STEPS[*]})"
            exit 1
        fi
        info "--redo-from $REDO_FROM: cleared stamps for tail steps"
    fi
    mkdir -p "$RELEASES" "$STAMPS"
}

# --- steps ----------------------------------------------------------------
step_archive() {
    is_done archive && { info "skip archive (stamp exists)"; return 0; }
    info "archive → $ARCHIVE"
    rm -rf "$ARCHIVE"
    xcodebuild archive \
        -scheme Leaf \
        -archivePath "$ARCHIVE" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic >/dev/null
    mark_done archive
    ok "archive done"
}

step_export() {
    # Bypass xcodebuild -exportArchive (требует Developer ID Provisioning Profile).
    # Copy .app из .xcarchive + manual inside-out re-sign с Developer ID Application.
    is_done export && { info "skip export (stamp exists)"; return 0; }
    info "export + re-sign → $APP"
    rm -rf "$EXPORTED"
    mkdir -p "$EXPORTED"
    cp -R "$ARCHIVE/Products/Applications/Leaf.app" "$APP"

    local sp="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    local cs=(codesign --force --timestamp --options=runtime --sign "$SIGN_ID")
    "${cs[@]}" "$sp/XPCServices/Downloader.xpc" >/dev/null
    "${cs[@]}" "$sp/XPCServices/Installer.xpc" >/dev/null
    "${cs[@]}" "$sp/Updater.app" >/dev/null
    "${cs[@]}" "$sp/Autoupdate" >/dev/null
    "${cs[@]}" "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null
    "${cs[@]}" "$APP/Contents/Frameworks/SQLCipher.framework" >/dev/null
    "${cs[@]}" --entitlements "$REPO_ROOT/LeafAgent/LeafAgent.entitlements" "$APP/Contents/MacOS/LeafAgent" >/dev/null
    "${cs[@]}" --entitlements "$REPO_ROOT/LeafMCP/LeafMCP.entitlements" "$APP/Contents/MacOS/LeafMCP" >/dev/null
    "${cs[@]}" --entitlements "$REPO_ROOT/Leaf/Leaf.entitlements" "$APP" >/dev/null

    mark_done export
    ok "export + re-sign done"
}

step_verify() {
    is_done verify && { info "skip verify (stamp exists)"; return 0; }
    info "codesign --verify --deep --strict"
    codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
    local authority
    authority=$(codesign -dv --verbose=4 "$APP" 2>&1 | grep -m1 "^Authority=Developer ID Application" || true)
    if [[ -z "$authority" ]]; then
        err "Leaf.app не подписан Developer ID Application — notary отвергнет."
        codesign -dv --verbose=4 "$APP" 2>&1 | grep "^Authority="
        exit 1
    fi
    ok "verify: $authority"
    mark_done verify
}

step_dmg() {
    is_done dmg && { info "skip dmg (stamp exists)"; return 0; }
    info "create-dmg → $DMG"
    rm -f "$DMG"
    rm -rf "$RELEASES/dmg-source"
    mkdir -p "$RELEASES/dmg-source"
    cp -R "$APP" "$RELEASES/dmg-source/"
    create-dmg --volname "Leaf $VERSION" "$DMG" "$RELEASES/dmg-source" >/dev/null 2>&1 || true
    rm -rf "$RELEASES/dmg-source"
    [[ -f "$DMG" ]] || { err "create-dmg не создал $DMG"; exit 1; }
    mark_done dmg
    ok "dmg done ($(du -h "$DMG" | cut -f1))"
}

step_notary() {
    is_done notary && { info "skip notary (stamp exists)"; return 0; }
    info "notarytool submit $DMG (Apple --wait: ~1-5 min typical)"
    local submit_out
    submit_out=$(xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json) || { err "notarytool submit failed"; exit 1; }
    local id status
    id=$(echo "$submit_out" | jq -r .id)
    status=$(echo "$submit_out" | jq -r .status)
    info "submission id=$id status=$status"
    if [[ "$status" != "Accepted" ]]; then
        local log_file="$RELEASES/notary-$(date +%s).log"
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 | tee "$log_file"
        err "notary status=$status — issues:"
        jq -r '.issues[]? | "[\(.severity)] \(.path // "?"): \(.message)"' "$log_file" >&2 || true
        err "Fix issue → bash scripts/release.sh $VERSION --clean"
        exit 1
    fi
    mark_done notary
    ok "notary accepted (id=$id)"
}

step_staple() {
    # Stapler требует EXACT same artifact hash что был submitted to notary.
    # НЕ re-create .dmg — Apple's CDN не хранит ticket для нового hash'а.
    # Staple .dmg отдельно от .app:
    #   - .dmg ticket для Gatekeeper при mount (offline)
    #   - .app ticket для launch после Sparkle update (offline; via $ZIP в step_zip)
    # .app внутри .dmg остаётся unstapled — Gatekeeper online-проверяет при first-launch
    #   через Apple's CDN (есть ticket по CDHash из .dmg submission). No user warning.
    is_done staple && { info "skip staple (stamp exists)"; return 0; }
    info "staple .app + .dmg (separately, same notary submission)"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    mark_done staple
    ok "staple done"
}

step_zip() {
    is_done zip && { info "skip zip (stamp exists)"; return 0; }
    info "ditto → $ZIP (Sparkle update bundle)"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    mark_done zip
    ok "zip done ($(du -h "$ZIP" | cut -f1))"
}

step_appcast() {
    # generate_appcast не любит .dmg + .zip same version (duplicate updates).
    # Sparkle update path = .zip; .dmg = first install only. Прячем .dmg на время
    # генерации, возвращаем после.
    is_done appcast && { info "skip appcast (stamp exists)"; return 0; }
    info "generate_appcast → $RELEASES/appcast.xml"
    local hidden="$DMG.appcast-hidden"
    [[ -f "$DMG" ]] && mv "$DMG" "$hidden"
    local rc=0
    ~/bin/sparkle/generate_appcast \
        --download-url-prefix https://updates.gundem.tech/releases/ \
        "$RELEASES/" >/dev/null || rc=$?
    [[ -f "$hidden" ]] && mv "$hidden" "$DMG"
    [[ $rc -eq 0 ]] || { err "generate_appcast failed (rc=$rc)"; exit $rc; }
    xmllint --noout "$RELEASES/appcast.xml"
    local item_count
    item_count=$(xmllint --xpath 'count(//item)' "$RELEASES/appcast.xml" 2>/dev/null || echo 0)
    [[ "$item_count" -ge 1 ]] || { err "appcast.xml содержит 0 <item>"; exit 1; }
    mark_done appcast
    ok "appcast done ($item_count <item> entries)"
}

step_upload() {
    is_done upload && { info "skip upload (stamp exists)"; return 0; }
    require_env_for_upload
    info "upload → R2 + CF cache purge"
    bash "$REPO_ROOT/scripts/upload-release.sh" "$RELEASES"
    mark_done upload
    ok "upload done"
}

# --- main -----------------------------------------------------------------
require_tools
assert_signing_identity
assert_version_matches_pbxproj
apply_flags

step_archive
step_export
step_verify
step_dmg
step_notary
step_staple
step_zip
step_appcast
step_upload

ok "release $VERSION done. Artifacts: $RELEASES/"
echo "  Leaf-$VERSION.dmg  ($(du -h "$DMG" | cut -f1))"
echo "  Leaf-$VERSION.zip  ($(du -h "$ZIP" | cut -f1))"
echo "  appcast.xml         (live: https://updates.gundem.tech/appcast.xml)"
