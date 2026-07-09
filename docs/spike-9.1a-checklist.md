# Spike 9.1a — Telegram webview ↔ MetaMask Mobile round trip (manual, on-device)

**Why (spec §9.1a):** Telegram's in-app browser does not pass the
`metamask://` scheme through (MetaMask/metamask-sdk#1103, open since 2024).
The known production mitigation is the universal-link form
(`https://metamask.app.link/…`), already used by production Telegram-bot
deposit deeplinks. Whether a relay/universal-link architecture survives the FULL
round trip — wallet dapp → MetaMask → **back into the wallet dapp** — is
unverified. The return leg is the fragile part. **This spike gates the M1
wallet dapp ship decision on each release** (webview behavior shifts under
Telegram/MetaMask app updates, so it is a recurring checklist, not a
one-time result).

**Harness:** serve `webapp/spike/telegram-webview.html` over HTTPS, attach it
to a test bot as a WebApp button, run per device. Also open the REAL wallet dapp
(`webapp/index.html`) from inside MetaMask Mobile's dapp browser (probe 7).

| # | Probe | iOS Telegram | Android Telegram | Notes |
|---|-------|--------------|------------------|-------|
| 1 | Environment: WebApp present, initData length > 0, `window.ethereum` absent in Telegram webview | ☐ | ☐ | |
| 2 | Universal link opens MetaMask app | ☐ | ☐ | expected: works |
| 3 | Raw `metamask://` scheme | ☐ | ☐ | expected: blocked |
| 4 | Inside MetaMask dapp browser: provider injected, accounts + chain readable | ☐ | ☐ | |
| 5 | Inside MetaMask dapp browser: `eth_signTypedData_v4` completes | ☐ | ☐ | |
| 6 | Return leg: `t.me` link from the page reaches the bot chat | ☐ | ☐ | THE fragile step |
| 7 | Full flow: chat button → wallet dapp (in MetaMask browser via universal link with `?order=` fallback since initData is absent outside Telegram) → sign → grant lands → chat card updates | ☐ | ☐ | |

**Decision matrix (record per release):**
- 4–7 pass inside MetaMask's browser → ship M1 with the universal-link route
  (chat button → `https://metamask.app.link/dapp/<wallet-dapp-url>?order=<ref>`);
  the intake must then accept order-scoped auth for the `?order=` entry
  (single-use high-entropy ref + wallet signature is the authenticator) —
  see the M2 hardening note below.
- 6 fails → keep the flow one-directional (user returns to Telegram
  manually; the chat card updates from the keeper result regardless — the
  return leg is UX polish, not correctness).
- Everything fails → transfer lane stays the only lane on that platform;
  typed failures already render the fallback card.

**Current status:** the wallet dapp core is transport-agnostic and fully
tested against a mock provider + the golden-vector cross-check. Plan 1 /
0.3.0 proceeded on maintainer confirmation of the Telegram button →
MetaMask dapp-browser hop below; fill the exact iPhone + Android checklist
rows here when the full device matrix is rerun.

**Plan 1 / 0.3.0 hop status:** proceeding as of 2026-07-09 on explicit
maintainer confirmation that the Telegram chat button →
`https://link.metamask.io/dapp/<host>/spike/hop-probe.html?order=probe123&token=tok456`
→ MetaMask dapp browser hop was tested and works. Record the exact iPhone +
Android device rows here when available.

**M2 note:** when the account is 7702-upgraded, USDC validates permits via
ERC-1271 (SignatureChecker branches on `isContract(owner)`); vectors for the
upgraded state are fork-test material, deliberately not faked hermetically.
