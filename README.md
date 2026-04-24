# LeafControl

Ambient memory layer for developer teams on macOS (далее iOS).

Продуктовая документация, архитектура и философия — в публичном whitepaper: **[leaf-docs.gundem.tech](https://leaf-docs.gundem.tech)**.

## Build

```bash
xcodebuild -project LeafControl.xcodeproj -scheme LeafControl -destination 'platform=macOS' build
```

## Structure

```
LeafControl/               # main app target (MenuBarExtra + Settings + Sparkle owner)
LeafControlAgent/          # launch agent CLI — event collector + SQLCipher writer
LeafControlMCP/            # stdio MCP server — exposes insights to AI clients
Packages/LeafControlCore/  # shared SPM library (public API, domain types)
```

## MCP integration (Claude Code)

LeafControl ships a stdio MCP server (`LeafControlMCP`) embedded in the app
bundle. After running the app and enabling background collection, register
the server with Claude Code.

**If the app is installed into `/Applications`:**

```bash
claude mcp add --transport stdio --scope user leafcontrol -- \
  /Applications/LeafControl.app/Contents/MacOS/LeafControlMCP
```

**Dev build (DerivedData, nothing installed):**

```bash
MCP=$(find ~/Library/Developer/Xcode/DerivedData \
      -name LeafControlMCP -type f -path '*/LeafControl.app/*' | head -1)
claude mcp add --transport stdio --scope user leafcontrol -- "$MCP"
```

Verify:

```bash
claude mcp list        # leafcontrol: ... ✓ Connected
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
