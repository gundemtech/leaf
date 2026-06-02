#!/usr/bin/env bash
# test-check-migrations.sh — fixture-based self-test for check-migrations.sh.
# Builds throwaway migration dirs (valid / gap / dup / rename-drift / out-of-order)
# and asserts the guard passes the good one and fails each bad one.
# Bash 3.2 compatible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-migrations.sh"
tmp="$(mktemp -d -t leaf-checkmig-selftest.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0

# mk_mig <dir> <filename-num> <identifier-num>
mk_mig() {
    printf 'mutating func registerMigration%sX() {\n  registerMigration("%s_x") { db in }\n}\n' \
        "$2" "$3" > "$1/M${2}_X.swift"
}
# mk_reg <regfile> <num>...   (registration call order)
mk_reg() {
    local file="$1"; shift
    : > "$file"
    for n in "$@"; do printf '    migrator.registerMigration%sX()\n' "$n" >> "$file"; done
}
# expect <label> <want-fail 0|1> <dir> <regfile>
expect() {
    local label="$1" want="$2" dir="$3" reg="$4" rc
    set +e
    LEAF_MIG_DIR="$dir" LEAF_MIG_REGFILE="$reg" "$SCRIPT" >/dev/null 2>&1
    rc=$?
    set -e
    if { [[ "$rc" -eq 0 && "$want" -eq 0 ]]; } || { [[ "$rc" -ne 0 && "$want" -eq 1 ]]; }; then
        echo "  ✓ $label"; pass=$((pass + 1))
    else
        echo "  ✘ $label (rc=$rc, want-fail=$want)"; fail=$((fail + 1))
    fi
}

# valid 001..003
d="$tmp/ok"; mkdir -p "$d"; mk_mig "$d" 001 001; mk_mig "$d" 002 002; mk_mig "$d" 003 003
mk_reg "$tmp/ok.swift" 001 002 003
expect "linear 001..003 passes" 0 "$d" "$tmp/ok.swift"

# gap (001, 003)
d="$tmp/gap"; mkdir -p "$d"; mk_mig "$d" 001 001; mk_mig "$d" 003 003
mk_reg "$tmp/gap.swift" 001 003
expect "gap (001,003) fails" 1 "$d" "$tmp/gap.swift"

# duplicate 001 (two files both prefix 001)
d="$tmp/dup"; mkdir -p "$d"; mk_mig "$d" 001 001
printf 'registerMigration("001_y") { db in }\n' > "$d/M001_Y.swift"
mk_reg "$tmp/dup.swift" 001 001
expect "duplicate 001 fails" 1 "$d" "$tmp/dup.swift"

# cross-rename drift: M003 file carries identifier 002
d="$tmp/drift"; mkdir -p "$d"; mk_mig "$d" 001 001; mk_mig "$d" 002 002; mk_mig "$d" 003 002
mk_reg "$tmp/drift.swift" 001 002 003
expect "cross-rename drift (M003 file, id 002) fails" 1 "$d" "$tmp/drift.swift"

# registration out-of-order (files fine, regfile 001,003,002)
d="$tmp/order"; mkdir -p "$d"; mk_mig "$d" 001 001; mk_mig "$d" 002 002; mk_mig "$d" 003 003
mk_reg "$tmp/order.swift" 001 003 002
expect "registration out-of-order fails" 1 "$d" "$tmp/order.swift"

echo "check-migrations self-test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
