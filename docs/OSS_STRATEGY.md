# Open-Source Strategy

> **Source of truth:** `leaf-strategic-update-2026-05-v4.md` (section 5).

**Decision:** open-source the core of the product.

**What is OSS:** capture daemon, local storage engine, MCP server, crypto layer.

**What is closed (SaaS):** Slack-bot service, billing, hosted Supabase relay, premium connectors.

## Why an OSS core

1. **Trust through transparency** — privacy claims are verifiable.
2. **Adoption through community** — lower-friction install, organic word of mouth.
3. **Compliance teams require auditability** — the part they want to read is open.
4. **We don't lose revenue** — the money is in the team feature, not in the capture daemon.

## License

**TBD:** Elastic License 2.0 or AGPL — final choice still under discussion. See ADR-017.
