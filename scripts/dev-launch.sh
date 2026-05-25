#!/usr/bin/env bash
# dev-launch.sh — idempotent Debug launch для Leaf macOS app.
#
# Решает 3 рекуррентные проблемы dev workflow:
#   1. /Applications/Leaf.app (prod alpha install) hijack'ит LaunchServices →
#      Xcode ⌘R открывает stale бинарник, не свежий Debug build.
#   2. SMAppService регистрирует LeafAgent под старый bundle path → launchd
#      respawn'ит залипшую копию, новый Debug билд не запускается.
#   3. CDHash main app vs Agent могут разойтись → одна TCC entry актуальна,
#      другая stale → молчаливый detect fail.
#
# Скрипт ничего не делает с TCC (для этого — dev-reset-tcc.sh).
# Безопасен дважды подряд. Печатает CDHash обоих бинарников до запуска,
# чтобы видно было что именно загрузится.
#
# Usage: just dev   (or ./scripts/dev-launch.sh from repo root)

set -euo pipefail

SCHEME="Leaf"
CONFIG="Debug"
BUNDLE_ID="tech.gundem.leaf"
AGENT_BUNDLE_ID="tech.gundem.leaf.agent"
PROD_APP="/Applications/Leaf.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

cyan()   { printf '\033[36m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

# --- Step 1: resolve DerivedData Debug build path -----------------------------
cyan "[1/7] Resolving Debug build path via xcodebuild..."
BUILD_DIR=$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | awk '/^[[:space:]]*BUILT_PRODUCTS_DIR =/ { print $3; exit }')
if [[ -z "${BUILD_DIR:-}" ]]; then
    red "  could not resolve BUILT_PRODUCTS_DIR for scheme=$SCHEME config=$CONFIG"
    red "  run \`xcodebuild -scheme $SCHEME -configuration $CONFIG build\` first?"
    exit 1
fi
DEBUG_APP="$BUILD_DIR/Leaf.app"
if [[ ! -d "$DEBUG_APP" ]]; then
    red "  Debug build missing at $DEBUG_APP"
    red "  run \`just build-all\` (or Xcode ⌘B) first"
    exit 1
fi
green "  → $DEBUG_APP"

# --- Step 2: kill stale Agent processes ---------------------------------------
cyan "[2/7] Killing stale LeafAgent processes..."
if pgrep -f "$AGENT_BUNDLE_ID" >/dev/null 2>&1; then
    pkill -f "$AGENT_BUNDLE_ID" 2>/dev/null || true
    sleep 1
    if pgrep -f "$AGENT_BUNDLE_ID" >/dev/null 2>&1; then
        yellow "  some Agent process survived (launchd may respawn — re-check below)"
    else
        green "  all Agent processes terminated"
    fi
else
    green "  no Agent processes running"
fi

# --- Step 3: unregister /Applications/Leaf.app if present ---------------------
cyan "[3/7] Checking for /Applications/Leaf.app hijack..."
if [[ -e "$PROD_APP" ]]; then
    yellow "  found $PROD_APP — unregistering from LaunchServices"
    "$LSREGISTER" -u "$PROD_APP" 2>&1 | sed 's/^/    /' || true
    yellow "  prod alpha unregistered; re-register via Finder double-click if needed later"
else
    green "  no /Applications/Leaf.app — nothing to unregister"
fi

# --- Step 4: register Debug build with force flag -----------------------------
cyan "[4/7] Registering Debug build with LaunchServices..."
"$LSREGISTER" -f -R "$DEBUG_APP" 2>&1 | sed 's/^/    /' || true
green "  Debug build registered"

# --- Step 5: print CDHash both binaries ---------------------------------------
cyan "[5/7] CDHash fingerprints (must match if same signing identity):"
MAIN_BIN="$DEBUG_APP/Contents/MacOS/Leaf"
AGENT_BIN="$DEBUG_APP/Contents/MacOS/LeafAgent"
if [[ -e "$MAIN_BIN" ]]; then
    MAIN_HASH=$(codesign -dvv "$MAIN_BIN" 2>&1 | awk -F'=' '/^CDHash=/ {print $2; exit}')
    printf '  main app  : %s\n' "${MAIN_HASH:-<unsigned/unreadable>}"
else
    red "  main app binary missing at $MAIN_BIN"
fi
if [[ -e "$AGENT_BIN" ]]; then
    AGENT_HASH=$(codesign -dvv "$AGENT_BIN" 2>&1 | awk -F'=' '/^CDHash=/ {print $2; exit}')
    printf '  agent     : %s\n' "${AGENT_HASH:-<unsigned/unreadable>}"
else
    red "  agent binary missing at $AGENT_BIN"
fi

# --- Step 6: open Debug build -------------------------------------------------
cyan "[6/7] Opening Debug build..."
open "$DEBUG_APP"
sleep 2
if pgrep -f "$BUNDLE_ID" >/dev/null 2>&1; then
    green "  main app launched (PID $(pgrep -f "$BUNDLE_ID" | head -1))"
else
    yellow "  main app not detected via pgrep yet (may still be launching)"
fi
if pgrep -f "$AGENT_BUNDLE_ID" >/dev/null 2>&1; then
    AGENT_PID=$(pgrep -f "$AGENT_BUNDLE_ID" | head -1)
    AGENT_PATH=$(lsof -p "$AGENT_PID" 2>/dev/null | awk '/txt.*LeafAgent$/ {print $NF; exit}')
    green "  agent running (PID $AGENT_PID)"
    if [[ -n "${AGENT_PATH:-}" ]]; then
        printf '    binary : %s\n' "$AGENT_PATH"
        if [[ "$AGENT_PATH" != "$AGENT_BIN" ]]; then
            red "    ⚠ agent NOT running from Debug build path!"
            red "      this is the hijack symptom — SMAppService still bound to stale plist"
            red "      try \`pkill -9 -f $AGENT_BUNDLE_ID && rm -rf $PROD_APP\` and re-run"
        fi
    fi
else
    yellow "  agent not yet detected (SMAppService respawn cadence ~5s)"
fi

# --- Step 7: tail log -------------------------------------------------------
cyan "[7/7] Streaming Agent log — Ctrl-C to detach (app keeps running)"
exec log stream --predicate 'subsystem == "tech.gundem.leaf.agent"' --info
