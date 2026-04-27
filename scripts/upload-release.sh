#!/usr/bin/env bash
# upload-release.sh — Leaf release artifacts → Cloudflare R2 + edge-cache purge.
#
# Phase 3.2 — pipeline для appcast.xml и release artifacts (.dmg / .zip / .delta).
# В Phase 3.2 используется только с placeholder appcast.xml для smoke.
# В Phase 3.3+ принимает реальные signed artifacts из generate_appcast.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: upload-release.sh [RELEASES_DIR]

Загружает содержимое RELEASES_DIR/ в R2 bucket leaf-updates:
  RELEASES_DIR/appcast.xml      → s3://$R2_BUCKET/appcast.xml         (application/xml, max-age=300)
  RELEASES_DIR/<artifact>       → s3://$R2_BUCKET/releases/<artifact> (octet-stream)

После загрузки — purge CF edge cache на appcast.xml.

RELEASES_DIR (default ./build/releases) обязан содержать appcast.xml.
Сам appcast не попадает под s3://$R2_BUCKET/releases/ — его содержит --exclude.

Required env vars (export перед запуском):
  export R2_BUCKET=leaf-updates
  export R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
  export R2_ACCESS_KEY_ID=...
  export R2_SECRET_ACCESS_KEY=...
  export CF_ZONE_ID=...
  export CF_API_TOKEN=...

Values живут в GitHub Secrets repo gundemtech/leaf (`gh secret list`),
локально подгружаются вручную через `export` в текущей shell.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

: "${R2_BUCKET:?missing R2_BUCKET — see --help}"
: "${R2_ENDPOINT:?missing R2_ENDPOINT — see --help}"
: "${R2_ACCESS_KEY_ID:?missing R2_ACCESS_KEY_ID — see --help}"
: "${R2_SECRET_ACCESS_KEY:?missing R2_SECRET_ACCESS_KEY — see --help}"
: "${CF_ZONE_ID:?missing CF_ZONE_ID — see --help}"
: "${CF_API_TOKEN:?missing CF_API_TOKEN — see --help}"

RELEASES_DIR="${1:-./build/releases}"

[[ -d "$RELEASES_DIR" ]] || { echo "✗ $RELEASES_DIR not found" >&2; exit 1; }
[[ -f "$RELEASES_DIR/appcast.xml" ]] || { echo "✗ appcast.xml missing in $RELEASES_DIR" >&2; exit 1; }

echo "→ Uploading distribution artifacts (.dmg / .zip / .delta) to s3://$R2_BUCKET/releases/"
# Whitelist по extension: только release artifacts. recursive + --exclude "*" --include
# "<ext>" защищает от случайного заливания .stamps/, .xcarchive/, exported/Leaf.app/
# и прочего мусора, который release.sh пишет рядом в build/releases/.
AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
aws s3 cp "$RELEASES_DIR/" "s3://$R2_BUCKET/releases/" \
    --recursive \
    --endpoint-url "$R2_ENDPOINT" \
    --exclude "*" \
    --include "*.dmg" \
    --include "*.zip" \
    --include "*.delta" \
    --content-type "application/octet-stream"

echo "→ Uploading appcast.xml to s3://$R2_BUCKET/appcast.xml"
AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
aws s3 cp "$RELEASES_DIR/appcast.xml" "s3://$R2_BUCKET/appcast.xml" \
    --endpoint-url "$R2_ENDPOINT" \
    --content-type "application/xml" \
    --cache-control "max-age=300"

echo "→ Purging Cloudflare edge cache on appcast.xml"
curl -fsSL -X POST \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"files":["https://updates.gundem.tech/appcast.xml"]}' >/dev/null

echo "✓ Uploaded → s3://$R2_BUCKET/ ; purged appcast.xml."
echo "  Verify: curl -fsSI https://updates.gundem.tech/appcast.xml"
