#!/usr/bin/env bash
# moat-archive.sh — shared helpers for the moat-sync / moat-push backup archive.
# Sourced (not executed) by scripts/moat-sync.sh and scripts/moat-push.sh.
# Bash 3.2 compatible (macOS default).

# leaf_moat_archive_dir
# Echoes the directory where moat backups live. Overridable via env for tests /
# alternate layouts; defaults to the historical hardcoded location.
leaf_moat_archive_dir() {
  printf '%s\n' "${LEAF_MOAT_ARCHIVE_DIR:-$HOME/Desktop/Leaf/_moat-archive}"
}

# leaf_moat_keep
# Echoes how many timestamped backups to retain. Overridable via env.
leaf_moat_keep() {
  printf '%s\n' "${LEAF_MOAT_ARCHIVE_KEEP:-10}"
}

# leaf_moat_gc_autobackups <archive_dir> <keep>
# Removes all but the newest <keep> `*autobackup-*` dirs in <archive_dir>,
# ordered by MODIFICATION TIME (not name) so the `push-autobackup-*` prefix
# can't keep a stale backup alive over a newer `autobackup-*`.
leaf_moat_gc_autobackups() {
  local dir="$1" keep="${2:-10}" count=0 d
  [ -d "$dir" ] || return 0
  # newest-first by mtime; ls -d keeps dir entries, -1 one per line.
  for d in $(ls -1dt "$dir"/*autobackup-* 2>/dev/null || true); do
    [ -d "$d" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      rm -rf "$d"
    fi
  done
}
