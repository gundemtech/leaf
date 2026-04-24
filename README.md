# Leaf

Ambient memory layer for developer teams on macOS (далее iOS).

Продуктовая документация, архитектура и философия — в публичном whitepaper: **[leaf-docs.gundem.tech](https://leaf-docs.gundem.tech)**.

## Build

```bash
xcodebuild -project Leaf.xcodeproj -scheme Leaf -destination 'platform=macOS' build
```

## Structure

```
Leaf/               # main app target (MenuBarExtra + Settings + Sparkle owner)
LeafAgent/          # launch agent CLI — event collector + SQLCipher writer
LeafMCP/            # stdio MCP server — exposes insights to AI clients
Packages/LeafCore/  # shared SPM library (public API, domain types)
```

## MCP integration (Claude Code)

Leaf ships a stdio MCP server (`LeafMCP`) embedded in the app
bundle. After running the app and enabling background collection, register
the server with Claude Code.

**If the app is installed into `/Applications`:**

```bash
claude mcp add --transport stdio --scope user leaf -- \
  /Applications/Leaf.app/Contents/MacOS/LeafMCP
```

**Dev build (DerivedData, nothing installed):**

```bash
MCP=$(find ~/Library/Developer/Xcode/DerivedData \
      -name LeafMCP -type f -path '*/Leaf.app/*' | head -1)
claude mcp add --transport stdio --scope user leaf -- "$MCP"
```

Verify:

```bash
claude mcp list        # leaf: ... ✓ Connected
```

In a new Claude Code session ask natural-language questions — e.g.
*"что я делал сегодня?"* — and Claude calls `get_timeline` under the hood.
The MCP server reads the same local database as the MenuBar app; raw metadata
never leaves the device.

**Supported tools (Phase 1):**

- `get_timeline(period: today | yesterday | last_7_days)` — top applications
  by active time for the given period.

More tools (`find_last_activity`, `get_team_timeline`, …) ship in later phases.

## License

TBD
