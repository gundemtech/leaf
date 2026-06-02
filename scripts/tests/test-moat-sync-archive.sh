#!/usr/bin/env bash
# test-moat-sync-archive.sh — moat-sync.sh must (a) honor LEAF_MOAT_ARCHIVE_DIR
# for its build-path autobackup and (b) garbage-collect old autobackups, so the
# secret-tree backups don't accumulate without bound. Runs the REAL script
# against a local bare-remote leaf-private clone (pull --ff-only is a no-op),
# with HOME isolated and xcodebuild/swift stubbed for speed. First coverage for
# moat-sync (also guards the Step-5 leak-clean assertion). Bash 3.2 compatible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SYNC="$REPO_ROOT/scripts/moat-sync.sh"
fail() { echo "✘ test-moat-sync-archive: FAIL — $1"; exit 1; }

sandbox="$(mktemp -d -t leaf-moat-sync.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

export HOME="$sandbox"   # so a $HOME/... default path can't escape the sandbox
G="git -c user.email=t@t -c user.name=t -c init.defaultBranch=main -c commit.gpgsign=false"

# stub heavy no-op binaries (moat-sync Step 4 cleans caches; result is `|| true`)
stub="$sandbox/stub"; mkdir -p "$stub"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/xcodebuild"; chmod +x "$stub/xcodebuild"
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/swift";      chmod +x "$stub/swift"
export PATH="$stub:$PATH"

# leaf-private origin (bare) + working clone = $PRIVATE_DIR (pull --ff-only no-op)
origin="$sandbox/origin.git"; clone="$sandbox/clone"
$G init -q --bare "$origin"
$G init -q "$clone"
mkdir -p "$clone/Sources/LeafCorePrivate/Prod" "$clone/Tests/LeafCorePrivateTests"
echo "// moat src"  > "$clone/Sources/LeafCorePrivate/Prod/Foo.swift"
echo "// moat test" > "$clone/Tests/LeafCorePrivateTests/FooTest.swift"
( cd "$clone" && $G add -A && $G commit -q -m seed && $G remote add origin "$origin" && $G push -q -u origin main )

# fake public repo: gitignore the moat build paths; build-path matches the clone
repo="$sandbox/repo"
mkdir -p "$repo/Packages/LeafCore/Sources/LeafCorePrivate/Prod" \
         "$repo/Packages/LeafCore/Tests/LeafCorePrivateTests"
printf 'Packages/LeafCore/Sources/LeafCorePrivate/**/*.swift\nPackages/LeafCore/Tests/LeafCorePrivateTests/**/*.swift\n' \
  > "$repo/.gitignore"
echo "// moat src"  > "$repo/Packages/LeafCore/Sources/LeafCorePrivate/Prod/Foo.swift"
echo "// moat test" > "$repo/Packages/LeafCore/Tests/LeafCorePrivateTests/FooTest.swift"
( cd "$repo" && $G init -q && $G add .gitignore && $G commit -q -m init )

# pre-seed archive with 12 old autobackups (keep default = 10)
archive="$sandbox/archive"; mkdir -p "$archive"
i=1; while [ "$i" -le 12 ]; do
  d="$archive/autobackup-$(printf '%05d' "$i")"; mkdir -p "$d"
  touch -t "202606010000.$(printf '%02d' "$i")" "$d"; i=$((i + 1))
done

LEAF_PRIVATE_DIR="$clone" LEAF_MOAT_ARCHIVE_DIR="$archive" \
  bash -c "cd '$repo' && bash '$SYNC'" >/dev/null 2>&1 || fail "moat-sync.sh exited non-zero"

# a fresh backup landed in the OVERRIDDEN archive (env path honored)
newest="$(ls -1dt "$archive"/autobackup-* 2>/dev/null | head -1)"
{ [ -n "$newest" ] && [ -f "$newest/Prod/Foo.swift" ]; } \
  || fail "no fresh backup in LEAF_MOAT_ARCHIVE_DIR (env path ignored)"
# retention: 12 pre-seeded + 1 new → GC'd down to keep=10
total="$(find "$archive" -maxdepth 1 -type d -name 'autobackup-*' | wc -l | tr -d ' ')"
[ "$total" -eq 10 ] || fail "retention not applied: expected 10 autobackups, got $total"
[ ! -d "$archive/autobackup-00001" ] || fail "oldest autobackup not GC'd"
# default $HOME archive must NOT be used (override truly honored)
[ ! -d "$HOME/Desktop/Leaf/_moat-archive" ] || fail "backup leaked to default \$HOME archive despite override"

echo "✓ test-moat-sync-archive: moat-sync honors LEAF_MOAT_ARCHIVE_DIR + GCs old autobackups."
