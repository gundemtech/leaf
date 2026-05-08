# ADR-015 — Multi-surface strategy

**Status:** Accepted (2026-05, with v4 strategy refresh)

## Context

A single-surface product (e.g., MCP-only inside Cursor) limits reach. Different roles and different workflows prefer different interfaces — a developer in flow wants Cursor-native context; a PM or a teammate in a different IDE wants a Slack bot; a CLI user wants a CLI.

Building all of that as separate products is wasteful; building it on one substrate is leverage.

## Decision

**Multiple surfaces over the same substrate.** All surfaces read the same local data layer (or, for shared events, the same E2E-decrypted view of the team's data).

Surfaces in scope:

- Cursor / Claude Code via MCP (primary AI-tool surface).
- Native macOS app (search, settings, Share Controls, onboarding).
- Slack bot (`/leaf <query>` for the whole team, including non-macOS members).
- VS Code extension (P2).
- CLI (P3).

## Consequences

- Broader reach: a team with mixed tooling all gets value.
- More UI surfaces to maintain — we accept this cost because the substrate is shared.
- Roadmap explicitly stages surfaces (Sprint 1 — MCP / CLI; Sprint 3 — native UI / Slack bot).
