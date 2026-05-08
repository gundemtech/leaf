# Leaf

**Private cross-tool activity layer for AI dev teams.**

Open-source memory layer that captures what your dev team actually does — git, Linear, Slack, file activity — and makes it queryable by Cursor, Claude Code, and your team's AI tools. End-to-end encrypted. macOS-native.

[![License: TBD](https://img.shields.io/badge/license-TBD-lightgrey)](#license) [![Platform](https://img.shields.io/badge/platform-macOS-blue)](#) [![Status](https://img.shields.io/badge/status-alpha-orange)](#)

**Quick links:** [Documentation](https://leaf-docs.gundem.tech) · [Privacy](docs/POSITIONING.md) · [Roadmap](docs/ROADMAP.md) · [Pricing](docs/PRICING.md)

---

## Why Leaf

AI tools forget context between sessions, don't know what other teammates are doing, and existing memory products require trust in a third-party cloud. Three concrete problems:

1. **AI forgets context between sessions.** GitHub issue [#14227](https://github.com/anthropics/claude-code/issues/14227) — users call Claude Code "goldfish".
2. **AI doesn't know what others on the team are doing.** GitHub issue [#38536](https://github.com/anthropics/claude-code/issues/38536) — public feature request for shared team memory.
3. **Existing solutions require cloud trust.** Deal-breaker for fintech / healthtech / defense / any regulated team.

Leaf solves all three: capture is on-device and macOS-native; team sharing is end-to-end encrypted with no trusted server; the core is open-source so claims can be verified.

## Quickstart

Three steps to be productive:

```bash
# 1. Install the Mac app (alpha — until public launch)
#    https://leaf-docs.gundem.tech/getting-started/

# 2. Register the MCP server with your AI client
claude mcp add --transport stdio --scope user leaf -- \
  /Applications/Leaf.app/Contents/MacOS/LeafMCP

# 3. (Optional) Connect GitHub / Linear / Slack via Settings → Connections
```

Verify:

```bash
claude mcp list   # leaf: ... ✓ Connected
```

In a new Claude Code session ask natural-language questions — *"что я делал сегодня?"* / *"what did Anton ship this week?"* — and Claude calls Leaf's MCP tools under the hood. The MCP server reads the same local SQLCipher database as the menu-bar app; raw metadata never leaves the device.

## Compared to alternatives

| | Leaf | ByteRover | OpenMemory | Anthropic Session Memory |
|---|---|---|---|---|
| Captures cross-tool activity (git / trackers / chat) | ✅ | partial | ❌ | ❌ |
| End-to-end encrypted team sharing | ✅ | ❌ (trusted cloud) | n/a (single-user) | ❌ |
| macOS-native experience | ✅ | ❌ (web) | ❌ | partial |
| Open-source core (verifiable) | ✅ | ✅ | ✅ | ❌ |
| Multi-surface (MCP + native UI + Slack bot + CLI) | ✅ | partial | ❌ | MCP only |

Differentiation is narrow but real: OS-level capture + macOS-native + E2E without a trusted server + open-source core. We're not first to market — see [docs/POSITIONING.md](docs/POSITIONING.md) for an honest competitive read.

## Architecture overview

Five-layer substrate:

- **Capture (Layer A):** background daemon on macOS — `NSWorkspace`, Accessibility API, FSEvents.
- **Connectors (Layer B):** plugin-style architecture; v1 ships GitHub / Linear / Slack. New connectors land in 1–2 days.
- **Storage:** SQLCipher local database; key in Keychain; `0600` file mode.
- **Summarization:** tier-based with BYOK — on-device (Apple Foundation Models / Ollama) by default, BYOK Anthropic / OpenAI opt-in, Leaf Cloud later.
- **Sharing:** end-to-end encrypted (X25519 + AES-GCM-256 today; XChaCha20-Poly1305 on roadmap), Supabase / Cloudflare relay can never decrypt.

Surfaces over the same substrate: Cursor / Claude Code via MCP, native macOS app, Slack bot, VS Code extension, CLI.

Full architecture in [`docs/COMPONENTS.md`](docs/COMPONENTS.md) and [`docs/TECH_STACK.md`](docs/TECH_STACK.md).

## Open source

Trust through transparency. The privacy and capture surface — the part you'd want to audit — is open. The hosted services that power Team-tier are closed.

| Open source (this repo) | Closed (SaaS) |
|---|---|
| Capture daemon | Slack-bot service |
| Local storage engine | Hosted relay (Supabase / Cloudflare) |
| MCP server | Billing |
| Crypto layer | Premium connectors |

License: **TBD** (Elastic License 2.0 vs. AGPL — see [`docs/OSS_STRATEGY.md`](docs/OSS_STRATEGY.md)).

## Build (developers)

```bash
xcodebuild -project Leaf.xcodeproj -scheme Leaf -destination 'platform=macOS' build
```

## Repository structure

```
Leaf/               # main app target (MenuBarExtra + Settings + Sparkle owner)
LeafAgent/          # launch agent CLI — event collector + SQLCipher writer
LeafMCP/            # stdio MCP server — exposes insights to AI clients
Packages/LeafCore/  # shared SPM library (public API, domain types)
docs/               # strategy & architecture docs (this update)
docs/adr/           # architecture decision records
```

## Roadmap

Public launch in 4–6 weeks across four sprints — solo wedge → team E2E → multi-surface → launch prep. See [`docs/ROADMAP.md`](docs/ROADMAP.md).

## License

TBD — see [`docs/OSS_STRATEGY.md`](docs/OSS_STRATEGY.md).
