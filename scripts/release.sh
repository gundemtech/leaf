#!/usr/bin/env bash
# release.sh — Leaf release orchestrator (archive → export → notary → staple → appcast → upload).
#
# Phase 3.3 — local-first signed/notarized/stapled distribution pipeline.
# Idempotent через stamp-файлы под build/releases/.stamps/. Re-run пропускает completed steps.
#
# Phase 2 (release-pipeline) additions:
#   • Secrets come from AWS SSM via `vault.sh run release` (live env) or, offline,
#     a cached env-file (consulted only when the live env is empty). assert_secrets
#     fails fast — before archive/notary — if neither is present.
#   • --until <step> stops the pipeline after a step (the publish-gate: build to
#     `appcast`, then resume `upload`/`site` after a human confirm in /release-leaf).
#   • step_appcast embeds the CHANGELOG-derived "What's New" notes and is
#     interrupt-safe (a kill mid-generation no longer strands the DMG).
#
# Usage:
#     vault.sh run release -- bash scripts/release.sh <version>            # full ship
#     vault.sh run release -- bash scripts/release.sh <version> --until appcast
#     bash scripts/release.sh <version> --redo-from <step>
#     bash scripts/release.sh <version> --clean
#     bash scripts/release.sh -h | --help
#
# Steps (in order): archive export verify dmg notary staple zip appcast upload site

set -euo pipefail

# --- pretty prints --------------------------------------------------------
C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
info() { echo "${C_INFO}→${C_OFF} $*"; }
ok()   { echo "${C_OK}✓${C_OFF} $*"; }
err()  { echo "${C_ERR}✗${C_OFF} $*" >&2; }
warn() { echo "${C_WARN}!${C_OFF} $*" >&2; }

usage() {
    cat <<'EOF'
Usage: release.sh <version> [--until <step> | --redo-from <step> | --clean]

Steps in order: archive export verify dmg notary staple zip appcast upload site

--until <step>  stop AFTER <step> (publish-gate: `--until appcast` builds +
                notarizes but does NOT touch R2/site; resume with a plain re-run
                once the human confirm in /release-leaf passes).
site = редеплой leaf-web (sibling checkout или LEAF_WEB_DIR).

Default: re-run skips completed steps (stamp-aware under build/releases/.stamps/).
Flags:
  --redo-from <step>   rm stamps от <step> и далее, форсит re-do tail
  --clean              rm -rf build/releases/, full rebuild

Iteration на notary fail (entitlements/signing fix):
  bash scripts/release.sh 1.0.0-alpha.1 --clean
На notary success ретрай (network blip и т.п.):
  bash scripts/release.sh 1.0.0-alpha.1 --redo-from notary

Secrets (R2_* / CF_*) — НЕ экспортируются вручную. Канон:
  vault.sh run release -- bash scripts/release.sh <version>      (live SSM)
Offline-fallback кэш (если live-env пуст):
  just secrets-refresh   # → ~/.config/leaf/release.env (0600, вне репо)

Required tools: xcodebuild, codesign, jq, xmllint, create-dmg, ditto,
                ~/bin/sparkle/generate_appcast, ~/bin/sparkle/sign_update
                xcrun notarytool (keychain-profile "leaf-notary" из Phase 3.0)
EOF
}

# --- constants (defined before the lib-only seam so the self-test can reach
#     assert_secrets / maybe_load_cached_secrets / run_pipeline) --------------
REQUIRED_UPLOAD_SECRETS=(R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY CF_ZONE_ID CF_API_TOKEN)
STEPS=(archive export verify dmg notary staple zip appcast upload site)
# Parsed args (init so functions / the self-test never trip `set -u`).
VERSION=""; REDO_FROM=""; CLEAN_FIRST=""; UNTIL=""

# --- secrets --------------------------------------------------------------
# Offline fallback: load the cached env-file ONLY when the live env is empty, so
# `vault.sh run release` (the primary live-SSM path) always wins and a stale cache
# can never shadow fresh secrets.
maybe_load_cached_secrets() {
    [[ -n "${R2_BUCKET:-}" ]] && return 0
    local cache="${LEAF_RELEASE_ENV_CACHE:-$HOME/.config/leaf/release.env}"
    [[ -f "$cache" ]] || return 0   # no cache → assert_secrets fails loudly next
    local when
    if when="$(stat -f '%Sm' -t '%Y-%m-%d' "$cache" 2>/dev/null)"; then :
    elif when="$(stat -c '%y' "$cache" 2>/dev/null)"; then when="${when%% *}"
    else when="?"; fi
    warn "using CACHED secrets from $cache (dated $when) — live SSM env is empty."
    warn "  if keys were rotated, refresh with: just secrets-refresh"
    # Parse KEY=VALUE safely with `export`, NOT `source`: a value with spaces (a
    # signing identity) would execute as a command under `source`. IFS='=' read -r
    # splits on the FIRST '=' only, so '=' inside a value survives.
    local k v
    # `|| [[ -n "$k" ]]` processes a final line that lacks a trailing newline
    # (read returns non-zero but still populated k/v) — else the last key (could be
    # LEAF_SIGN_ID, which is not in REQUIRED_UPLOAD_SECRETS) would be silently dropped.
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        case "$k" in ''|'#'*) continue ;; esac
        export "$k=$v"
    done < "$cache"
}

# Fail fast — before archive/notary — if any upload secret is missing. Runs
# unconditionally (even for --until appcast): the whole flow is meant to run under
# `vault.sh run release`, so a missing secret means a misconfigured invocation, and
# a no-secrets dry-run is exactly the Phase 2 fast-fail test.
assert_secrets() {
    local missing=() v
    for v in "${REQUIRED_UPLOAD_SECRETS[@]}"; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "missing release secrets: ${missing[*]}"
        err "Run under SSM secrets:  vault.sh run release -- bash scripts/release.sh ..."
        err "or seed the offline cache:  just secrets-refresh"
        exit 1
    fi
}

# --- pipeline runner ------------------------------------------------------
# Single loop over STEPS; --until exits AFTER the named step (publish-gate). An
# empty UNTIL short-circuits the test, so a plain run does the full pipeline.
# (The `==` here needs the spaces + quotes — `"$s"==$UNTIL` would be one truthy
# [[ ]] arg and exit after the first step.)
run_pipeline() {
    local s
    for s in "${STEPS[@]}"; do
        "step_$s"
        if [[ -n "${UNTIL:-}" && "$s" == "${UNTIL:-}" ]]; then
            ok "--until ${UNTIL}: stopped after step '$s' (publish steps NOT run)"
            return 0
        fi
    done
}

# Enforce the Ordering invariant (the critical Phase 2 property): the COMMITTED
# releases.json must already carry the version being built BEFORE step_archive
# bundles it as-is (PBXFileSystemSynchronizedRootGroup copies the file verbatim).
# The /release-leaf PREP step regenerates it; this guard makes a skipped/out-of-order
# PREP fail fast instead of silently shipping in-app "What's New" + the dashboard one
# version behind. Test seam: LEAF_RESOURCES_JSON (mirrors gen-release-notes.sh).
assert_releases_json_matches_version() {
    local f="${LEAF_RESOURCES_JSON:-$REPO_ROOT/Leaf/Resources/releases.json}"
    [[ -f "$f" ]] || { err "committed releases.json missing: $f — run: just gen-notes"; exit 1; }
    local newest
    newest="$(jq -r '.releases[0].version // ""' "$f" 2>/dev/null || true)"
    if [[ "$newest" != "$VERSION" ]]; then
        err "releases.json stale: newest entry is '$newest', building '$VERSION'."
        err "Run PREP first: bump-version.sh $VERSION + CHANGELOG-cut + just gen-notes (see /release-leaf)."
        exit 1
    fi
    ok "releases.json newest entry == $VERSION (Ordering invariant)"
}

# Move every *.dmg.appcast-hidden in $RELEASES back to *.dmg. Stateless +
# idempotent (glob, NOT an in-memory array — sidesteps the Bash 3.2 empty-array
# `set -u` crash), so it serves both the on-entry heal of a prior kill -9 AND the
# step_appcast trap. $RELEASES is set in the paths section before any step runs.
restore_hidden_dmgs() {
    local h
    for h in "$RELEASES"/*.dmg.appcast-hidden; do
        [[ -f "$h" ]] || continue   # literal glob (no match) → skip cleanly
        mv -f "$h" "${h%.appcast-hidden}"
    done
}

# --- test seam ------------------------------------------------------------
# Source with LEAF_RELEASE_LIB_ONLY=1 to load the functions above WITHOUT running
# the arg-parser or the pipeline — scripts/tests/test-release-flow.sh drives
# run_pipeline / assert_secrets / maybe_load_cached_secrets in isolation.
if [[ "${LEAF_RELEASE_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# --- arg parsing ----------------------------------------------------------
[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

VERSION="$1"; shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --redo-from) REDO_FROM="${2:?--redo-from requires step name}"; shift 2 ;;
        --until)     UNTIL="${2:?--until requires step name}"; shift 2 ;;
        --clean)     CLEAN_FIRST=1; shift ;;
        *)           err "unknown arg: $1"; usage; exit 1 ;;
    esac
done

# Validate --until against the known steps (same discipline as --redo-from).
if [[ -n "$UNTIL" ]]; then
    until_found=0
    for s in "${STEPS[@]}"; do [[ "$s" == "$UNTIL" ]] && until_found=1; done
    [[ $until_found -eq 1 ]] || { err "--until $UNTIL: not a known step (${STEPS[*]})"; exit 1; }
fi

# --- paths ----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES="$REPO_ROOT/build/releases"
STAMPS="$RELEASES/.stamps"
ARCHIVE="$RELEASES/Leaf-$VERSION.xcarchive"
EXPORTED="$RELEASES/exported"
APP="$EXPORTED/Leaf.app"
DMG="$RELEASES/Leaf-$VERSION.dmg"
ZIP="$RELEASES/Leaf-$VERSION.zip"

SIGN_ID="${LEAF_SIGN_ID:-Developer ID Application: <YOUR NAME> (<TEAM_ID>)}"  # set LEAF_SIGN_ID in your env/Local config (kept out of the public repo)
NOTARY_PROFILE="leaf-notary"

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
        err "Bump pbxproj first (scripts/bump-version.sh $VERSION), then re-run."
        exit 1
    fi
    ok "version $VERSION matches pbxproj"
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

    # Drop embedded Development provisioning profile (Xcode archive embeds dev-profile
    # by default; Developer ID distribution does NOT require profile + dev profile
    # contains ProvisionedDevices whitelist that blocks LaunchServices spawn on any
    # Mac other than the maintainer's via POSIX 163 / Launchd job spawn failed). Codesign
    # re-sign на следующем шаге восстановит integrity без profile reference.
    rm -f "$APP/Contents/embedded.provisionprofile"

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
    # Re-sign Leaf.app с release-distribution entitlements (sandbox=false only).
    # Leaf/Leaf.entitlements содержит profile-gated keys (application-identifier,
    # team-identifier, aps-environment, keychain-access-groups) для Xcode Run dev
    # loop. Distribution bundle MUST strip их — AMFI rejects spawn если они
    # present без authorizing provisioning profile (POSIX 163 / "Launchd job
    # spawn failed" на любом Mac кроме build machine). См.
    # Config/Release/Leaf.release.entitlements header comment.
    "${cs[@]}" --entitlements "$REPO_ROOT/Config/Release/Leaf.release.entitlements" "$APP" >/dev/null

    # Defensive verify: entitlements blob must NOT contain AMFI triggers.
    local restricted
    restricted=$(codesign -d --entitlements - "$APP" 2>&1 | grep -E "application-identifier|developer\.team-identifier|aps-environment|keychain-access-groups" || true)
    if [[ -n "$restricted" ]]; then
        err "AMFI-restricted entitlements found in signed Leaf.app — bundle would fail to spawn on non-whitelisted Macs."
        err "$restricted"
        exit 1
    fi
    ok "entitlements blob clean — no AMFI triggers"

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
    # Standard drag-to-Applications layout: app-icon left, Applications symlink right.
    # 540×380 window, 128 px icons, vertically centered around y=190.
    create-dmg \
        --volname "Leaf $VERSION" \
        --window-size 540 380 \
        --icon-size 128 \
        --icon "Leaf.app" 140 190 \
        --app-drop-link 400 190 \
        "$DMG" "$RELEASES/dmg-source" >/dev/null 2>&1 || true
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
    # SHA-256 рядом с .dmg — публикуется на R2, сайт ссылается из dashboard
    # checksums. Считаем ПОСЛЕ staple (stapler меняет байты .dmg).
    (cd "$RELEASES" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
    mark_done zip
    ok "zip done ($(du -h "$ZIP" | cut -f1)) + dmg sha256"
}

step_appcast() {
    is_done appcast && { info "skip appcast (stamp exists)"; return 0; }

    # Interrupt-recovery: a prior run killed (incl. kill -9, which can't be trapped)
    # between hide and restore leaves *.dmg.appcast-hidden with the stamp unset.
    # Un-hide on entry so the DMG is never permanently stranded (a stamped-but-missing
    # DMG would otherwise upload to R2 without an installer).
    restore_hidden_dmgs

    # Embed the current version's "What's New" fragment into the signed appcast.
    # gen-release-notes runs here (not earlier) because --clean/apply_flags in main
    # would have rm-rf'd build/releases/ before this step; the stamp covers both
    # the .html render and generate_appcast. (releases.json is the PREP step's job —
    # the Ordering invariant — NOT regenerated here.)
    info "release notes → $RELEASES/Leaf-$VERSION.html"
    bash "$REPO_ROOT/scripts/gen-release-notes.sh" --html-only "$VERSION"
    [[ -f "$RELEASES/Leaf-$VERSION.html" ]] || { err "gen-release-notes did not produce Leaf-$VERSION.html"; exit 1; }

    info "generate_appcast → $RELEASES/appcast.xml"
    # generate_appcast не любит .dmg + .zip с одинаковым CFBundleVersion (duplicate
    # updates). Sparkle update path = .zip; .dmg = first install only. Прячем ВСЕ
    # .dmg на время генерации. A trap restores them even on Ctrl-C / SIGTERM so an
    # interrupted run never strands the DMG as *.dmg.appcast-hidden.
    trap 'restore_hidden_dmgs' EXIT INT TERM
    local dmg
    for dmg in "$RELEASES"/*.dmg; do
        [[ -f "$dmg" ]] || continue   # literal glob (no .dmg) → nothing to hide
        mv "$dmg" "$dmg.appcast-hidden"
    done

    local rc=0
    ~/bin/sparkle/generate_appcast \
        --embed-release-notes \
        --download-url-prefix https://updates.gundem.tech/releases/ \
        "$RELEASES/" >/dev/null || rc=$?

    restore_hidden_dmgs
    trap - EXIT INT TERM

    [[ $rc -eq 0 ]] || { err "generate_appcast failed (rc=$rc)"; exit $rc; }
    xmllint --noout "$RELEASES/appcast.xml"
    local item_count
    item_count=$(xmllint --xpath 'count(//item)' "$RELEASES/appcast.xml" 2>/dev/null || echo 0)
    [[ "$item_count" -ge 1 ]] || { err "appcast.xml содержит 0 <item>"; exit 1; }
    # Embed sanity: the generated item must carry <description> (the embedded notes).
    # A silent embed failure would show an empty Sparkle update dialog — fail loud.
    grep -q '<description>' "$RELEASES/appcast.xml" || { err "appcast.xml <item> has no <description> — release notes did not embed"; exit 1; }
    # DMG must be back before the stamp: a stamped-but-missing DMG would make a
    # resumed upload ship without an installer.
    [[ -f "$DMG" ]] || { err "Leaf-$VERSION.dmg missing after appcast (interrupted hide/restore?) — re-run"; exit 1; }
    mark_done appcast
    ok "appcast done ($item_count <item> entries, notes embedded)"
}

step_upload() {
    is_done upload && { info "skip upload (stamp exists)"; return 0; }
    assert_secrets
    info "upload → R2 + CF cache purge"
    bash "$REPO_ROOT/scripts/upload-release.sh" "$RELEASES" "$VERSION"
    mark_done upload
    ok "upload done"
}

step_site() {
    # Сайт берёт версию из appcast при сборке (leaf-web src/lib/version.ts) —
    # редеплой сайта сразу после upload держит версию на leaf.gundem.tech
    # всегда актуальной. Без leaf-web рядом — warn, релиз не блокируем.
    is_done site && { info "skip site (stamp exists)"; return 0; }
    local web_dir="${LEAF_WEB_DIR:-$REPO_ROOT/../leaf-web}"
    if [[ ! -f "$web_dir/scripts/deploy.sh" ]]; then
        warn "leaf-web checkout не найден ($web_dir) — сайт остался со старой версией."
        warn "Клонируй gundemtech/leaf-web рядом (или LEAF_WEB_DIR=...) и запусти scripts/deploy.sh."
        return 0
    fi
    info "site: жду пока CDN отдаст appcast с $VERSION (purge propagation)"
    local i
    for i in {1..12}; do
        curl -fsS https://updates.gundem.tech/appcast.xml | grep -q ">$VERSION<" && break
        if [[ $i -eq 12 ]]; then
            err "CDN не отдаёт appcast $VERSION спустя 120s — сайт задеплоит старую версию. Проверь purge."
            exit 1
        fi
        sleep 10
    done
    # Phase 4 contract — refresh leaf-web's committed last-known releases.json so the
    # site's build-time version source (src/lib/version.ts) matches this ship. Source
    # is the committed copy (build/releases/ may have been --clean'd). leaf-web reads a
    # local file, not the network, so standalone site builds stay deterministic.
    local committed_json="$REPO_ROOT/Leaf/Resources/releases.json"
    if [[ -f "$committed_json" && -d "$web_dir/src/data" ]]; then
        cp "$committed_json" "$web_dir/src/data/releases.json"
        info "site: refreshed leaf-web/src/data/releases.json → $VERSION"
    else
        warn "site: leaf-web/src/data not found — version.ts will use its committed releases.json"
    fi
    info "site: деплой leaf-web (билд подтянет $VERSION из appcast)"
    bash "$web_dir/scripts/deploy.sh"
    # Независимая пост-проверка (не доверяем exit code деплоя): живой сайт
    # обязан показывать именно $VERSION, иначе step не stamp'ится и re-run повторит.
    local live_ver
    live_ver=$(curl -fsS https://leaf.gundem.tech/ | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1 || true)
    if [[ "$live_ver" != "v$VERSION" ]]; then
        err "site verify failed: live=$live_ver, ожидалось v$VERSION — step не закрыт, re-run после фикса"
        exit 1
    fi
    mark_done site
    ok "site deployed — leaf.gundem.tech показывает v$VERSION"
}

# --- main -----------------------------------------------------------------
maybe_load_cached_secrets
# SIGN_ID was captured at parse time, BEFORE the cache loader could export
# LEAF_SIGN_ID — re-resolve so the offline-cache path signs with the real
# identity instead of the placeholder (live-env path is unaffected).
SIGN_ID="${LEAF_SIGN_ID:-$SIGN_ID}"
assert_secrets
require_tools
assert_signing_identity
assert_version_matches_pbxproj
assert_releases_json_matches_version
apply_flags

run_pipeline

if [[ -z "$UNTIL" ]]; then
    ok "release $VERSION done. Artifacts: $RELEASES/"
    echo "  Leaf-$VERSION.dmg  ($(du -h "$DMG" | cut -f1))"
    echo "  Leaf-$VERSION.zip  ($(du -h "$ZIP" | cut -f1))"
    echo "  appcast.xml         (live: https://updates.gundem.tech/appcast.xml)"
fi
