# Positioning

> **Source of truth:** `leaf-strategic-update-2026-05-v4.md` (sections 1–2). This file is a project-local reflection of those sections — keep in sync with the v4 strategy document on substantive changes.

What Leaf is, who it's for, what problem it solves, and what it explicitly is not.

---

## 1. What we're doing — in three sentences

**Leaf is a persistent memory layer for developer teams that use AI tools (Cursor, Claude Code, Claude Desktop) every day.** It automatically captures what the team actually does on their machines — git activity, tickets in trackers, discussions in chat, file-system activity — and makes that knowledge available to AI tools through MCP. **The main differentiation from existing solutions (ByteRover, OpenMemory, Anthropic Session Memory)** is end-to-end encryption between team members without a trusted server, plus a macOS-native experience and an open-source core for transparency.

---

## 2. Goal / For whom / What problem it solves

### 2.1 Product goal

Make sure AI tools in a developer team **never lose context** — neither between sessions of one person, nor between team members. Context is grounded not in conversations with AI but in **ground-truth activity** (git, trackers, chats, files).

### 2.2 For whom — priorities by phase, not "forbidden forever"

**Priority for v1 (where PMF lands fastest):**

Dev teams of 2–10 people in which:

- Everyone uses macOS as their primary work machine.
- Everyone, or most of the team, uses Cursor / Claude Code / Claude Desktop daily.
- The team works with sensitive code (fintech, healthtech, security, defense, any regulated industry) **or** has strict privacy requirements.
- They are willing to pay for tools that save time.

**Secondary segment for v1 (freemium users):**

Solo developers on macOS with heavy AI-tool usage. Acquisition channel — future team accounts come from here.

**Addressed as we grow:**

- **Windows / Linux capture** — eventually, after PMF on macOS.
- **Flow for PM / designers / QA** — after the dev segment is stable.
- **Enterprise-tier for 50+ teams** — separate sales motion, supported architecturally from day one.

**Not our segment, even long-term:**

Teams without AI-tool adoption. There is nothing to "augment" — no AI that needs memory.

### 2.3 What concrete problem we solve

**Problem 1 — AI forgets context between sessions.** GitHub issue [#14227](https://github.com/anthropics/claude-code/issues/14227) in the Claude Code repo; users call Claude Code "goldfish".

**Problem 2 — AI doesn't know what others on the team are doing.** GitHub issue [#38536](https://github.com/anthropics/claude-code/issues/38536) "Feature Request: Shared Team Memory" — public request.

**Problem 3 — existing solutions require trust in the cloud.** For regulated teams (fintech, healthtech, defense) this is a deal-breaker — security teams forbid it.

### 2.4 What the product is **not**

**Definitely not:** bossware, a Slack/Linear replacement, a time tracker.

**Open question — after PMF:** personal-productivity self-view (only for the user), AI ROI tracking.

**Categorically not:** "AI Ratio" as a marketing feature, "Sunday Digest" as a "killer feature", aggregated team productivity dashboard (= bossware).
