# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The package version is stamped in `VERSION`, `vectors/VERSION`, `mix.exs`, and
`webapp/config.json`; `CONTRACT_VERSION` pins `SpendRouter.version()` because
package releases can ship zero contract bytecode changes. `scripts/check-version.sh`
(run in CI) fails on divergence.

## [Unreleased]

### Changed

- **The geofence is now a country blocklist derived from the terms.**
  `ctx.compliance.geo_allow` (allowlist) is replaced by `:geo_block`, and the
  blocklist is no longer configuration: `Terms.restricted_countries/1` parses
  it from a `Restricted countries: CU, IR, KP.` line in the same terms bytes
  that are hashed for acceptance, so the geofence cannot drift from the served
  terms (the `SPEND_GEOFENCE_COUNTRIES` env var is gone). The fail-closed
  posture is unchanged: missing country evidence, a missing/empty/malformed
  blocklist, and a malformed blocklist entry all still deny with `451`;
  `Compliance.check!/1` rejects a stale `:geo_allow` key by name at boot, and
  a terms rewrite that breaks the marker line fails the deploy.
  **Upgrade note:** adding the marker line to an already-deployed terms
  document changes the terms bytes, so the accepted hash rotates and every
  existing user must re-accept — plan the upgrade as a terms release.

### Added

- Geofence denials append a `geo_denied` audit event (`user_ref: nil` — the
  denial deliberately precedes authentication) through the configured
  compliance store, capped per country per `ctx.rate` window because the
  denial path is unauthenticated. Recording never changes the `451`.
- Wallet dapp network auto-switch: a wallet-vs-config chain mismatch now asks
  the wallet to switch (EIP-3326 `wallet_switchEthereumChain`), adds the chain
  from the new optional `config.json` `chain` block on 4902 (EIP-3085, plain
  or MetaMask-mobile-wrapped), and re-reads `eth_chainId` before proceeding.
  Rejections and unlanded switches stay the typed `wrong_chain`; the
  config-drift dead state still never switches (there is no right chain to
  switch to until the operator redeploys).

### Fixed

- `go.html` no longer auto-navigates on mobile: a JS-initiated navigation to
  the wallet universal link from an embedded webview (Telegram's in-app
  browser) carries no user gesture, so iOS routed it to the App Store instead
  of the installed wallet. The hand-off is the user's tap on the launch
  button; desktop keeps its same-origin auto-hop to `index.html`.

### Planned

- **M2 — delegation lane (ERC-7710):** standing delegation with caveats,
  redeemed through the user's account — one-tap payments over the same
  router path. The base contract already carries the `delegationManager`
  introspection view and the keeper's grant registry stores delegation
  grants, but no redemption path exists yet.

## [0.5.0] - 2026-07-14

Compliance-layer release. No Solidity bytes changed; `CONTRACT_VERSION`
remains `0.2.0`.

### Added

- Compliance-layer request evidence, a fail-closed country geofence returning
  `451`, a terms gate returning `428`, and `POST /terms` acceptance.
- `DelegatedSpend.Compliance.Store` for acceptance and audit-event persistence.
- `DelegatedSpend.Compliance.Meta.build/4` — edge-metadata builder (client IP
  by `x-forwarded-for` hop count, country from the trusted edge header only).
- `DelegatedSpend.Compliance.check!/1` — boot-time validation of
  `ctx.compliance` (the `BootCheck` idiom: deny-all misconfiguration fails the
  deploy, not every request).

### Changed

- Intake handlers now expose three-arity request-metadata forms while keeping
  their two-arity compatibility forms; a two-arity call with compliance
  configured logs a warning naming the deny-all consequence.
- `user_tx` order views withhold the executable `tx` payload until the
  current terms are accepted (the dapp-side gate alone cannot bind callers
  that replay the fetched payload from external tooling).

## [0.4.0] - 2026-07-14

Durable execution-status release. No Solidity bytes changed;
`CONTRACT_VERSION` remains `0.2.0`.

### Added

- Store-backed `:pending`, submitted, mined, and failed execution status that
  survives Keeper restarts, plus atomic execution start and first-terminal
  resolution with exactly-once mined spend accounting.
- Durable tracking of every same-nonce fee-bump hash, with periodic
  reconciliation independent of the Signer's in-memory state.
- Adapter migration requirements for atomic start, idempotent terminal writes,
  unresolved-row preservation, and terminal-status retention.

### Changed

- Successful technical status is now `{:mined, tx_hash}` / `"mined"`
  throughout the Keeper, intake, object door, tests, and docs.
- `result_fn` is best-effort and runs only after a newly stored terminal result;
  callback raises, exits, and throws are logged without crashing the Keeper.
- Durable polling is the recovery mechanism. Callbacks remain hints, and
  product routing, confirmation depth, wallet storage, and business crediting
  stay consumer-owned.
- A `send_raw` error after durable hash write is treated as ambiguous
  submission, never as terminal failure; a late receipt can still settle it.

## [0.3.4] - 2026-07-12

Wallet-dapp theme and trust-boundary release. No Solidity bytes changed.

### Added

- A self-contained CSS/config theming seam, default stock styling, favicon, and
  state stamps for consumer overlays.
- Dapp-side expected-owner and runtime-chain checks: a mismatched wallet or
  stale deployed config refuses before signing or submitting an order.

### Changed

- Launcher CSP permits same-origin theme assets while preserving the
  order-kind-neutral copy: manual transfers credit the same order.

## [0.3.3] - 2026-07-10

Notary-identity release: the published package name drops the `genswarms-`
prefix.

### Changed

- The swarmidx package name is now **`wallet-bridge`** — refs read
  `swarmidx:genlayerlabs/wallet-bridge@0.3.3+`. The GitHub repository keeps
  the `genswarms-wallet-bridge` name. Earlier notary entries stay where they
  were published: `genswarms-delegated-spend` through 0.3.0,
  `genswarms-wallet-bridge` for 0.3.1–0.3.2.

## [0.3.2] - 2026-07-10

Copy release: the wallet dapp speaks bridge, not lanes.

### Changed

- Dapp footer copy is order-kind-neutral ("you authorize exactly what is
  shown — one signature, one action") instead of naming the delegated-spend
  lane; it holds for `permit`, `user_tx`, and `bind` orders alike.
- Manual-transfer panel copy says the funds "credit the same order" —
  consumer-neutral wording (no product vocabulary in package copy).

## [0.3.1] - 2026-07-10

Rename release: the package and repository are now **`genswarms-wallet-bridge`**.
No contract or code-identity changes.

### Changed

- **Renamed the package and repository to `genswarms-wallet-bridge`** (formerly
  `genswarms-delegated-spend`): since 0.3.0 the surface is wider than delegated
  spend — generic wallet-order transport (`user_tx`/`bind`) plus the attested
  wallet dapp and launcher. The swarmidx identity is
  `genlayerlabs/genswarms-wallet-bridge` from this release; releases through
  0.3.0 remain on the old notary name. Code identities are unchanged: the OTP
  app stays `:genswarms_delegated_spend` and the keeper's swarm-object module
  stays `DelegatedSpend.Keeper.Object`, so consumers' path deps and swarm
  handler wiring keep working unmodified.
- Webapp failure copy is consumer-neutral: no chat-transfer-fallback promise
  the package cannot keep on behalf of the adopting app.

## [0.3.0] - 2026-07-09

Wallet dapp consolidation release: permit remains the delegated-spend lane,
while `user_tx` and `bind` add generic wallet-order transport behind the same
static dapp and launcher.

### Added

- `DelegatedSpend.Intake.Token` for ref-scoped, expiring HMAC access tokens,
  plus intake admission that accepts either token auth (`ctx.token_secret`) or
  the existing Telegram `initData` path. Dapp order fetches are now build
  version-pinned and return 409 on stale or missing `"v"`.
- Keeper order kinds: default `permit`, `user_tx`, and `bind`; per-order
  `ttl_s`; registry-only keeper boot without `:signer`, `:router`, or
  `:action`; typed `:wrong_kind` and `:permit_lane_disabled` refusals that do
  not consume orders.
- Kind-aware intake views plus `handle_wallet/2` for single-use bind refs
  (`ctx.wallet_fn`, `ctx.wallet_view_fn`) and `handle_submitted/2` for
  best-effort user-tx reports (`ctx.submitted_fn`). Submitted reports have no
  crediting authority.
- Static webapp routing for permit, `user_tx`, and bind orders; token-aware
  request bodies; manual transfer panel; no-provider open-in-wallet hint; and
  `go.html` launcher with configurable `dappLinkPrefix`.
- Golden `user_tx` order vector and ExUnit fixture test pinning the order-fetch
  wire shape.

### Changed

- Package version stamps move to `0.3.0`; Solidity stays at
  `CONTRACT_VERSION` `0.2.0` because this release changes no contract bytes.

## [0.2.0] - 2026-07-05

First published release (swarmidx `genlayerlabs/genswarms-delegated-spend`).

### Added

- **Supervision-friendly process options:** `Signer.start_link` and
  `Keeper.start_link` accept `name:` (a restarted process stays reachable at
  the same name — app ctx never holds a stale pid); `Intake.Rate.start_link/2`
  (returns `{:ok, pid}`, accepts `name:`); keeper `reconcile_on_init: true`
  runs boot reconciliation as the keeper's own first message, so a
  supervisor restart self-heals without an external `reconcile_boot` call.
  Defaults preserve existing behavior exactly.

- **Keeper swarm-object door (`DelegatedSpend.Keeper.Object`):** a GenSwarms
  `ObjectHandler` over the keeper core. Other swarm objects register orders,
  query status, and reset revert backoff by JSON message; source authority is
  the framework-stamped `from` (payload-claimed identity stays inert), gated
  by an allowlist that fails closed when empty. Because object messages are
  one-way, the door requires a **caller-minted `order_ref`** — the core now
  accepts one in `register_order` (64 lowercase hex chars, uniqueness-checked
  per `user_ref`; refusals are typed `:bad_order_ref` /
  `:duplicate_order_ref`); omitted refs are server-minted exactly as before.
  The synchronous call door (`execute_with_permit/4` etc.) is unchanged — the
  intake HTTP path keeps its request/response shape. `swarmidx.json` gsp
  manifest added (`kind: handler`, module = the object door).

## [0.1.0] - 2026-07-05

M1 — the permit lane: one EIP-2612 signature per payment, gasless for the
user, over an app-specific non-custodial router.

### Added

- **Contracts (Foundry):** abstract `SpendRouter` base — single
  `transferFrom(user → destination)` token path with exact-delivery check,
  reentrancy lock, per-instance `orderId` idempotency, permit application
  with front-run tolerance, and no owner/pause/upgrade/rescue/execute
  surface. `ISpendRouter` introspection views. `EchoSpendRouter` example
  consumer (test-only) and the inheritable invariant suite
  `SpendRouterTestBase` (conservation, zero residual, credit-recipient
  derivation, destination beneficiary binding via app-supplied oracle,
  idempotency, ABI pin), plus hostile-token, base-guard, and cross-router
  isolation tests.
- **Keeper (Elixir, `objects/spend_keeper/`):** pure-Elixir EVM core (keccak,
  secp256k1/RFC-6979, ABI, RPC, EIP-1559 signing — no NIFs);
  `Keeper.Signer` (own key, pinned chain id, simulation before every
  broadcast, gap-free nonces, action-key idempotency, same-nonce fee-bump
  sweep); `Keeper.PermitLane` calldata composition (`<action>WithPermit`
  with the `[owner, deadline, v, r, s]` tail convention);
  `Keeper.BootCheck` (chain-id + codehash pins before enable);
  `DelegatedSpend.Keeper` — server-authoritative immutable orders, atomic
  single consumption, TTL before broadcast, envelope-sender allowlist,
  optional `expected_owner` binding with fail-closed
  `require_owner_binding`, `min_deadline_slack_s` anti-grief check, typed
  mined receipt results (display-only), boot reconciliation on
  definitive receipts only; `Keeper.Store` behaviour with `MemoryStore`
  reference semantics.
- **Intake (Elixir):** `DelegatedSpend.Intake` pure HTTP handlers
  (`handle_order/2`, `handle_grant/2`) — the app supplies serving and the
  fail-closed bind; Telegram `initData` HMAC verification with freshness
  (`Intake.TelegramAuth`, constant-time compare, never logged); strict
  byte-for-byte grant validation against pinned config
  (`Intake.GrantValidation`, 409 on version mismatch); per-`user_ref`
  fixed-window rate limiting (`Intake.Rate`) touchable only by
  authenticated callers.
- **Mini App (`webapp/`):** zero-dependency permit flow — connect wallet,
  fetch order, on-chain permit nonce read, `eth_signTypedData_v4`, grant
  envelope submit — with every failure a typed state; DOM-free flow module
  tested under `node --test` with a mock EIP-1193 provider.
- **Golden vectors (`vectors/permit/`):** generated by the webapp's actual
  encoding module, signed by Foundry's independent EIP-712 implementation,
  redeemed in Foundry and parsed by the Elixir keeper — a 3-language
  cross-check; CI regenerates and diffs byte-identical.
- **Tooling:** `scripts/attest.sh` deployment attestation (runtime bytecode
  diff modulo immutables + codehash to pin + introspection views);
  `scripts/check-version.sh` co-versioning check; CI (Foundry + ExUnit +
  node + anvil end-to-end + attestation positive/negative probes).
- **Proven end-to-end on Base Sepolia** by the first consumer's router over
  claim-bound escrow deposit views: gasless permit spend mined, funds at the
  vault-derived destination, zero router residual, idempotent retry, and
  orderId replay failing SIMULATION at zero gas.
