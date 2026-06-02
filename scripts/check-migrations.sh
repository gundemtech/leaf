#!/usr/bin/env bash
# check-migrations.sh — linearity guard for GRDB migrations (R3).
#
# Root cause this prevents: the M024↔M028 / M026↔M029 split, where parallel
# branches reused migration NUMBERS, producing duplicate / out-of-sequence
# identifiers in grdb_migrations. This guard fails the build if the registered
# migrations are not a contiguous, duplicate-free, in-order M001..MNNN sequence.
#
# Three independent sources must agree (catches rename drift, e.g. a 030-named
# method that registers a "029_..." identifier string):
#   1. filename prefix          — Mnnn_*.swift in DB/Migrations/
#   2. identifier string        — registerMigration("nnn_...") inside each file
#   3. registration call order  — migrator.registerMigrationNNN...() in Database.swift
#
# Overridable for the self-test via LEAF_MIG_DIR / LEAF_MIG_REGFILE.
# Bash 3.2 compatible (macOS default + ubuntu CI). No associative arrays.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIG_DIR="${LEAF_MIG_DIR:-$REPO_ROOT/Packages/LeafCore/Sources/LeafCore/DB/Migrations}"
REG_FILE="${LEAF_MIG_REGFILE:-$REPO_ROOT/Packages/LeafCore/Sources/LeafCore/DB/Database.swift}"

fail() { echo "✘ check-migrations: $1" >&2; exit 1; }

[[ -d "$MIG_DIR" ]]  || fail "migrations dir not found: $MIG_DIR"
[[ -f "$REG_FILE" ]] || fail "registration file not found: $REG_FILE"

# --- 1. Filename prefixes + per-file identifier-string agreement -------------
nums=""
for f in "$MIG_DIR"/M[0-9][0-9][0-9]_*.swift; do
    [[ -e "$f" ]] || fail "no Mnnn_*.swift migration files in $MIG_DIR"
    base="$(basename "$f")"
    fn="${base:1:3}"   # NNN from Mnnn_
    idline="$(grep -oE 'registerMigration\("[0-9]{3}_[a-z0-9_]+"\)' "$f" | head -1 || true)"
    [[ -n "$idline" ]] || fail "$base: no registerMigration(\"nnn_...\") identifier string found"
    idnum="$(printf '%s' "$idline" | grep -oE '[0-9]{3}' | head -1)"
    [[ "$fn" == "$idnum" ]] || fail "$base: filename prefix M$fn != identifier-string prefix ${idnum}_ (rename drift)"
    nums="$nums $fn"
done

# --- 2. Filenames contiguous 001..N, no duplicates ---------------------------
sorted="$(printf '%s\n' $nums | sort)"
dups="$(printf '%s\n' $sorted | uniq -d | tr '\n' ' ')"
[[ -z "${dups// /}" ]] || fail "duplicate migration number(s): $dups"
count="$(printf '%s\n' $nums | grep -c .)"
i=1
for n in $(printf '%s\n' $sorted | uniq); do
    expected="$(printf '%03d' "$i")"
    [[ "$n" == "$expected" ]] || fail "non-contiguous filenames: expected M$expected, got M$n (gap or out-of-sequence)"
    i=$((i + 1))
done

# --- 3. Registration call order in Database.swift ----------------------------
# Method names are registerMigrationNNN<CamelName>() where the name may itself
# contain digits (e.g. registerMigration026S8Substrate) — match a leading capital
# then any alnum, and extract only the 3 digits immediately after registerMigration.
regnums="$(grep -oE 'registerMigration[0-9]{3}[A-Z][A-Za-z0-9]*\(\)' "$REG_FILE" \
    | sed -E 's/registerMigration([0-9]{3}).*/\1/' || true)"
[[ -n "$regnums" ]] || fail "no registerMigrationNNN...() calls found in $(basename "$REG_FILE")"
i=1
for n in $regnums; do
    expected="$(printf '%03d' "$i")"
    [[ "$n" == "$expected" ]] || fail "registration order: expected registerMigration$expected at position $i, got registerMigration$n (dup/gap/out-of-order)"
    i=$((i + 1))
done
regcount=$((i - 1))
[[ "$regcount" == "$count" ]] || fail "registration count ($regcount) != migration-file count ($count)"

echo "✓ check-migrations: $count migrations linear M001..M$(printf '%03d' "$count") (filenames, identifier strings, registration order all aligned)."
