#!/usr/bin/env bash
# upload-release.sh — Leaf release artifacts → Cloudflare R2 + edge-cache purge.
#
# Phase 3.2 — pipeline для appcast.xml и release artifacts (.dmg / .zip / .delta).
# Phase 2 (release-pipeline) additions:
#   • releases.json → bucket ROOT (the dashboard + bundled in-app source). Sourced
#     from the COMMITTED Leaf/Resources/releases.json (survives release.sh --clean,
#     which rm-rf's build/releases/). Uploaded LAST (Ordering invariant): a set -e
#     failure between cp's must never expose version N to the dashboard before
#     Sparkle has the matching appcast.
#   • stable Leaf.dmg + Leaf.dmg.sha256 at the bucket root (homepage permalink that
#     dashboard.astro's DMG_URL points at — release.sh never created it before).
#
# Phase 3.3+ принимает реальные signed artifacts из generate_appcast.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMITTED_RELEASES_JSON="$REPO_ROOT/Leaf/Resources/releases.json"

usage() {
    cat <<'EOF'
Usage: upload-release.sh [RELEASES_DIR] [VERSION]

Загружает содержимое RELEASES_DIR/ в R2 bucket leaf-updates:
  RELEASES_DIR/<artifact>       → s3://$R2_BUCKET/releases/<artifact> (octet-stream)
  RELEASES_DIR/*.sha256         → s3://$R2_BUCKET/releases/<name>     (text/plain)
  RELEASES_DIR/Leaf-<VER>.dmg   → s3://$R2_BUCKET/Leaf.dmg            (stable permalink)
                                + s3://$R2_BUCKET/Leaf.dmg.sha256
  RELEASES_DIR/appcast.xml      → s3://$R2_BUCKET/appcast.xml         (application/xml, max-age=300)
  Leaf/Resources/releases.json  → s3://$R2_BUCKET/releases.json       (application/json, max-age=300, LAST)

VERSION (optional 2nd arg) picks which Leaf-<VER>.dmg becomes the stable Leaf.dmg.
Без него берётся highest-versioned *.dmg в каталоге (sort -V).

После загрузки — purge CF edge cache: appcast.xml + releases.json + Leaf.dmg(.sha256).

Required env vars — НЕ экспортируются вручную. Канон: запуск под
`vault.sh run release` (live SSM) или offline-кэш `just secrets-refresh`:
  R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY CF_ZONE_ID CF_API_TOKEN
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

: "${R2_BUCKET:?missing R2_BUCKET — run under vault.sh run release (see --help)}"
: "${R2_ENDPOINT:?missing R2_ENDPOINT — see --help}"
: "${R2_ACCESS_KEY_ID:?missing R2_ACCESS_KEY_ID — see --help}"
: "${R2_SECRET_ACCESS_KEY:?missing R2_SECRET_ACCESS_KEY — see --help}"
: "${CF_ZONE_ID:?missing CF_ZONE_ID — see --help}"
: "${CF_API_TOKEN:?missing CF_API_TOKEN — see --help}"

RELEASES_DIR="${1:-./build/releases}"
VERSION="${2:-}"

[[ -d "$RELEASES_DIR" ]] || { echo "✗ $RELEASES_DIR not found" >&2; exit 1; }
[[ -f "$RELEASES_DIR/appcast.xml" ]] || { echo "✗ appcast.xml missing in $RELEASES_DIR" >&2; exit 1; }
[[ -f "$COMMITTED_RELEASES_JSON" ]] || { echo "✗ committed releases.json missing: $COMMITTED_RELEASES_JSON (run: just gen-notes)" >&2; exit 1; }

# Helper: aws s3 cp with R2 credentials + endpoint (keeps the long flag list in
# one place). $1 src  $2 dst  $3 content-type  [$4..] extra flags.
r2_cp() {
    local src="$1" dst="$2" ctype="$3"; shift 3
    AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
    aws s3 cp "$src" "$dst" \
        --endpoint-url "$R2_ENDPOINT" \
        --region auto \
        --content-type "$ctype" \
        "$@"
}

# --- 1. distribution artifacts (.dmg / .zip / .delta) → releases/ ----------
echo "→ Uploading distribution artifacts (.dmg / .zip / .delta) to s3://$R2_BUCKET/releases/"
# Whitelist по extension: только release artifacts. recursive + --exclude "*" --include
# защищает от случайного заливания .stamps/, .xcarchive/, exported/Leaf.app/.
r2_cp "$RELEASES_DIR/" "s3://$R2_BUCKET/releases/" "application/octet-stream" \
    --recursive --exclude "*" --include "*.dmg" --include "*.zip" --include "*.delta"

# --- 2. checksum sidecars (*.sha256) → releases/ ---------------------------
echo "→ Uploading checksum files (*.sha256) to s3://$R2_BUCKET/releases/"
r2_cp "$RELEASES_DIR/" "s3://$R2_BUCKET/releases/" "text/plain" \
    --recursive --exclude "*" --include "*.sha256"

# --- 3. stable Leaf.dmg permalink (+ checksum) at bucket root --------------
# dashboard.astro / homepage point at a version-stable updates.gundem.tech/Leaf.dmg.
# Pick the current build's DMG (explicit VERSION) or the highest-versioned one.
STABLE_DMG=""
if [[ -n "$VERSION" && -f "$RELEASES_DIR/Leaf-$VERSION.dmg" ]]; then
    STABLE_DMG="$RELEASES_DIR/Leaf-$VERSION.dmg"
else
    STABLE_DMG="$(ls "$RELEASES_DIR"/Leaf-*.dmg 2>/dev/null | sort -V | tail -1 || true)"
fi
if [[ -n "$STABLE_DMG" && -f "$STABLE_DMG" ]]; then
    echo "→ Uploading stable permalink $(basename "$STABLE_DMG") → s3://$R2_BUCKET/Leaf.dmg"
    r2_cp "$STABLE_DMG" "s3://$R2_BUCKET/Leaf.dmg" "application/octet-stream" --cache-control "max-age=300"
    # Checksum labelled for the stable name so `shasum -c Leaf.dmg.sha256` matches.
    sha="$(shasum -a 256 "$STABLE_DMG" | cut -d' ' -f1)"
    tmp_sha="$(mktemp)"; printf '%s  Leaf.dmg\n' "$sha" > "$tmp_sha"
    r2_cp "$tmp_sha" "s3://$R2_BUCKET/Leaf.dmg.sha256" "text/plain" --cache-control "max-age=300"
    rm -f "$tmp_sha"
else
    echo "! no Leaf-*.dmg in $RELEASES_DIR — skipped stable Leaf.dmg permalink" >&2
fi

# --- 4. appcast.xml → bucket root ------------------------------------------
echo "→ Uploading appcast.xml to s3://$R2_BUCKET/appcast.xml"
r2_cp "$RELEASES_DIR/appcast.xml" "s3://$R2_BUCKET/appcast.xml" "application/xml" --cache-control "max-age=300"

# --- 5. releases.json → bucket root (LAST — Ordering invariant) ------------
# Uploaded after the appcast so a mid-run failure can never show the dashboard a
# version Sparkle can't yet serve. Source = committed copy (build copy is gone
# after --clean; the freshness-guard proves the two are byte-identical).
echo "→ Uploading releases.json to s3://$R2_BUCKET/releases.json (last)"
r2_cp "$COMMITTED_RELEASES_JSON" "s3://$R2_BUCKET/releases.json" "application/json" --cache-control "max-age=300"

# --- 6. purge CF edge cache on every cacheable surface ---------------------
echo "→ Purging Cloudflare edge cache (appcast.xml, releases.json, Leaf.dmg, Leaf.dmg.sha256)"
curl -fsSL -X POST \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"files":[
        "https://updates.gundem.tech/appcast.xml",
        "https://updates.gundem.tech/releases.json",
        "https://updates.gundem.tech/Leaf.dmg",
        "https://updates.gundem.tech/Leaf.dmg.sha256"
    ]}' >/dev/null

echo "✓ Uploaded → s3://$R2_BUCKET/ ; purged appcast.xml + releases.json + Leaf.dmg(.sha256)."
echo "  Verify: curl -fsSI https://updates.gundem.tech/appcast.xml"
