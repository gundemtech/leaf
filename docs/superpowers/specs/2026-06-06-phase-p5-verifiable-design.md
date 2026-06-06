# Phase P5 — Verifiable Cloud Inference (v1.5): Client-Side Attestation

**Date:** 2026-06-06
**Status:** Design — pending plan
**Author:** brainstorm session (AI Coworker track, final phase)

## Problem

Leaf's cloud-inference path is **trust-based**. When the AI Coworker sends a
prompt (structured work facts by default; escalated bodies on explicit per-action
consent), privacy rests on the provider's promise — in-region, no training, no
retention — not on a property the client can *verify*. The track's safety contract
records this honestly (§8.5: "trust-based ≠ verifiable") and defers the verifiable
story to v1.5. P5 is that phase: move toward an architecture where the inference
operator is **blind** to the prompt and the client **proves** this before sending.

## Constraints discovered (fresh research, 2026-06-06)

Three findings reshape what "verifiable" can mean *today* and define P5's honest scope:

1. **Frontier-model + client-verifiable attestation do not co-exist yet.** Frontier
   proprietary models are not licensed to confidential-GPU operators. Verifiable
   attestation today implies an **open-weight** model (e.g. Llama-class) served on a
   confidential-GPU TEE (candidate operators: Phala, Tinfoil, Edgeless Continuum,
   OpenPCC — the set already named in the whitepaper roadmap).
2. **No native client-side attestation-verification library exists for our client
   platform.** Vendor verifiers target other runtimes; a faithful verifier on our
   side must be implemented against the documented attestation format.
3. **EU-region confidential-GPU inference is not yet guaranteed** by any operator —
   a documented soft gap for the PoC, a hard requirement to revisit before any
   production default.

## Decisions

- **Two honest tiers, not a replacement.** A new **opt-in, experimental** inference
  path (`InferencePath.attested`) runs an **open-weight** model with client-side
  attestation. The existing frontier paths (own-key direct + provided-inference proxy)
  remain the **default, trust-based** tier. Users who want cryptographic verifiability
  accept the open-weight tradeoff; everyone else is unaffected.
- **Attestation applies to our endpoint only.** The own-key direct path talks to the
  model vendor's managed API, which does not expose attestation to us; it stays
  trust-based by nature. Only an operator endpoint we route to can be attested.
- **The data boundary does not change.** P5 changes *where* inference runs and *how*
  the client proves it — never *what* fields enter the prompt. The egress boundary
  (`makeContext` / `makeEscalation` and the opaque prompt-safe types) and the
  prompt-injection defenses are untouched; their sentinel tests must still pass.
- **Honest-claim discipline is load-bearing (§8.5).** The product does **not** market
  "verifiable" until the client verifies the full chain end-to-end. The verifier
  carries an explicit assurance level; until the complete certificate-chain and
  transparency-log checks land, assurance stays at the PoC level and the path stays
  labelled experimental and off by default.
- **Metadata side-channel (§8.6) — deferred.** Padding / oblivious-transport
  mitigations are out of scope for the PoC; the claim remains "content protected,
  metadata (roster / timing / size) partially" — documented, not closed.

## Architecture

### Verify-before-send (fail-closed)

The client obtains the operator's attestation, **verifies it locally, and only then
sends the prompt** over a transport cryptographically bound to the attested runtime.
Any verification failure aborts the send — the prompt never leaves the device.

The targeted attestation model (per the operator's published format): a
hardware-signed runtime report, a published expected measurement, and an
enclave-generated transport public key **bound** to the measured runtime. The client's
load-bearing liveness guarantee is that **binding** — the prompt is sent only over a
connection whose server key equals the attested key.

### The seam (public, testable)

A small public seam in the shared core, mirroring the existing inference/egress seam
pattern (public protocol + injectable substrate + concrete implementation supplied
privately):

- **Value types** — an attestation challenge, a verdict (verified flag, assurance
  level, the bound transport key, and per-check booleans), a normalized parsed
  attestation, and an error type. The verdict **never** carries prompt or event
  content and **never** the raw expected measurement (booleans only).
- **`AttestationDocumentParser`** — converts an operator's attestation bytes into the
  normalized parsed form. The PoC ships a parser for a simple/synthetic format
  (fully unit-tested); a parser for the real operator binary format is a follow-up.
- **`AttestationVerifier`** + a fail-closed no-op substrate (the safe default that
  always refuses). The concrete verifier performs the cryptographic checks over the
  normalized form against **injected** trust values.
- **`AttestedSummarizer`** — conforms to the existing summarizer protocol. It runs
  verify-before-send, fails closed (no network on a failed verdict), records an
  audit entry before sending, and pins the request transport to the bound key.

### What stays private

The pinned trust values (expected measurement, trust-root key, operator endpoint) and
the operator-specific wiring live only in the private module — the verification
*algorithm* is public (verifiability is the claim, not the moat), the *values* are not.

## Scope

**In P5 (the verifiable scaffold):** the public seam and value types; the public
verification core with synthetic-vector tests covering every fail mode; the
fail-closed `AttestedSummarizer` with verify-before-send, audit-before-send (via an
audit-sink protocol, spy-tested), and transport pinning; the private placeholder
operator wiring (fails closed until real trust values exist); an off-by-default opt-in
flag; this design doc. The `.attested` path is **built, tested, and injectable, but not
wired into a runtime caller** — mirroring the provided-inference path, which is likewise
built-and-tested-but-not-live.

**Deferred to a later production-wiring phase:** the real operator-format parser and
trust values; full certificate-chain and transparency-log verification (which raises
assurance above the PoC level); a persisted attestation audit table and its read-back
surface; routing a live caller through `.attested`; EU-region resolution.

## Testing

- Verification core, synthetic vectors: a valid attestation verifies (PoC assurance,
  bound key returned); bad signature, wrong measurement, stale/absent freshness, and
  transport-key mismatch each fail closed.
- **Fail-closed sentinel:** a failing verifier produces **zero** network sends while
  still recording the (unverified) audit entry — the P5 analog of the egress sentinel.
- **Transport pinning:** a server key that differs from the attested key aborts before
  the body is sent.
- **Boundary regression:** the existing egress sentinel tests pass unchanged.
- **Honest-claim:** the verifier never emits the full assurance level in P5; the path
  is off by default.
