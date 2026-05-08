# ADR-016 — Extensible connector architecture

**Status:** Accepted (2026-05, with v4 strategy refresh)

## Context

Hard-coding a fixed set of integrations (only GitHub / Linear / Slack) limits growth. Users will request other tools — GitLab, Bitbucket, Jira, Notion, Asana, Trello, Discord, Microsoft Teams, Figma, Sentry, DataDog, PagerDuty — and we need to be able to ship them quickly without rewriting the core.

## Decision

**Plugin-like connector architecture.** v1 ships with GitHub / Linear / Slack as first-party connectors. New connectors are added through a uniform interface so a single connector lands in 1–2 days of work, not a week.

## Consequences

- Architectural flexibility: each connector is a small, isolated module.
- Longer initial design phase — the abstraction has to be right before the third connector lands.
- Roadmap can stay honest: "GitLab? GitLab is a 1–2 day add when there's a paying team that needs it." The path from user request to ship is short.
- Future option: open the connector interface to community contributions once the core is OSS (cf. ADR-017).
