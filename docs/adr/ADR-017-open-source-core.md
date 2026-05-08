# ADR-017 — Open-source core

**Status:** Accepted, with the specific license still open (2026-05, with v4 strategy refresh)

## Context

ByteRover's open-source approach drives adoption — the GitHub repo is itself a marketing channel. More importantly, our privacy claims need to be _verifiable_ for the compliance teams we want as customers; "trust us, the daemon is well-behaved" is not a credible answer to a security review.

At the same time, we need to protect the parts of the product that generate revenue.

## Decision

**Open-source core.**

- **OSS:** capture daemon, local storage engine, MCP server, crypto layer.
- **Closed (SaaS):** Slack-bot service, billing, hosted relay, premium connectors.

License selection is **deferred** — Elastic License 2.0 vs. AGPL is still under discussion. See section 11 of the v4 strategy document.

## Consequences

- **Trust through transparency** — privacy claims can be audited in code by anyone.
- **Compliance teams** can satisfy themselves on the local agent without an NDA-bound source review.
- **Revenue is preserved** — the parts that drive payment (hosted relay, Slack bot, billing) remain closed.
- **License choice is a known open question** — it must be resolved before public launch (see Sprint 4 in `docs/ROADMAP.md`).
- **Community contribution path** for connectors becomes possible (cf. ADR-016) once the license is settled.
