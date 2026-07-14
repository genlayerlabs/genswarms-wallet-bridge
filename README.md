# genswarms-wallet-bridge

The chat-to-wallet bridge for GenSwarms products (Base + USDC + Telegram +
deterministic Elixir object brain): wallet-native delegated spending plus
generic wallet-order transport, behind one attested dapp and launcher.
Delegated spend lanes use the app's contract path; wallet-order transport lets
the user's wallet verify and submit app-built payloads directly.

Not a wallet (it never holds user keys or funds) and not a cross-chain bridge
(one chain, one token path) — it is the span between the deterministic object
brain and the user's own wallet. The swarmidx identity is
`genlayerlabs/wallet-bridge` (0.3.3+). Formerly published as
`genswarms-delegated-spend` (through 0.3.0) and
`genswarms-wallet-bridge` (0.3.1–0.3.2).

- **Permit lane (M1):** one EIP-2612 signature per payment — gasless for the user.
- **Delegation lane (M2):** ERC-7710 standing delegation with caveats — one-tap.
- **Wallet-order transport (0.3):** `user_tx` order fetch + wallet submission,
  and `bind` order fetch + connected-wallet POST.

**Generic as a package, never generic as a deployed authority:** every consuming
app deploys its own immutable `SpendRouter` subclass with exactly one typed
money-moving action. No shared deployed contracts.

Adoption contract (design spec §3.2; spec section references — §n — appear
throughout the code and docs): concrete router + funds destination +
intent calls + storage adapter + config/deploys. `contracts/src/examples/EchoSpendRouter.sol`
is the reference consumer; its test suite is the template. The full adoption
guide is `docs/adoption.md`.

## Security invariants (contracts layer — do not weaken)

- The router NEVER holds funds: one token-moving path, a single
  `transferFrom(user → destination)` with an exact-delivery check
  (fee-on-transfer and lying tokens revert cleanly).
- The credit recipient (`user`) is derived structurally — permit signer in the
  `...WithPermit` variant, `msg.sender` in the plain variant — never a
  keeper-controlled parameter.
- The destination is a beneficiary-bound derivation taking that `user` as the
  beneficiary input, AND must be recoverable by that beneficiary (claim-bound
  refund path or equivalent). The base cannot express this in Solidity; the
  binding half is enforced by `SpendRouterTestBase`; the recoverability half
  is the consumer's to prove (e.g. with a vault refund round-trip test in
  its own suite). `EchoSpendRouter` is TEST-ONLY: its hash destinations are
  unrecoverable by design — never deploy it with a real token.
- `_routeSpend` holds a reentrancy lock across the token transfer: a reentrant
  token cannot interleave a nested spend at any destination (with USDC this is
  unreachable; the lock makes the accounting token-independent).
- `orderId` is idempotent per router instance and consumed before any external
  call (a keeper retry or reentrant token can never double-spend). Consumers
  namespace order ids per router instance.
- No owner, pause, upgrade, rescue, or generic execute — pinned by the ABI
  test (exactly the two action selectors, nothing payable, no receive/fallback).
- Permit front-run tolerance checks ALLOWANCE, not the permit deadline: an
  expired permit riding a sufficient standing allowance proceeds (pinned by
  test). Order freshness/TTL is the keeper's server-authoritative job.
- Compromised-keeper worst case: user-authorized amounts, landing at
  user-bound destinations — recoverable, never redirectable (pinned by the
  blast-radius tests).

## Keeper chain layer (Elixir)

`objects/spend_keeper/` — pure Elixir, no NIFs: keccak256, secp256k1
(RFC-6979) and the ABI/RPC plumbing are ports of a production-proven native
Elixir chain client; `Tx1559` adds type-2 signing. `Keeper.Signer` owns the keeper
key and enforces the §10 invariants: pinned chain id at boot, simulation
before EVERY broadcast (a revert costs zero gas), action-key idempotency,
gap-free nonces, same-nonce fee-bump sweep. `Keeper.PermitLane` composes
`<action>WithPermit` calldata from the pinned action config + the
server-authoritative order + the user's permit envelope; `Keeper.BootCheck`
pins chain id + contract codehashes before the keeper enables.
Hermetic: `mix test`. Real-EVM: `mix run test/e2e/anvil_permit_lane.exs`
(forge build + anvil; runs in CI). `scripts/check.sh` runs every layer
(stamps, mix, webapp, vectors, forge, e2e) — the same gates as CI.

## Registry + intake (Elixir)

`DelegatedSpend.Keeper` owns server-authoritative orders (immutable, atomic
single consumption, TTL checked immediately before broadcast) while
`DelegatedSpend.Keeper.Store` owns durable technical status: `:pending`,
`{:submitted, tx}`, `{:mined, tx}`, or `{:failed, reason}`. `:unknown` means no
execution status is retained. `mined` means one successful receipt, not
confirmation depth or product credit. Order registration authority is the
runtime ENVELOPE SENDER checked against an allowlist — payload-claimed
identity is inert.

The keeper is a functional core with two doors. `DelegatedSpend.Keeper.Object`
is the GenSwarms object door (`swarmidx.json` points at it): other swarm
objects register orders by JSON message, the source is the framework-stamped
`from`, and — messages being one-way — the sender mints the `order_ref`
itself (format- and uniqueness-checked by the core; a caller-minted ref is
indistinguishable from a server-minted one). The synchronous call door
(`execute_with_permit/4` etc.) remains for the intake HTTP path, which must
put an answer in an HTTP response; end-user authority there is the platform
auth, not swarm identity.
`DelegatedSpend.Keeper.Store` is the behaviour apps implement
(`MemoryStore` is the reference semantics; production apps ship their own
SQL adapter against it). Execution start and terminal resolution are atomic,
restart-safe store operations; durable polling is the recovery path when a
best-effort callback is lost. `DelegatedSpend.Intake` ships PURE HTTP handlers (the
app supplies serving + fail-closed bind): Telegram `initData` HMAC with
freshness or ref-scoped access tokens, `user_ref` derived only from verified
identity, strict byte-for-byte grant validation against pinned config, dapp
build-version pinning, per-user rate limits that only authenticated callers
can even touch, `handle_wallet/2` for bind orders, and `handle_submitted/2`
for best-effort user-tx reports. `initData`, access tokens, and raw platform
ids are never logged.

## Adopting (contracts layer)

1. Extend `SpendRouter` with ONE typed action + its `...WithPermit` variant
   (`contracts/src/examples/EchoSpendRouter.sol` is the template, ~60 lines).
2. Inherit `SpendRouterTestBase` in your suite and implement the seven hooks
   (`contracts/test/EchoSpendRouterSuite.t.sol` is the template). Your router
   is not adopted until the inherited suite passes — that suite is what
   enforces the beneficiary-binding invariant the base cannot express in
   Solidity.
3. A real consumer's destination must be recoverable by the beneficiary —
   e.g. an escrow vault's claim-bound CREATE2 deposit views with a
   permissionless refund path. `docs/adoption.md` walks all five adoption
   items end-to-end.
