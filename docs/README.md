# Documentation map

- **[adoption.md](adoption.md)** — THE adoption guide: the five things a
  consuming app supplies, worked end-to-end against `EchoSpendRouter` /
  `EchoSpendRouterSuite` (the in-repo reference consumer).
- **[spike-9.1a-checklist.md](spike-9.1a-checklist.md)** — the recurring
  manual on-device checklist (Telegram webview ↔ MetaMask Mobile round trip)
  that gates each wallet dapp release.
- **Security invariants** — the authoritative do-not-weaken list lives in the
  top-level [README.md](../README.md); `CONTRIBUTING.md` summarizes it for
  reviewers.
- **Spec section references** — `§n` citations throughout the code and docs
  refer to the package's design spec (§3.2 = the five-item adoption
  contract, §8 = the testing matrix, §10 = the invariants). The normative
  content of every cited section is restated where it is enforced (module
  docs, README invariants, adoption.md); the citations are provenance, not
  required reading.
