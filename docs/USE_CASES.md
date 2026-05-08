# Use Cases

> **Source of truth:** `leaf-strategic-update-2026-05-v4.md` (section 3). Seven illustrative scenarios — keep in sync on substantive changes.

Seven scenarios that describe the kind of value Leaf delivers, told as the AI tool's (or Slack bot's) reply to a real human question.

---

### Use case 1 — "AI remembers yesterday's work"

In Cursor: "what did I work on Friday on auth?"

> Friday: 3 commits in `src/auth/` against LEAF-127. Last one at 13:08 — "wip: refresh rotation logic", tests were failing. In #leaf-architecture at 11:45 you were writing about the dilemma — rotate refresh on every use, or only on access expiry. Decision not recorded.

### Use case 2 — Asynchronous handoff between team members

Dima: "what was Anton doing today?"

> Anton today — OAuth migration (LEAF-127), 3 commits in `src/auth/refresh.ts`. Stopped halfway through rotation logic. Open question in #leaf-architecture about token rotation policy.

### Use case 3 — Production bug at night

Maya: "what changed in /payments over the last 2 weeks?"

> On 28 April Anton migrated to Stripe API v2024-09 (LEAF-203). He noted "webhook signatures use a new format — needs to be tested". No commits to the webhook handler since then. Worth checking there.

### Use case 4 — Decision archaeology three weeks later

"Why did we move OAuth refresh to the server?"

> Decision on 22 April. In LEAF-127's description Anton wrote: 'client-side refresh = refresh token in localStorage, security concern'. In #leaf-architecture this was discussed with Dima → server-side via httponly cookie.

### Use case 5 — Preparing for code review

Dima: "what should I know before reviewing PR #142?"

> PR #142 — persistent memory for MCP queries (LEAF-198). Anton worked on it for 3 days, 7 commits. **Important:** on Tuesday in #leaf-architecture he wrote that he'd chosen LRU eviction at 1000 entries — but this wasn't discussed or agreed with you.

### Use case 6 — Slack bot for the whole team

A new team member: `/leaf what did we decide about backups and why?`

> Decision on 3 March, initiator — Anton. S3 backups (incremental hourly + full daily) instead of managed RDS — cost savings + portability. Implementation by Dima, 4–5 March in `infra/backup/`.

### Use case 7 — Personal Friday recap

In the Leaf app: "what did I get done this week that mattered?"

> Shipped: OAuth refresh token rotation (LEAF-127), payments hotfix.
> In progress: middleware refactor (~70%, PR #143 draft).
> Decisions: token rotation policy server-side.
