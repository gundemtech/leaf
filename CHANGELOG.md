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

## [1.0.0-alpha.32] — 2026-06-10

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

[Unreleased]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.32...HEAD
[1.0.0-alpha.32]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.31...v1.0.0-alpha.32
[1.0.0-alpha.31]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.30...v1.0.0-alpha.31
[1.0.0-alpha.30]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.29...v1.0.0-alpha.30
[1.0.0-alpha.29]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.28...v1.0.0-alpha.29
[1.0.0-alpha.28]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.27...v1.0.0-alpha.28
[1.0.0-alpha.27]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.26...v1.0.0-alpha.27
[1.0.0-alpha.26]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.25...v1.0.0-alpha.26
[1.0.0-alpha.25]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.24...v1.0.0-alpha.25
[1.0.0-alpha.24]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.23...v1.0.0-alpha.24
[1.0.0-alpha.23]: https://github.com/gundemtech/leaf/compare/v1.0.0-alpha.16...v1.0.0-alpha.23
[1.0.0-alpha.16]: https://github.com/gundemtech/leaf/compare/1.0.0-alpha.6...v1.0.0-alpha.16
[1.0.0-alpha.6]: https://github.com/gundemtech/leaf/releases/tag/1.0.0-alpha.6
