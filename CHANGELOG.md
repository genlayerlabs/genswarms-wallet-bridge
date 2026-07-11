# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The package version is stamped in `VERSION`, `vectors/VERSION`, `mix.exs`, and
`webapp/config.json`; `CONTRACT_VERSION` pins `SpendRouter.version()` because
package releases can ship zero contract bytecode changes. `scripts/check-version.sh`
(run in CI) fails on divergence.

## [Unreleased]

### Planned

- **M2 — delegation lane (ERC-7710):** standing delegation with caveats,
  redeemed through the user's account — one-tap payments over the same
  router path. The base contract already carries the `delegationManager`
  introspection view and the keeper's grant registry stores delegation
  grants, but no redemption path exists yet.

## [0.3.1] - 2026-07-10

Webapp theming seam: the static dapp becomes reskinnable by overlaying one
CSS file and one config field — markup, element ids, user-facing copy, and
scripts stay fixed. No contract changes (`CONTRACT_VERSION` stays `0.2.0`).

### Added

- `webapp/theme.css`: the theming seam — both pages link it after their
  inline base styles, and deployments overlay this ONE file to reskin
  (an overlay replaces the file, it does not cascade after it, so a theme
  must be self-contained). The shipped default is contract-only: it
  declares the `:root` custom-property contract (`--bg`, `--fg`,
  `--muted`, `--accent`, `--accent-fg`, `--danger`, `--border`,
  `--font-display`, `--font-body`) and no element rules, so the package
  alone keeps the stock light, system-font look pixel-for-pixel.
- Outcome state stamps for themes: terminal outcomes set
  `data-state="error"` / `data-state="success"` on `#status` (cleared
  while progress text shows), and `#summary` carries `data-state="error"`
  when the order fails to load (expired / not found / stale build /
  unauthorized). The default theme leaves every state unstyled; user-facing
  copy is unchanged.
- Optional `config.productName`: when present it renders into `<title>` and
  `<h1>` on both pages (`webapp/lib/brand.mjs`); absent, the built-in
  "Fast payments" / "Opening your wallet..." strings stay.
- Neutral `webapp/favicon.svg` plus `<link rel="icon">` on both pages.
- Owner-bound order enforcement in the dapp: the intake order view now
  exposes `expected_owner` (only when the order carries one — it is the
  wallet the user must pay from, not a secret), and both the permit and
  `user_tx` paths refuse a mismatched connected wallet with a typed
  `wrong_wallet` failure — `#pay` hides and `#status` stamps
  `data-state="error"` with switch-wallet copy, checked at load, on
  `accountsChanged`, and (load-bearing) again inside each pay path.
  Previously only the keeper's server-side permit check compared owners; the
  browser-signed `user_tx` lane never did, so a wallet other than the bound
  one could pay an order whose payouts go to the bound wallet.

### Changed

- CSP on both pages: `style-src` gains `'self'` (for `theme.css`) and
  `font-src 'self'` is added (themes may self-host fonts); `go.html`
  additionally gains `img-src 'self' data:` (matching `index.html`) so the
  favicon and any theme-injected imagery render on the hop page instead of
  logging CSP violations. Still fully static, zero external hosts.
- The `#pay` button is hidden in states it can never serve: no injected
  wallet provider, and a failed order load. Element ids and copy stay
  fixed.
- Package version stamps move to `0.3.1`; permit golden vectors regenerated
  for the version stamp only (signatures unchanged).

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
  results (`{:credited, tx}` = mined, display-only), boot reconciliation on
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
