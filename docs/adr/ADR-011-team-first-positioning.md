# ADR-011 — Team-first positioning

**Status:** Accepted (2026-05, with v4 strategy refresh)

## Context

Anthropic Session Memory shipped in Claude Code, and individual-memory products are commodifying quickly. Multiple competitors operate on the individual layer (ByteRover, OpenMemory, Anthropic itself). Holding individual memory as the headline product cedes the differentiated ground to the AI-tool vendors.

Team memory, by contrast, remains under-served — and the "E2E across teammates without a trusted server" angle is something neither Anthropic nor existing memory startups offer.

## Decision

**Team E2E memory becomes the main product.** Individual memory becomes a free freemium hook for Team adoption.

## Consequences

- Marketing repositioning from "personal AI memory" to "memory layer for AI dev teams."
- Personal Pro tier removed from pricing — there is no individual paid tier; paid plans start at Team.
- Slack bot, Share Controls, and team-aware MCP queries become first-class roadmap items rather than nice-to-haves.
- We accept being second/third to market on the individual layer; differentiation is now narrow but sharper (cf. ADR-017).
