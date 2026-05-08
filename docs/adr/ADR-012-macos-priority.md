# ADR-012 — macOS priority, extensible platform strategy

**Status:** Accepted (2026-05, with v4 strategy refresh)

## Context

Cross-platform development would cost a 2-person team an estimated 6–12 months. Heavy AI dev users are disproportionately on macOS — that's where adoption of Cursor / Claude Code / Claude Desktop is highest. Going cross-platform up front would dilute focus and slow PMF on the segment we can actually win first.

## Decision

**macOS-only for capture in v1.** Cross-platform team members are still served by web / Slack read-surfaces (they receive shared memory, but their machine isn't a capture source). Windows / Linux capture lands on the roadmap, gated by demand signals after PMF.

## Consequences

- Native macOS depth (NSWorkspace, Accessibility API, FSEvents, CryptoKit, Keychain) without compromise.
- Narrow platform reach in v1: a Windows-only team is not yet our segment.
- Team-tier setups where _some_ developers are on Linux/Windows still work — they read shared memory through Slack-bot / future web view, just don't contribute capture.
- Adding Windows/Linux capture later is a known cost, not a surprise.
