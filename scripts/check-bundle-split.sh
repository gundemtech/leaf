#!/usr/bin/env bash
# check-bundle-split.sh — regression guard for the Debug/prod bundle-id split (#26).
#
# Debug builds MUST use a distinct ".debug" PRODUCT_BUNDLE_IDENTIFIER so they can
# never share the prod LaunchServices namespace or clobber the prod SQLCipher DB
# (the "after every Sparkle update everything breaks" root cause). Release configs
# MUST stay on the plain prod id. This guard fails CI/preflight if anyone ever
# re-unifies them (e.g. a careless pbxproj merge).
#
# Rule, per XCBuildConfiguration that declares a PRODUCT_BUNDLE_IDENTIFIER:
#   name = Debug;   -> bundle id MUST contain ".debug"
#   name = Release; -> bundle id MUST NOT contain ".debug"
# Plus a sanity floor: at least one Debug and one Release id must be found.
set -euo pipefail

PBX="${1:-Leaf.xcodeproj/project.pbxproj}"
[ -f "$PBX" ] || { printf '\033[31m✘ pbxproj not found: %s\033[0m\n' "$PBX"; exit 1; }

awk '
  /isa = XCBuildConfiguration;/ { bid="" }
  /PRODUCT_BUNDLE_IDENTIFIER = / {
    v=$0
    sub(/.*PRODUCT_BUNDLE_IDENTIFIER = /, "", v)
    sub(/;.*/, "", v)
    gsub(/[ \t]/, "", v)
    bid=v
  }
  /name = Debug;/ {
    if (bid != "") {
      dbg++
      if (index(bid, ".debug") == 0) { print "✘ Debug config carries a non-.debug bundle id: " bid; bad++ }
    }
  }
  /name = Release;/ {
    if (bid != "") {
      rel++
      if (index(bid, ".debug") > 0) { print "✘ Release config carries a .debug bundle id: " bid; bad++ }
    }
  }
  END {
    if (dbg == 0 || rel == 0) {
      print "✘ bundle-split guard: expected both Debug and Release ids (dbg=" dbg " rel=" rel ")"
      exit 1
    }
    if (bad > 0) { exit 1 }
    print "✓ bundle-split intact — " dbg " Debug (.debug) / " rel " Release (prod) configs"
  }
' "$PBX"
