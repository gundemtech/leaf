# ADR-013 — Tier-based summarization with BYOK

**Status:** Accepted (2026-05, with v4 strategy refresh)

## Context

A pure cloud-LLM summarization layer breaks the privacy positioning that makes Leaf credible to regulated teams. A pure on-device layer (Apple Foundation Models) may have insufficient quality for some queries, and quality cannot be tested honestly until we ship and see real usage.

Forcing one trade-off for everyone is wrong.

## Decision

Three-tier summarization architecture; the user chooses which tier their data passes through.

1. **On-device (default)** — Apple Foundation Models on macOS Tahoe+, Ollama as fallback. Privacy-maximum.
2. **BYOK (opt-in)** — the user supplies their own Anthropic / OpenAI API key. Highest quality. Their data goes to the LLM provider through their own account; Leaf never sees it.
3. **Leaf Cloud (later, opt-in)** — our API key, explicit consent. Not in v1.

Both tier-1 and tier-2 ship in v1. Tier-3 is deferred.

## Consequences

- Architectural flexibility: a single Summarization Pipeline abstraction with pluggable backends.
- More implementation work for v1 — two backends instead of one.
- Honest privacy story: we don't promise on-device-only when we can't yet verify on-device quality is sufficient for all queries; we let the user decide.
- On-device quality becomes a measurable thing post-launch, not a guess.
