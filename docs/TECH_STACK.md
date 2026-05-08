# Technology Stack

> **Source of truth:** `leaf-strategic-update-2026-05-v4.md` (section 4, sub-sections 4.1–4.11). This file mirrors that section. Implementation details (exact thresholds, byte layouts, KDF info strings, etc.) live in private modules per the project's pre-push moat checklist and are not documented here.

---

## 4.1 Platform and language

| Technology | What for | Why this one |
|------------|----------|--------------|
| **Swift / SwiftUI** | Native macOS app + capture daemon + MCP server + CLI | Apple-native, single language for everything that runs on the Mac |
| **TypeScript / Node.js** | Slack bot + VS Code extension | Standard for serverless edge functions and VS Code extensions |

## 4.2 macOS capture (Layer A)

| Technology | What for | Why this one |
|------------|----------|--------------|
| **NSWorkspace** | Tracking the active application | Standard macOS API |
| **Accessibility API** | Window titles | The only way to get window titles |
| **FSEvents** | File-system events | Native macOS file watcher |
| **LaunchAgent** | Background daemon | Standard way to run a background process |

## 4.3 Connectors layer (Layer B) — extensible architecture

**Principle:** plugin-like architecture in which new connectors are added without rewriting the core.

**v1 ships with:**

| Connector | What it captures |
|-----------|------------------|
| GitHub | PRs, issues, commit metadata |
| Linear | Tasks, project metadata, discussions |
| Slack | Messages in team channels |

**Roadmap (driven by user requests):** GitLab, Bitbucket, Jira, Notion, Asana, Trello, Discord, Microsoft Teams, Figma, Sentry, DataDog, PagerDuty.

**Architectural requirement:** adding a new connector ≈ 1–2 days.

## 4.4 Storage

| Technology | What for | Why this one |
|------------|----------|--------------|
| **SQLite + SQLCipher** | Local encrypted database | Already in use. Embedded, free, battle-tested |

## 4.5 Cryptography

| Technology | What for | Why this one |
|------------|----------|--------------|
| **Apple CryptoKit** | X25519 + XChaCha20-Poly1305 on macOS | Apple-native, hardware-accelerated, audited |
| **libsodium** | Same crypto in server-side components | Industry-standard, cross-platform |
| **iCloud Keychain** | Backup of private keys | Apple-native secure storage |

## 4.6 Summarization layer — tier-based with BYOK

```
                    ┌─────────────────────────┐
                    │  Summarization Pipeline │
                    │     (one abstraction)   │
                    └────────────┬────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
     ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
     │   ON-DEVICE     │ │      BYOK       │ │   LEAF CLOUD    │
     │   (default)     │ │   (opt-in)      │ │  (later opt-in) │
     │                 │ │                 │ │                 │
     │ Apple FM /      │ │ User's API key  │ │ Our API key     │
     │ Ollama fallback │ │ Anthropic/OpenAI│ │ explicit consent│
     └─────────────────┘ └─────────────────┘ └─────────────────┘
```

**What the user sees in Settings:**

```
How should Leaf summarize your activity?

◉ On-device (default)
  Apple Foundation Models / Ollama. Privacy-maximum.

○ Cloud via my API key (BYOK)
  Highest quality. Your data goes to Anthropic/OpenAI
  via your own account. Leaf never sees it.

○ Cloud via Leaf (coming later)
```

**What ships in v1:**

1. Default: Apple FM on macOS Tahoe+ / Ollama fallback.
2. Day-1 option: BYOK Anthropic API key.
3. Deferred: Leaf cloud-tier.

**On-device quality is tested after we ship** — decision driven by facts, not guesses.

## 4.7 Sync / Relay backend

| Technology | What for | Why this one |
|------------|----------|--------------|
| **Supabase** | Untrusted relay for encrypted blobs + auth + Edge Functions for the Slack bot | Postgres + Auth + Realtime + Edge Functions out of the box |

## 4.8 MCP server

| Technology | What for | Why this one |
|------------|----------|--------------|
| **MCP SDK in Swift** | Server for AI tools | Swift native = single language with the Mac app |

## 4.9 Distribution / Build

| Technology | What for | Why this one |
|------------|----------|--------------|
| **Apple Developer Program** | Notarization | $99/year; without it Gatekeeper complains |
| **Sparkle** | Auto-update | Standard for macOS |
| **GitHub Actions** | CI/CD | Already in use |

## 4.10 Billing

| Technology | What for | Why this one |
|------------|----------|--------------|
| **Stripe** | Subscriptions, free trial, team-seat billing | Industry standard |

## 4.11 What we are **not** using

- ~~Electron / React for the Mac app~~ — native (SwiftUI).
- ~~Cloud LLM as a trust point~~ — only BYOK or on-device.
- ~~Vector DB~~ — overkill, revisit later.
- ~~Kubernetes / own infra~~ — Supabase covers it.
- ~~Analytics SDK (Mixpanel / Amplitude)~~ — contradicts the privacy posture.
