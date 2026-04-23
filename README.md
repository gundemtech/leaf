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

## License

TBD
