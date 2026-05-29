# OSS Promotion Decisions — 2026-05-25

Decisions taken during the Phase 1 OSS-readiness sweep (security-hardening
master spec §6). This document is intentionally PII-free.

## D1 — Git history author/email rewrite: **GO, deferred**

The public repo's commit history carries co-author identities (display names +
personal emails). For open-source promotion these are collapsed into a single
neutral identity and personal emails are stripped.

- **Decision:** rewrite. Map every historic author/committer identity → one
  neutral identity (e.g. `Leaf Team <dev@gundem.tech>` — final value chosen at
  run time).
- **Execution:** **not** performed on this branch. A one-shot script
  (`scripts/oss/rewrite-authors.sh`) runs against a **fresh mirror clone** so
  the result is reviewable before any force-push. The maintainer runs it
  immediately before the first public push and force-pushes the mirror.
- **Why deferred / mirror-only:** rewriting history on the live repo would
  break every existing clone and the in-flight feature branches; doing it on a
  throwaway mirror at promotion time avoids disrupting ongoing work.
- **Why the script is PII-free:** it derives the existing identities
  dynamically from `git log` at run time and maps them to the neutral identity
  via a generated (temporary) mailmap. No names or emails are committed.

## D2 — Source/doc name scrub: neutral placeholders

Real team-member names that had leaked into preview/test fixtures and docs are
replaced with neutral placeholders, consistent with the prior precedent
(commit `122e5f3a`). The concrete real→placeholder mapping is kept out of the
public repo (in the gitignored phase plan) to avoid re-stating the real names.
Functional identifiers that merely *look* like names — e.g. the lowercase MCP
routing handles in `leaf_ask_question(to=…)` — are **not** renamed; they are
system identifiers, not display PII.

## D3 — Apple identifiers

- **Code-signing identity** (`scripts/release.sh`): the hardcoded
  `Developer ID Application: <name> (<team-id>)` string is replaced by a
  `$LEAF_SIGN_ID` environment override with a placeholder default. The real
  value lives in the maintainer's environment / gitignored local config.
- **Xcode `DEVELOPMENT_TEAM`** (`Leaf.xcodeproj`): **retained.** An Apple Team
  ID is not a secret — it is present in the code signature of every shipped
  app and grants no access. It is a functional build setting; emptying it would
  break local signing for no confidentiality gain. Contributors override it via
  the existing gitignored `Config/Local.xcconfig`.

## D4 — Automated leak guard is the canonical enforcement

`scripts/leak-guard.sh` is the single source of truth for the forbidden-pattern
set, replacing the purely-manual `/pre-push-leaf` checklist for the mechanical
checks. It runs in CI (`.github/workflows/leak-guard.yml`) on PRs + pushes to
`main`, and as a local `pre-push` hook (`just install-hooks`).

- Names are stored base64 (not secret, but kept out of source verbatim and
  prevented from self-matching).
- Tuned moat numerics are matched **structurally** (pragma key `= <digit>`), so
  the concrete value never appears in the public guard.
- The guard scans tracked **tree content only**; historic commit metadata is
  handled by D1's deferred rewrite, not by the guard (which would otherwise be
  permanently red until the rewrite runs).
