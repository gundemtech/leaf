# ADR-014 — E2E encryption with untrusted relay

**Status:** Accepted (2026-05, with v4 strategy refresh)

## Context

Trust-required cloud sharing is a deal-breaker for the regulated teams (fintech, healthtech, defense) that v4 names as the priority ICP. Pure peer-to-peer is too complex for v1 — devices are not always online, key distribution is fiddly, NAT traversal is non-trivial.

We need a middle path: a relay that is required for liveness but cannot read content.

## Decision

**Supabase as an untrusted relay.** Keys are generated on-device and never leave the device. Symmetric crypto runs end-to-end between team members; the relay sees opaque blobs.

- Asymmetric handshake: X25519 key exchange.
- Symmetric encryption today: AES-GCM-256; XChaCha20-Poly1305 named in the v4 strategy as the longer-term symmetric primitive.
- Server cannot decrypt.

## Consequences

- Architectural privacy guarantee: even a full server compromise cannot leak team memory.
- Some UX complexity: key recovery, onboarding, and device-loss scenarios require explicit thought (iCloud Keychain backup is the primary mitigation).
- Relay is required infrastructure for Team-tier — but it is dumb, swappable, and self-hostable for Enterprise.
