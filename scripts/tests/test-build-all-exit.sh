#!/usr/bin/env bash
# test-build-all-exit.sh — regression guard for the `just build-all` exit-masking
# bug. Historically build-all ran `xcodebuild … | tail -3` under `set -e`, so a
# BUILD FAILED returned tail's exit 0 and the recipe (and therefore `just
# preflight`) reported green on a broken build. This self-test stubs xcodebuild
# with an always-failing binary on PATH and asserts `just build-all` exits
# non-zero. Fast: the stub returns immediately, no real compile.
#
# Bash 3.2 compatible (macOS default).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

stubdir="$(mktemp -d -t leaf-buildall-selftest.XXXXXX)"
cleanup() { rm -rf "$stubdir"; }
trap cleanup EXIT

# Stub xcodebuild that mimics a failing build (exit 65, the xcodebuild failure code).
cat > "$stubdir/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "** BUILD FAILED ** (test stub)"
exit 65
EOF
chmod +x "$stubdir/xcodebuild"

# Prepend the stub so the recipe's `xcodebuild` resolves to it.
export PATH="$stubdir:$PATH"

if just build-all >/dev/null 2>&1; then
    echo "✘ test-build-all-exit: FAIL — build-all returned 0 despite a failing xcodebuild (exit masking is back)."
    exit 1
fi

echo "✓ test-build-all-exit: build-all correctly propagates a failing build (non-zero exit)."
