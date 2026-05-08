# System Components

> **Source of truth:** `leaf-strategic-update-2026-05-v4.md` (section 6).

Eleven components, each with its own responsibility. Status and estimates reflect the v4 strategy snapshot.

Status legend: ✅ implemented · 🟡 partial · ❌ not started · 🔴 blocker for launch.

---

### 6.1 Capture Daemon

**What:** background LaunchAgent that listens to macOS events and writes normalised events into SQLCipher.

**Status:** ✅ implemented in core.

**Remaining work:** 1–2 days of polish.

### 6.2 Local Storage Engine

**What:** SQLCipher database with a normalised event schema.

**Status:** ✅ base implementation.

**Estimate:** 1 day to finalise the schema.

### 6.3 Summarization Engine — 🔴 launch blocker

**What:** pipeline with tier-based backends.

**Status:** ❌ not started.

**Estimate:** 4–5 days (with two backends — on-device and BYOK).

### 6.4 MCP Server

**What:** implements the MCP protocol; exposes tools (`leaf_query_activity`, `leaf_query_team`, `leaf_get_decision`, `leaf_current_work`).

**Status:** 🟡 partially implemented.

**Estimate:** 2–3 days after the Summarization Engine.

### 6.5 Sync Relay Client (E2E) — Phase 5

**What:** encrypts shared events, routes them through the Supabase relay, decrypts locally.

**Status:** 🟡 60–70% done.

**Estimate:** 4–5 days to production.

### 6.6 Native Mac App (UI)

**What:** menu bar, search bar, settings, Share Controls, onboarding.

**Status:** ❌ minimal.

**Estimate:** 4–5 days for an MVP.

### 6.7 Slack Bot

**What:** Slack App with the slash command `/leaf <query>`.

**Status:** ❌ not started.

**Estimate:** 3–5 days.

### 6.8 VS Code Extension (P2)

**What:** sidebar with file context.

**Status:** ❌ not started.

**Estimate:** 3–4 days.

### 6.9 CLI Tool (P3)

**What:** `leaf today`, `leaf "auth refactor"`, `leaf install --cursor`.

**Status:** ❌ not started.

**Estimate:** 2–3 days.

### 6.10 Auth & Onboarding

**What:** lazy permissions, MCP auto-install, key generation, OAuth setup, summarization-tier choice.

**Status:** 🟡 base in place, needs rework.

**Estimate:** 3–4 days.

### 6.11 Billing & Licensing

**What:** Stripe integration, free trial, team-seat management.

**Status:** ❌ not started.

**Estimate:** 2–3 days.
