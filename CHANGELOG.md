# Changelog

All notable changes to the Leaf macOS app, newest first. These are
**per-release app notes** — what shipped in each build. They are distinct from
the product changelog at <https://leaf-docs.gundem.tech/reference/changelog/>,
which records product and strategy decisions.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project aims to follow [Semantic Versioning](https://semver.org/).

Backfilled entries (alpha.6 through alpha.29) are reconstructed best-effort from
the release history and summarised at a feature level.

## [Unreleased]

## [1.0.0-alpha.36] — 2026-06-12

### Added

- Local commit capture. Leaf now reads your own commit messages straight from
  the repositories inside your watched folders — authorship is verified, so
  teammates' commits are never captured — with a one-time history backfill.
  Commit messages are the densest record of decisions; search and decision
  recall finally have a real corpus to work with.
- Handoff context card. Handing work to a teammate now attaches a structured
  card — last commit, open review, ticket status, last thread — rendered on
  top of the message for the recipient. You preview exactly what's shared
  before sending (references and titles only, never message bodies), and the
  card is attached only with your consent. Teammates on older builds simply
  see the text.
- Team brief. The "what shipped" counters now include teammates' shared PR
  merges and completed tickets alongside your own (no double counting), a
  contributor count, a "resolved by Tuesday"-style line from real resolution
  dates, and a "read full brief" view listing everything behind the numbers.
- Search result cards. Results render as cards with a MATCH badge on the top
  hit, a result counter, and labeled rows (author / channel / commit / ticket
  / PR) built from the cross-source link graph. When a search finds nothing
  because coverage is thin, the empty state says so and names the fix.
- Nudges in the menu bar. A compact "you · last 24h" panel in the menu-bar
  popover, plus a global ⌥⌘L shortcut that brings Leaf forward.
- New `leaf_search` AI tool — one call returning the same ranked results the
  Search tab shows; `leaf_get_decision` can now return the top N decisions
  with channel / commit context for broad onboarding questions.

### Fixed

- The memory layer actually fills. Cross-source link derivation was inert in
  production builds, the full-text index never covered events captured before
  it existed, and detectors never revisited history — all three repaired with
  a one-time background sweep. Searching months of work now returns real
  results instead of a single match.
- "Current work" no longer names a messenger or music app as the thing you
  are working on — it looks for your last development app and honestly shows
  nothing if there wasn't one. The current branch and last commit now always
  describe the same repository.
- Search queries containing hyphens or quotes no longer fail (both in-app
  and through the AI tools).
- The background agent could crash-loop on launch after the account-login
  update (its own metadata was missing the service configuration). Caught
  and fixed before it ever reached a release.
- Activity and search are no longer drowned by internal telemetry pulses —
  feeds show work output, not bookkeeping.

## [1.0.0-alpha.35] — 2026-06-11

### Added

- Account login. The app now signs in with your Leaf account — email and
  password or Google / GitHub — and everything (the app and background
  collection) runs under your session. Anonymous mode is gone; signing out
  stops collection until you sign back in.
- Search tab. Full-text search over everything Leaf remembers on this Mac:
  decisions surface first (with linked PR / issue references), then open
  questions, blockers and matching commit / comment / thread text. Same
  engine the AI tools use, now without an AI client.
- Nudges card on Home — "am I quietly stuck?": stalled PRs with no movement
  for days, tickets sitting in the same status, unresolved blockers, and
  fragmented-attention days with the total switch count and your top
  app-switching pairs. Visible only to you — there is no manager dashboard.
- Brief on Home — "what shipped in the last 5 days": PRs merged across
  repos, tickets done, decisions surfaced, blockers resolved. The PR and
  ticket counters expand into the actual list, each row opening its source.
- Collection-paused banner. If the background agent stops running, Home says
  so in red with a Repair button — instead of silently showing stale data
  and counting the outage as your "idle" time.

### Changed

- Home was redesigned around four questions: what am I on (NOW — branch,
  repo, session, last commit, uncommitted work), how is the day going
  (TODAY), what needs me (NEEDS YOU — filters now actually filter, items
  carry real issue titles and timestamps), and what happened without me
  (WHILE YOU WERE AWAY).
- The activity feed grew from 9 to 21 event types: issues opened / closed,
  releases, branches and tags, review and issue comments, discussions,
  Linear priority moves ("raised priority of …"), assignment pickups and
  handoffs, and project updates.
- PRs and issues are now referred to by their titles everywhere (feed,
  inbox, brief) instead of bare "PR#64" handles — including PRs that were
  already merged.
- The "needs you" CI alert now reflects the latest pipeline state per
  repository and links to the commit — a green re-run quietly retires a
  stale failure instead of pinning it for a day.

### Fixed

- A Linear polling edge case re-captured the same issue every 5 minutes
  (dozens of identical copies polluting search and counters). New
  duplicates are no longer written and existing ones are collapsed
  everywhere they could show.

## [1.0.0-alpha.34] — 2026-06-10

### Added

- Team page is now a workspace hub with three tabs. Chats: a two-pane
  messenger for real 1:1 conversations — live composer, reply quotes (click a
  quote to jump to the original), read receipts, task bubbles with Open /
  Mark Done, unread badges and search. Members: the full roster with roles,
  pending join requests and active invite tokens in one place. Settings:
  workspace rename, per-workspace share rules and the danger zone
  (Leave / Delete / Wipe).

### Changed

- App Settings now covers device-level categories only (Sharing /
  Notifications / Data / General) — workspace management lives on the Team
  page. A join-request notification now deep-links straight to Team → Members.

### Added

- Analyze with AI: ask the model to break down specific events in detail —
  select events in the Activity feed ("Analyze with AI") or press "Dig deeper"
  on an Ask Leaf answer. A consent dialog shows the exact text that will be
  sent before anything leaves your Mac; events from personal apps and DMs are
  marked "never sent" and are excluded even if selected.
- AI privacy log (Settings → Sharing): two append-only feeds — "AI received"
  (every text escalation you confirmed) and "AI handoffs" (AI-drafted messages
  sent to teammates).
- Workspace picker in the sidebar: compact trigger with a custom dropdown and
  profile row for switching between workspaces.

### Fixed

- Activity → Raw events shows captured events again (the feed had been left
  permanently empty by an earlier cleanup).

### Changed

- Home, Team, Activity and Analytics now refresh in real time while open —
  new data appears without switching tabs or reopening the window.

### Added

- "Ask Leaf" tab: ask questions about your work in plain language and get
  answers built from your own structured activity data. Uses your own
  Anthropic API key (managed in Settings → Data → AI Answers, shared with the
  MCP server), with period and model pickers.
- Diagnostics now shows the background agent's launchd state and a Repair
  button that restores collection in one click.

### Fixed

- Background collection now heals itself: the app monitors the agent's
  heartbeat and automatically restarts or re-registers it if capture silently
  stops — previously this required manually re-toggling settings. If automatic
  recovery fails, Leaf notifies you with a pointer to the fix. Collection you
  turned off yourself is never re-enabled automatically.
- Launching Leaf from a non-installed location (a DMG, Downloads, a temporary
  copy) can no longer break background collection for the installed app —
  agent registration is now guarded to the canonical install location.

### Changed

- Team page redesigned as a chat-style feed: message bubbles grouped into
  conversation runs with explicit recipients, Today/Yesterday day separators,
  quieter activity rows, and member names resolved everywhere instead of raw
  key fingerprints.

## [1.0.0-alpha.31] — 2026-06-10

### Added

- In-app "What's New" screen: after an update, Leaf shows what changed in the
  installed version (also available any time from Settings). Sparkle's update
  dialog now carries the same release notes instead of an empty pane.

### Fixed

- Incoming team messages could silently stop arriving in newly created teams:
  one message with cross-post metadata aborted the whole inbound sync batch, so
  newer pings, tasks and handoffs never appeared. Sync now tolerates all
  metadata shapes, and a single message can no longer block the batch.

## [1.0.0-alpha.30] — 2026-06-09

### Fixed
- Approving a request to join a workspace now works reliably — the admin queue
  no longer shows a spurious "bad request" error on approval.
- Team members now see the full roster: invitees see each other, not just the
  admin and themselves (previously the roster did not sync between members).

## [1.0.0-alpha.29] — 2026-06-09

### Added
- Local system banners for incoming team messages (handoff, task, ping) — you
  no longer have to open the app to learn a message arrived.
- A master notifications toggle plus per-type settings in Settings (handoff
  notifications are always on); a text preview is shown by default.

## [1.0.0-alpha.28] — 2026-06-07

### Fixed
- Team direct messages and handoffs now deliver symmetrically in both
  directions — a just-joined member's messages reach their counterpart, and the
  new member can send the first message. Verified live on two Macs.
- The workspace creator now appears in the member list by personal name rather
  than by the workspace name.
- Stranded invite approvals now resume, and the sidebar refreshes when a
  workspace join completes.

### Changed
- The release flow gained an automatic website-deploy step and publishes a
  download checksum alongside each build.

## [1.0.0-alpha.27] — 2026-06-06

### Added
- AI Coworker — an optional AI layer over your own work data, with a
  fail-closed boundary on what may ever leave the device and bring-your-own-key
  support (Anthropic). First capabilities: ask questions about your own work
  through the MCP tool, cross-provider synthesis and trends, on-demand
  escalation backed by an append-only audit log, and AI-drafted team handoffs
  sent over the existing end-to-end-encrypted transport. A client-side
  attestation seam (proof-of-concept) lays groundwork for a future verifiable
  open-weight path.

## [1.0.0-alpha.26] — 2026-06-04

### Fixed
- Joining a workspace now reliably materialises the full member roster.
- Settings toggles for IDE watchers, notification behaviour, and
  script-dependent features now take effect (previously some had no effect);
  script-dependent features gained an availability precheck.

### Changed
- Debug and release builds now use separate bundle identifiers, fixing
  app-launch breakage that could follow an update.

## [1.0.0-alpha.25] — 2026-06-03

### Added
- A recovery screen for when the on-disk database is newer than the installed
  app (for example after a downgrade): Backup & Reset / Reveal / Quit, instead
  of a failed load. The background agent now exits cleanly without a crash-loop.

### Fixed
- The pending-invites list now refreshes within bounded limits.
- Resolved a data race in notification settings.

### Changed
- Hardened internal release and hygiene tooling (migration-linearity and
  secret-scan guards, build and test gates).

## [1.0.0-alpha.24] — 2026-06-01

### Fixed
- The Diagnostics section in Settings is now always visible.
- Release upload reliability fixes.

## [1.0.0-alpha.23] — 2026-06-01

This release folds in a large body of work shipped as untagged builds
(alpha.17–22): the first team-collaboration suite, a redesigned Home, and
deeper activity capture.

### Added
- Team collaboration: send direct messages (handoff, task, ping) to teammates
  over end-to-end encryption, across multiple workspaces with an
  invite-and-approve join flow. A team feed shows what teammates are working on,
  and messages can optionally be mirrored to Slack or Linear.
- Share Controls: choose per source exactly what is shared with your team —
  nothing is shared by default.
- Redesigned Home centred on what you're doing now — where you left off, who's
  around, and what needs your attention — with Analytics moved behind a Settings
  toggle.
- Google Calendar connection — calendar data feeds the activity surface.
- Deeper activity capture for coding tools, browsers, and meetings.
- Settings reorganised into five category tabs, with a new Diagnostics panel for
  troubleshooting background capture.

### Fixed
- Security and privacy hardening across team encryption, sign-in, and network
  paths.

## [1.0.0-alpha.16] — 2026-05-16

### Added
- IDE awareness: detection for the VS Code family (VS Code, Cursor, Insiders,
  VSCodium) and JetBrains projects, behind a settings gate.
- Deeper capture for Xcode and Zoom activity.

## [1.0.0-alpha.6] — 2026-04-29

### Added
- Earliest recorded alpha build: background work capture, the native menu-bar
  app, and the MCP server foundations.

[Unreleased]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.35...HEAD
[1.0.0-alpha.35]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.34...v1.0.0-alpha.35
[1.0.0-alpha.34]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.33...v1.0.0-alpha.34
[1.0.0-alpha.33]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.32...v1.0.0-alpha.33
[1.0.0-alpha.32]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.31...v1.0.0-alpha.32
[1.0.0-alpha.31]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.30...v1.0.0-alpha.31
[1.0.0-alpha.30]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.29...v1.0.0-alpha.30
[1.0.0-alpha.29]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.28...v1.0.0-alpha.29
[1.0.0-alpha.36]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.35...v1.0.0-alpha.36
[1.0.0-alpha.28]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.27...v1.0.0-alpha.28
[1.0.0-alpha.27]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.26...v1.0.0-alpha.27
[1.0.0-alpha.26]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.25...v1.0.0-alpha.26
[1.0.0-alpha.25]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.24...v1.0.0-alpha.25
[1.0.0-alpha.24]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.23...v1.0.0-alpha.24
[1.0.0-alpha.23]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.16...v1.0.0-alpha.23
[1.0.0-alpha.16]: https://github.com/gundemtech/leaf/compare/1.0.0-alpha.6...v1.0.0-alpha.16
[1.0.0-alpha.6]: https://github.com/gundemtech/leaf/releases/tag/1.0.0-alpha.6
