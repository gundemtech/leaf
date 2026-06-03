#!/usr/bin/env bash
# fix-launch.sh — un-wedge LaunchServices when `open Leaf` / Spotlight / a Sparkle
# relaunch resolve the name "Leaf" to a stale/broken phantom bundle instead of
# /Applications/Leaf.app (the post-Sparkle + dev-build pollution symptom: the app
# fails to come back, "is not open anymore", eventually `open` returns -600).
#
# Idempotent and safe to run any time launch breaks. Only removes REGENERABLE
# Leaf.app copies (Xcode DerivedData + repo build/). Never touches /Applications,
# ~/Downloads, or ~/.Trash — those are your files (removed manually if needed).
#
# After the debug/prod bundle-id split (tech.gundem.leaf.debug), dev builds no
# longer claim the prod id, so this should rarely be needed — it stays as the
# break-glass recovery.
set -euo pipefail

LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cyan() { printf '\033[36m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

cyan "[1/5] Stopping stray Leaf executables (app + agent + mcp)…"
pkill -f "Leaf.app/Contents/MacOS/" 2>/dev/null || true

cyan "[2/5] Removing regenerable phantom Leaf.app bundles (DerivedData + repo build/)…"
find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -name "Leaf.app" \
  -path "*/Build/Products/*" -exec rm -rf {} + 2>/dev/null || true
find ./build -name "Leaf.app" -exec rm -rf {} + 2>/dev/null || true

cyan "[3/5] Rebuilding the LaunchServices database…"
"$LSR" -r -domain local -domain user -domain system >/dev/null 2>&1 || true

cyan "[4/5] Restarting the LaunchServices daemon (clears wedged -600 state)…"
killall lsd 2>/dev/null || true

if [ -d /Applications/Leaf.app ]; then
  cyan "[5/5] Re-registering /Applications/Leaf.app as the canonical 'Leaf'…"
  "$LSR" -f /Applications/Leaf.app >/dev/null 2>&1 || true
else
  cyan "[5/5] /Applications/Leaf.app not present — skipping re-register."
fi

green "✓ Launch un-wedged."
echo "  Now launch:  open /Applications/Leaf.app"
echo "  If Spotlight still resolves wrong, also remove stray copies:"
echo "    rm -rf ~/Downloads/Leaf.app ~/.Trash/Leaf.app"
