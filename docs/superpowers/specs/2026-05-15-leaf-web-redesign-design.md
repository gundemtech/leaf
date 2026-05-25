# Leaf Web Redesign — Design Spec

**Date:** 2026-05-15
**Status:** Draft → awaiting user review
**Author:** Alex + Claude (brainstorming session)
**Scope:** Marketing site at `leaf.gundem.tech` (full redesign + new pages). Whitepaper (`leaf-docs.gundem.tech`) and internal dashboard (`leaf-internal.gundem.tech`) are **follow-up scope** — they reuse the tokens defined here but live in separate specs.

---

## 1. Goal

Replace the current single-page marketing site at `leaf.gundem.tech` with a **multi-page, content-rich product site** that:

- Showcases what Leaf does (capture, integrations, surfaces, use cases) at depth a single landing can't carry.
- Communicates the privacy story explicitly — *"your manager can't peek without your permission"* — as a primary differentiator, not a buried footnote.
- Lives in a maintainable build (Astro) so adding pages and updating components doesn't require copy-pasting headers across 7 HTML files.
- Reuses the **existing app design system** (`LeafCore` semantic tokens: SF Pro / green accent / 4pt baseline / hairline borders / 3 elevation tiers / Liquid Glass) ported to web.
- Looks like a modern dev-tool premium product — **Linear's confidence + Stripe's polish + Raycast's native-Mac credibility** — and explicitly avoids generic AI-SaaS aesthetics (aurora gradients, soft-blob illustrations, isometric abstract scenes, emoji-as-decoration, "AI sparkle" badges).

The site must **preserve all existing wiring**: Supabase auth (sign in / sign up / OTP / password reset), Cloudflare Worker waitlist form with Turnstile, OxaPay early-access payment link, RSS feed at `/changelog/feed.xml`, JSON feed at `/changelog/latest.json`, sitemap, clean URLs (no `.html` suffix), session-aware header (Sign in/Dashboard toggle), nginx routes, OG meta + Twitter cards.

## 2. Information architecture (sitemap)

```
PUBLIC ROUTES
├─ /                — Landing: hero + section teasers + waitlist CTA
├─ /product         — Deep feature dive (single long page, sticky sub-nav)
├─ /pricing         — Plan cards + full comparison table + billing FAQ
├─ /privacy         — Privacy deep-dive (captured-vs-not matrix, E2E crypto,
│                     Share Controls, Won't-list, verifiability)
├─ /open-source     — OSS-vs-closed matrix + GitHub link
├─ /changelog       — Lента релизов (RSS-fed, paginated)
├─ /changelog/feed.xml — RSS (preserved, do not change)
└─ /terms           — Terms of service

AUTH ROUTES (functionality preserved exactly; visual restyle only)
├─ /signup          — 5 in-page panels: sign in / create / verify OTP /
│                     forgot password / reset
└─ /dashboard       — Authed account: profile + download .dmg + sign out +
│                     delete account

API (unchanged)
└─ /api/contact     — Cloudflare Worker (Turnstile + Supabase D1 waitlist)
```

**Top navigation (every page):**
`🍃 Leaf · Product · Pricing · Privacy · Open Source · Docs↗  [Sign in]`

`Docs↗` is an external link to `leaf-docs.gundem.tech`. `Sign in` is session-aware — flips to `Dashboard` if Supabase session detected (existing behavior, preserved).

**Footer (every page):**
3-column sitemap (Product / Resources / Company) + brand row with version stamp `v1.0.0-alpha.15`.

## 3. Hero messaging

**Primary headline (H1):**

> **Stop briefing your AI. It can just know.**

**Supporting paragraph:**

> Your team's working memory, captured automatically across your tools. Queryable from Claude Code, Cursor, and Slack. Private by architecture — managers can't peek without your consent.

**Primary CTA:** `[Install for macOS →]`
**Secondary CTA:** `[Read the whitepaper ↗]` (links to `leaf-docs.gundem.tech`)

**Eyebrow mono label:** `v1.0.0-alpha.15 · macOS-native · OSS`

The hero is paired with an **animated live MCP query demo** inside a Liquid Glass card: typed-text input → cascading result rows showing team focus / decisions / encryption indicators. Respects `prefers-reduced-motion`. Tilted 4° on desktop, flat on mobile.

## 4. Design direction

**Vibe one-liner:** *Linear's confidence + Stripe's polish + Raycast's native-Mac credibility — telling the story of memory, not of "AI productivity."*

**Design DNA (4 lines):**
1. Dark-first canvas with light-mode toggle via `prefers-color-scheme` (matches app design system).
2. Single green accent `#22C55E` (light) / `#4ADE80` (dark) — no secondary accents, no rainbow palette.
3. SF Pro Display for headings (semibold, 64–17pt scale), Inter for body (17pt prose), JetBrains Mono for technical content (paths, MCP queries, version stamps). No serif. No custom fonts.
4. Hairline 1px borders + 3 elevation tiers (raised / floating / modal) + Liquid Glass on interactive moments. No gradient backgrounds, no soft-blob illustrations, no generic isometric abstract scenes.

**Motion:** snappy springs `cubic-bezier(.18, .89, .32, 1.28)`, durations 120/200/350/550ms. All animations respect `prefers-reduced-motion: reduce`.

**Liquid Glass:** real `backdrop-filter: blur(24px) saturate(1.4)` on feature cards, hero demo card, and floating elements. Tinted green at 8–12% opacity for accent surfaces. Used sparingly — not decorative wallpaper.

## 5. Tokens

CSS variables loaded into `:root` and overridden in `@media (prefers-color-scheme: dark)`. Values transcribed verbatim from app design system (`Packages/LeafCore/Sources/LeafCore/UI/Tokens/`):

### 5.1 Color

| Role | Light | Dark |
|---|---|---|
| `--surface-canvas` | `#FAFAF9` | `#0A0A0B` |
| `--surface-raised` | `#F5F5F4` | `#131316` |
| `--surface-inset` | `#E7E5E4` | `#1D1D22` |
| `--surface-glass-tint` | `#22C55E` | `#4ADE80` |
| `--text-primary` | `#0C0A09` | `#F4F4F7` |
| `--text-secondary` | `#44403C` | `#A0A0AB` |
| `--text-tertiary` | `#787176` | `#7E7E89` |
| `--text-quaternary` | `#A8A29E` | `#595962` |
| `--text-inverse` | `#FAFAF9` | `#0A0A0B` |
| `--accent-primary` | `#22C55E` | `#4ADE80` |
| `--accent-subtle` | `#DCFCE7` | `#14532D` |
| `--accent-emphasis` | `#16A34A` | `#86EFAC` |
| `--border-subtle` | `#E7E5E4` | `#1D1D22` |
| `--border-strong` | `#D6D3D1` | `#2A2A30` |
| `--border-focus` | `#22C55E` | `#4ADE80` |
| `--status-success` | `#16A34A` | `#4ADE80` |
| `--status-warning` | `#D97706` | `#F59E0B` |
| `--status-danger` | `#DC2626` | `#EF4444` |
| `--status-info` | `#2563EB` | `#3B82F6` |

### 5.2 Typography

| Token | Value |
|---|---|
| Body stack | `-apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", Inter, sans-serif` |
| Mono stack | `"JetBrains Mono", ui-monospace, SFMono-Regular, monospace` |
| `.t-display-lg` | 600 64px/1.05, tracking -0.02em |
| `.t-display` | 600 48px/1.08, tracking -0.02em |
| `.t-title-lg` | 600 28px/1.20, tracking -0.01em |
| `.t-title-md` | 600 22px/1.25 |
| `.t-title-sm` | 600 17px/1.35 |
| `.t-body-lg` | 400 17px/1.55 |
| `.t-body` | 400 15px/1.55 |
| `.t-body-sm` | 400 13px/1.50 |
| `.t-caption` | 400 12px/1.45 |
| `.t-label` | 500 11px/1.20, tracking 0.04em, uppercase |
| `.t-mono` | 400 14px/1.50, mono stack |

### 5.3 Spacing (4pt baseline)

`--space-xxs: 2px · --space-xs: 4px · --space-sm: 8px · --space-md: 12px · --space-lg: 16px · --space-xl: 24px · --space-xxl: 32px · --space-3xl: 48px · --space-4xl: 64px · --space-5xl: 96px`

### 5.4 Radii

`--radius-sm: 6px · --radius-md: 10px · --radius-lg: 14px · --radius-xl: 20px · --radius-xxl: 28px · --radius-pill: 999px`

### 5.5 Elevation

| Token | Light shadow | Dark shadow |
|---|---|---|
| `--elev-raised` | `0 1px 3px rgba(0,0,0,.04)` | `0 1px 3px rgba(0,0,0,.50)` |
| `--elev-floating` | `0 4px 12px rgba(0,0,0,.08)` | `0 4px 12px rgba(0,0,0,.60)` |
| `--elev-modal` | `0 24px 48px rgba(0,0,0,.18)` | `0 24px 48px rgba(0,0,0,.70)` |

### 5.6 Motion

| Token | Value |
|---|---|
| `--dur-snap` | 120ms |
| `--dur-short` | 200ms |
| `--dur-medium` | 350ms |
| `--dur-long` | 550ms |
| `--ease-standard` | `cubic-bezier(.25, .10, .25, 1)` |
| `--ease-emphasized` | `cubic-bezier(.20, .00, .00, 1)` |
| `--spring-snappy` | `cubic-bezier(.18, .89, .32, 1.28)` |

## 6. Components

Each component is implemented as an Astro `.astro` file under `src/components/`. Style scoped or scoped-with-tokens.

| Component | Variants | Notes |
|---|---|---|
| `LeafButton` | primary · secondary · ghost · destructive × sm · md · lg | Existing app spec; corner radius 10px, snappy spring on hover |
| `LeafInput` | md · lg + states (rest / focus / error / disabled) | 36–44px height, 12px h-padding, accent focus border 2px |
| `LeafCard` | rest · raised · glass | `glass` uses backdrop-filter, accent tint @ 8–12% |
| `LeafBadge` | accent · muted · status | E.g. "ALPHA", "v1.0.0-alpha.15" |
| `LeafNav` | sticky header with backdrop-filter blur | Session-aware Sign in/Dashboard toggle preserved |
| `LeafFooter` | 3-column sitemap + brand row | Static, shared across all pages |
| `LeafCodeBlock` | mono + hairline + copy button | For MCP query examples, file paths |
| `LeafAccordion` | expanding rows + chevron animation | FAQ section |
| `LeafTabBar` | tab buttons + underline indicator | `/signup` panel switching |
| `LeafTable` | bordered + zebra + sticky head | Pricing comparison |
| `LeafAnchorNav` | sticky sub-nav with scroll-progress underline | `/product`, `/privacy` |
| `LeafEyebrow` | small uppercase mono label | Section dividers ("№01 · ON YOUR MAC") |
| `LeafLogo` | wordmark + mark | PNG @1x/@2x/@3x via srcset; drop-in SVG when provided |

**Icon strategy:** SVG sprite generated from `~/Desktop/Leaf/design-elements/icons/` (35+ existing) + SF Symbols ported to SVG for missing ones. All `currentColor`-aware. Loaded once per page via `<symbol>` defs.

**Logo strategy:** PNG only for now. `LeafLogo` component renders `<picture>` with `srcset` at 48px / 96px / 144px. Drop-in SVG replacement when Alex provides one.

## 7. Page wireframes

### 7.1 `/` Landing — scroll order

1. **Header nav** (sticky, backdrop blur)
2. **Hero** — H1 "Stop briefing your AI. It can just know." + supporting paragraph + 2 CTAs + animated live MCP demo in glass card
3. **§01 What's captured (Layer A)** — eyebrow + H2 "Captured automatically. Nothing leaves your laptop unencrypted." + 6-card grid 3×2 (App usage · Git activity · AI tools · Calendar · Focus state · File touches) + link "Read privacy details →"
4. **§02 Integrations (Layer B)** — eyebrow + H2 "Connected to where your team works." + 3 large cards (Linear · GitHub · Slack) + 2 small cards (AI tool hooks · Degraded providers) + faded "coming soon" row + CTA "View all integrations →"
5. **§03 Three surfaces** — eyebrow + H2 "One memory layer. Three surfaces." + 3 cards (MCP · Native macOS · Slack bot) + CTA "Read product details →"
6. **§04 Use cases** — eyebrow + H2 "What Leaf actually solves." + 4 horizontal cards (Async handoff · Prod-bug archaeology · Decision archaeology · AI coaching), each with quote-question + arrow-answer
7. **§05 Privacy teaser** — eyebrow + H2 "Your manager can't peek without your permission." + 3 bullets (Local-first / E2E / Share Controls) + 2 CTAs ("How privacy works →" + "Open-source verifiability →")
8. **§06 Pricing teaser** — eyebrow + 3 plan cards (Free / Team highlighted / Enterprise) + CTA "See full comparison →"
9. **§07 FAQ** — 6–8 accordion rows + CTA "Full FAQ in docs →"
10. **CTA section** — Top block: Early access $10 OxaPay button. Bottom block: Email waitlist (Turnstile + Worker, existing).
11. **Footer**

### 7.2 `/product` — Deep feature dive

Single long page with **sticky sub-nav** (`LeafAnchorNav`):
`▸ What's captured  ▸ Integrations  ▸ Surfaces  ▸ Architecture`

Sections:
- **§1 What's captured** — full list of Mac native signals (NSWorkspace / AX / EventKit / FSEvents / AI hooks) + explicit "Never captured" list (file contents / screenshots / keystrokes / prompt-response / email bodies / message text) + product UI screenshot of Activity tab in tilted glass card
- **§2 Integrations** — Linear / GitHub / Slack detailed cards with per-event-kind lists, OAuth flow description, polling cadence, what's not captured
- **§3 Surfaces** — MCP (15-tool list with descriptions) / Native macOS (screenshots of Home / Activity / Team / Connections) / Slack bot (example thread dialog)
- **§4 Architecture diagram** — 2D flat or isometric: Mac collectors → encrypted local SQLCipher → MCP server / macOS UI / Slack bot / E2E relay. Each arrow labeled with transport + encryption.
- **Bottom CTA** — "Try it free · Read whitepaper"

### 7.3 `/pricing` — Plans + comparison + billing FAQ

- **Hero** — "Pricing that scales with your team."
- **3-tier plan cards** — Free / Team (highlighted, recommended) / Enterprise. Same as landing teaser but with full feature list per card.
- **Comparison table** — full feature matrix (Mac capture / integrations / MCP local / native app / team presence / Share Controls / E2E sharing / Slack bot / seats / SSO / audit log / dedicated relay / SLA / support tier)
- **Billing FAQ** — 4–5 questions (cancellation / refunds / seat add-remove / annual discount)
- **Bottom CTA** — Early access $10 OxaPay

All pricing is **mock for now** — values are placeholders; real billing flow is out of scope.

### 7.4 `/privacy` — Privacy deep-dive

Sections (sticky sub-nav):
1. **What's captured vs not** — visual matrix, two side-by-side columns
2. **Local-first storage** — diagram (Mac drive → SQLCipher AES-256 → key in Keychain) + plain-text facts (file path, encryption, key storage, file permissions)
3. **End-to-end encryption** — diagram (Your Mac / Teammate Mac / Relay) + cryptographic primitives (X25519 / XChaCha20-Poly1305 / team key rotation)
4. **Share Controls — opt-in transparency** — big callout "Your manager can't peek" + 4 principles (default empty whitelist / per-app per-event-type / admin can't override / invisible mode)
5. **Won't-list** — public commitment to never building surveillance features (manager mode / productivity scores / screen recording / keylogging / OCR / prompt-response capture)
6. **Verify it yourself** — open-source links (GitHub repo, crypto module path, audit history when available)

### 7.5 `/open-source`

- **Hero** — "Open core. Verifiable privacy."
- **OSS-vs-closed matrix** — two-column table (current site copy preserved)
- **License** — placeholder "TBD: Elastic 2.0 vs AGPL"
- **Repo card** — GitHub button + stars + last release
- **Bottom CTA** — Read whitepaper / Star on GitHub

### 7.6 `/changelog`

- Card-per-release feed, paginated. Each card: date · time · author · `[ALPHA]` tag · H3 title · 3-line preview · expand
- RSS link badge top-right
- Data source: same JSON-feed pipeline as today (Cloudflare Worker → Telegram approval → published JSON). Renderer is restyled, pipeline unchanged.

### 7.7 `/signup` — Auth (5 panels)

Centered card on a muted canvas. 5 in-page panels switched by JS (existing logic preserved):
- Sign in (email + password + show toggle + OAuth Google/GitHub + "Forgot password?")
- Create account (name + email + password + 6-digit OTP)
- Verify code (6-box mono OTP, auto-advance, 30s resend cooldown rendered as **circular progress** instead of text)
- Forgot password
- Reset password

All Supabase wiring, OAuth providers, OTP flow, Turnstile, and cooldown logic are preserved.

### 7.8 `/dashboard` — Authed account

Same content surface as today (name / email / provider / member-since / download .dmg / sign out / delete account), restyled in the new system. Section cards for Account / Download / Danger zone.

### 7.9 `/terms`

Single typographic page. Right-side sticky TOC if ≥4 sections. Existing content, restyled.

## 8. Tech stack & file layout

**Build:** Astro (latest stable). Static output. Local dev via `pnpm dev`. Production build via `pnpm build` → `dist/`.

**Deployment:** `rsync` (or scp) from `dist/` to `/var/www/leaf/` on the VPS. Nginx config unchanged.

**Repository layout:**

```
leaf-web/                           (new repo or `web/` subdir in gundemtech/leaf)
├─ astro.config.mjs
├─ package.json
├─ tsconfig.json
├─ public/
│  ├─ assets/
│  │  ├─ logo/                  ← PNG @1x/@2x/@3x (drop-in SVG later)
│  │  ├─ icons/                  ← SVG sprite source
│  │  └─ og-images/              ← OG card images per page
│  ├─ favicon.svg                  ← emoji or vectorized logo
│  ├─ robots.txt
│  └─ sitemap.xml                  ← generated by Astro or hand-rolled
├─ src/
│  ├─ components/
│  │  ├─ LeafButton.astro
│  │  ├─ LeafInput.astro
│  │  ├─ LeafCard.astro
│  │  ├─ LeafBadge.astro
│  │  ├─ LeafNav.astro
│  │  ├─ LeafFooter.astro
│  │  ├─ LeafCodeBlock.astro
│  │  ├─ LeafAccordion.astro
│  │  ├─ LeafTabBar.astro
│  │  ├─ LeafTable.astro
│  │  ├─ LeafAnchorNav.astro
│  │  ├─ LeafEyebrow.astro
│  │  ├─ LeafLogo.astro
│  │  └─ sections/              ← page-level sections
│  │     ├─ HeroLanding.astro
│  │     ├─ LayerACapture.astro
│  │     ├─ LayerBIntegrations.astro
│  │     ├─ ThreeSurfaces.astro
│  │     ├─ UseCases.astro
│  │     ├─ PrivacyTeaser.astro
│  │     ├─ PricingTeaser.astro
│  │     ├─ FAQ.astro
│  │     └─ WaitlistCTA.astro
│  ├─ layouts/
│  │  ├─ BaseLayout.astro        ← html shell + nav + footer + OG meta
│  │  └─ AuthLayout.astro        ← minimal layout for signup/dashboard
│  ├─ pages/
│  │  ├─ index.astro             ← /
│  │  ├─ product.astro
│  │  ├─ pricing.astro
│  │  ├─ privacy.astro
│  │  ├─ open-source.astro
│  │  ├─ changelog/
│  │  │  ├─ index.astro
│  │  │  └─ feed.xml.ts          ← RSS generator (preserves existing format)
│  │  ├─ signup.astro
│  │  ├─ dashboard.astro
│  │  └─ terms.astro
│  ├─ styles/
│  │  ├─ tokens.css              ← all CSS variables
│  │  ├─ reset.css
│  │  └─ global.css
│  └─ scripts/
│     ├─ supabase-client.ts      ← session detection + auth flows
│     ├─ waitlist.ts             ← form + Turnstile + Worker POST
│     └─ session-aware-nav.ts    ← Sign in/Dashboard toggle
└─ README.md
```

**Repo decision (open question — see §13):** new standalone repo `gundemtech/leaf-web` vs `web/` subdir in `gundemtech/leaf`.

**Deploy script (initial draft):**

```bash
#!/usr/bin/env bash
set -euo pipefail
pnpm install --frozen-lockfile
pnpm build
rsync -avz --delete dist/ root@gundem.tech:/var/www/leaf/
ssh root@gundem.tech 'systemctl reload nginx'
```

## 9. Must-preserve constraints

These are wiring details that the redesign must not break. Confirmed against `~/Desktop/Leaf/leaf-docs/infra/README.md` §19 "Theming" and the captured live HTML.

| Constraint | Source | How preserved |
|---|---|---|
| Supabase auth (sign in / create / OTP / reset) | Publishable key `sb_publishable_bgsd10ucTMsf6D-S8jwpvg_bMo53xF_`, project `jpzqmtmmypnzqhdltcvr` | Same keys + same Supabase JS via CDN; auth UI rewritten but flow unchanged |
| Cloudflare Turnstile waitlist | Site key `0x4AAAAAADCjktFBs6RTYJTZ`, secret in Worker | Same site key in form; new Astro page renders same Turnstile widget |
| Cloudflare Worker `/api/contact` | Existing endpoint, D1 backend | Unchanged. Astro form POSTs to same URL. |
| OxaPay early-access link | `https://pay.oxapay.com/15460469` | Linked from new `/`, `/pricing`, and CTA section |
| RSS feed at `/changelog/feed.xml` | RSS 2.0, last 50 posts | Astro endpoint `feed.xml.ts` generates identical format |
| JSON feed at `/changelog/latest.json` | Dynamic load by landing | Endpoint preserved; new landing fetches same URL |
| Clean URLs (no `.html` suffix) | Nginx rewrites | Astro builds to `/product/index.html` so clean URLs work without nginx changes |
| Session-aware header | Supabase `getSession()` polling | Ported to `session-aware-nav.ts` script |
| OG meta + Twitter cards | Per-page | Each Astro page declares OG meta in frontmatter; `BaseLayout` renders |
| SEO meta + favicon | Title/description per page | Astro `<head>` per page |
| Sparkle .dmg download | From `/dashboard` after auth | Link preserved on restyled dashboard |
| Color-scheme native autofill / scrollbar | `color-scheme` CSS hint | Set in `tokens.css` |

## 10. Migration strategy

**Approach: big-bang replacement on a feature branch, atomic deploy.**

1. Develop in a new repo (or `web/` subdir).
2. Build to `dist/`, dry-run on a staging subdomain (e.g. `leaf-preview.gundem.tech`) hosted from a second nginx location.
3. Run acceptance smoke tests (§11) against staging.
4. When approved: `rsync` overwrites `/var/www/leaf/` in one atomic swap.
5. Old HTML files are removed by `rsync --delete`. Rollback path: keep tarball of old `/var/www/leaf/` (`tar -czf /var/backups/leaf-pre-redesign-$(date +%Y%m%d).tar.gz /var/www/leaf/`) before deploy.

**Why big-bang:** the new design is opinionated and the old pages don't visually coexist with the new ones. Mixing them mid-rollout looks broken to visitors.

## 11. Acceptance criteria (visual + functional smoke)

**Visual:**

- All pages render correctly on Safari (macOS), Chrome (macOS), Firefox (macOS), Mobile Safari (iOS 17+), Chrome (Android).
- Light/dark mode toggle via OS-level preference works on every page; no flash of wrong theme on page load.
- `prefers-reduced-motion: reduce` disables hero typing animation, accordion expand spring, and card hover elevation transitions.
- Lighthouse audit: Performance ≥90, Accessibility ≥95, Best Practices ≥95, SEO ≥95 on `/` and `/product`.
- All text passes WCAG AA contrast (4.5:1 body, 3:1 large text) in both themes.

**Functional:**

- Header session-aware: anonymous user sees "Sign in"; authenticated user sees "Dashboard". Tested with `supabase.auth.getSession()` mock.
- Waitlist form: enter email → Turnstile challenge → submit → success message. Tested end-to-end against staging Worker.
- Signup flow: create account → verify OTP → land on `/dashboard`. Tested with real Supabase test account.
- Sign-in flow with OAuth Google + GitHub.
- Forgot password → reset flow (email via Resend).
- Dashboard: download .dmg button hits `updates.gundem.tech`, sign out clears session, delete account clears Supabase user.
- OxaPay button opens external payment link in new tab.
- Changelog page renders latest 50 posts from JSON feed; RSS feed validates as RSS 2.0.
- Clean URLs work (`/product` not `/product.html`); direct `.html` hits 301-redirect.
- All anchor links in sticky sub-nav (`/product`, `/privacy`) scroll smoothly to correct section.

## 12. Out of scope (this spec)

- **Whitepaper redesign** (`leaf-docs.gundem.tech`) — follow-up spec. Will reuse §5 tokens by porting them into `~/Desktop/Leaf/leaf-docs/docs/assets/extra.css`. Header override in `~/Desktop/Leaf/leaf-docs/overrides/partials/header.html` updated to match new wordmark / nav style.
- **Internal dashboard redesign** (`leaf-internal.gundem.tech`) — follow-up spec. CSS variable swap in `~/Desktop/Leaf/leaf-internal/docs/assets/extra.css` to point at §5 tokens.
- **Logo vectorization** — Alex will deliver SVG separately. Until then, PNG `@1x/@2x/@3x` via srcset.
- **Real pricing wiring** — pricing values on `/pricing` are mock placeholders; actual billing integration is a separate track.
- **Blog / writing surface** — not in this spec; can be added later as `/blog` via Astro content collections.
- **Internationalization** — site is English-first; Russian translation deferred.
- **Animated architecture diagram on `/product`** — first version is static SVG; animated version is a polish task post-launch.

## 13. Open questions for implementation

These are decisions deferred to the implementation phase or owner approval:

1. **Repo location** — new standalone `gundemtech/leaf-web` (clean separation; site has its own lifecycle) **or** `web/` subdir inside `gundemtech/leaf` (one repo, easier to keep in sync)? **Recommend: new repo** because the site is touched on a different cadence than app code and the app repo's `pre-push-leaf` checklist is irrelevant for marketing content.
2. **Hero MCP demo** — typed-text + cascading-result animation (current pattern, polished) **or** real video recording of a Claude Code session **or** static screenshot? Recommend: typed-text animation first (lightweight, works in dark/light, respects reduce-motion); upgrade to video later if it adds story.
3. **Architecture diagram on `/product` §4** — flat 2D **or** isometric **or** annotated screenshot? Defer; first pass flat 2D for ship velocity, iterate after launch.
4. **FAQ source** — hand-write 6–8 questions in spec **or** pull from `leaf-docs.gundem.tech/faqs/`? Recommend: hand-write 6–8 punchy ones for landing, link "Full FAQ in docs →" to whitepaper FAQ.
5. **Use case scenarios** — exact wording for the 4 cards. Spec has draft text; final copy review with Alex in implementation.
6. **Pricing seat limit** — "Up to 20 seats" for Team plan is taken from current site; confirm with Sasha before locking.
7. **Hero CTA** — `[Install for macOS →]` lands on `/dashboard` (requires auth) **or** opens .dmg directly **or** routes to `/signup`? Confirm intended journey.
8. **Lighter-weight build alternative** — if Astro setup creates friction for Sasha, fall back to vanilla HTML with shared `<header>`/`<footer>` includes via PostHTML or a tiny build script. Decide after first prototype.

## 14. Follow-up specs (post this one)

1. `2026-MM-DD-leaf-whitepaper-restyle-design.md` — port tokens into MkDocs Material; restyle header / sidebar / cards / admonitions to match.
2. `2026-MM-DD-leaf-internal-dashboard-restyle-design.md` — swap CSS variables in `extra.css`; align status badges + progress bars with new system.
3. `2026-MM-DD-leaf-logo-svg-vectorization.md` — once SVG arrives, drop-in replace in `LeafLogo.astro` + favicon.svg.

---

## Appendix A — Reference inventory (what we drew from)

- **App design system tokens:** `Packages/LeafCore/Sources/LeafCore/UI/Tokens/` (LeafColor / LeafType / LeafSpace / LeafRadius / LeafElevation / LeafMotion). All §5 values are verbatim ports.
- **App components:** `LeafButton`, `LeafInput`, `LeafCard`, `LeafBadge`, `LeafCodeBlock` patterns ported to `.astro` components in §6.
- **Current site:** captured to `/tmp/leaf-landing-snapshot/` via `curl` audit (all HTML + linked `/assets/theme.css?v=1`). Reviewed in audit pass to extract must-preserve constraints.
- **Infrastructure runbook:** `~/Desktop/Leaf/leaf-docs/infra/README.md` §19 "Theming" — page inventory, nginx routes, Supabase/Worker/Turnstile/OxaPay/Resend wiring.
- **Visual references:** Linear (linear.app), Vercel (vercel.com), Stripe (stripe.com) — design DNA per §4.

## Appendix B — Glossary

- **Layer A** — on-device signal collection (NSWorkspace / AX / EventKit / FSEvents / AI tool hooks). Defined in app whitepaper.
- **Layer B** — connected SaaS providers (currently Linear / GitHub / Slack; expanding).
- **Three surfaces** — MCP server / Native macOS app / Slack bot. Three access paths to the same memory layer.
- **Share Controls** — opt-in per-app, per-event-type whitelist controlling what's visible to teammates. Default = nothing.
- **E2E** — end-to-end encryption: X25519 handshake + XChaCha20-Poly1305 symmetric, relay never sees plaintext.
- **Won't-list** — public commitment to features Leaf will never build (manager surveillance, productivity scores, screen recording, keylogging, OCR, prompt-response content capture).
