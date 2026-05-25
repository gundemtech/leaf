#!/usr/bin/env bash
# dev-reset-tcc.sh — destructive TCC reset для Leaf dev workflow.
#
# Сбрасывает Accessibility grants под bundle ID main app + Agent. После reset
# первый запуск Agent вызовет system AX dialog (см. Agent.swift:45-47 —
# AXIsProcessTrustedWithOptions с kAXTrustedCheckOptionPrompt).
#
# Нужен когда CDHash drift накопился настолько, что свежий build систематически
# silent-denied несмотря на «галку ON» в System Settings. Также сбрасывает
# /Applications/Leaf.app полностью если present — иначе SMAppService продолжит
# resolve'ить путь к stale бинарю.
#
# Usage: just dev-clean   (или ./scripts/dev-reset-tcc.sh)

set -euo pipefail

BUNDLE_ID="tech.gundem.leaf"
AGENT_BUNDLE_ID="tech.gundem.leaf.agent"
PROD_APP="/Applications/Leaf.app"

yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

red "⚠ DESTRUCTIVE: reset Accessibility TCC для $BUNDLE_ID + $AGENT_BUNDLE_ID"
red "  после reset потребуется заново grant в System Settings → Privacy & Security → Accessibility"
if [[ -e "$PROD_APP" ]]; then
    red "  + удалит $PROD_APP (prod alpha install, root-owned)"
fi
read -r -p "Продолжить? [y/N] " ans
case "${ans:-}" in
    [yY]|[yY][eE][sS]) ;;
    *) yellow "aborted"; exit 0 ;;
esac

# --- TCC reset ----------------------------------------------------------------
yellow "Resetting Accessibility TCC..."
tccutil reset Accessibility "$BUNDLE_ID" 2>&1 | sed 's/^/  /' || true
tccutil reset Accessibility "$AGENT_BUNDLE_ID" 2>&1 | sed 's/^/  /' || true
green "  TCC reset done"

# --- /Applications/Leaf.app cleanup -------------------------------------------
if [[ -e "$PROD_APP" ]]; then
    yellow "Removing $PROD_APP (requires sudo)..."
    sudo rm -rf "$PROD_APP"
    green "  $PROD_APP removed"
fi

# --- Kill any running Agent ---------------------------------------------------
if pgrep -f "$AGENT_BUNDLE_ID" >/dev/null 2>&1; then
    yellow "Killing running Agent..."
    pkill -9 -f "$AGENT_BUNDLE_ID" 2>/dev/null || true
fi

green "Done. Run \`just dev\` to launch Debug build."
