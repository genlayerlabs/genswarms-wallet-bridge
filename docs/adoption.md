# Adopting genswarms-wallet-bridge

This guide walks the **five-item adoption contract** (design spec §3.2): what
a consuming app supplies to run the permit lane on its own authority. The
worked example throughout is the package's own reference consumer —
`contracts/src/examples/EchoSpendRouter.sol` and its suite
`contracts/test/EchoSpendRouterSuite.t.sol`. Where Echo deliberately stops
short (recoverability, persistence), the guide describes what a real
consumer's version looks like.

The posture to internalize first: **generic as a package, never generic as a
deployed authority.** Every app deploys its OWN immutable router subclass with
exactly one typed money-moving action. Nothing deployed is shared between
apps; a grant to one router instance is unusable via another (pinned by the
cross-router isolation test).

The five items:

1. A concrete router extending `SpendRouter`
2. The funds destination
3. Intent calls + typed result handling
4. A storage adapter (the `Keeper.Store` behaviour)
5. Config + deploys

## 0.3 wallet-order transport

Version 0.3 adds two transport order kinds beside the permit lane:

- `permit` remains delegated spend: the keeper broadcasts, intake validation is
  load-bearing, and your router/test invariants define the money-moving
  authority.
- `user_tx` and `bind` are wallet-order transport: the server routes a
  server-built payload, but the user's wallet is the verifier. The keeper never
  broadcasts these kinds; `execute_with_permit/4` refuses them with
  `{:failed, :wrong_kind}` without consuming the order.

If you only need wallet-order transport, start the keeper registry-only:

```elixir
{:ok, keeper} =
  DelegatedSpend.Keeper.start_link(%{
    store: {YourStore, ref},
    source_allowlist: ["your-app"],
    order_ttl_s: 900
  })
```

No `:signer`, `:router`, or `:action` is required. A permit order can still be
registered, but execution returns `{:failed, :permit_lane_disabled}` until you
configure the permit lane.

The intake supports the existing Telegram `initData` path and a ref-scoped
token path. Mint tokens app-side when creating button URLs:

```elixir
token = DelegatedSpend.Intake.Token.mint(secret, order_ref, user_ref, expires_at)
```

Order-token TTL should match the order TTL; bind tokens should be short-lived
(15 minutes or less). Tokens bind `{ref, user_ref, expires_at}` and open one
order or bind ref only. They are not account credentials.

New or changed intake endpoints:

| Handler | Request | Purpose |
|---|---|---|
| `handle_order/2` | `{v, token \| init_data, order_ref}` | Fetch kind-aware order views; `user_tx` includes `tx`, `bind` includes `current_wallet`; owner-bound orders include `expected_owner`; EVERY view carries the keeper's runtime `chain_id` (the dapp fails closed on config drift). |
| `handle_wallet/2` | `{v, token \| init_data, bind_ref, address}` | Consume one bind order and call `ctx.wallet_fn.(user_ref, address, bind_ref)`. |
| `handle_submitted/2` | `{v, token \| init_data, order_ref, tx_hash}` | Best-effort user-tx report through `ctx.submitted_fn.(order_id, tx_hash)`. It has zero crediting authority. |

Optional ctx keys:

- `:token_secret` enables token auth.
- `:wallet_fn` is consumer-owned, request-critical bind persistence. A failure
  rejects the request after consuming the single-use bind order.
- `:wallet_view_fn` is the consumer-owned wallet lookup for bind views.
- `:submitted_fn` receives an untrusted, best-effort transaction hint. It can
  be lost and has no crediting authority.

Hard rule for adopters: `user_ref` is one-way. If your app must act on a bind
or order result, key your own state by `bind_ref` or `order_ref` at mint time.
The callbacks return those refs; they will never get a platform id back out of
`user_ref`.

---

## 1. The concrete router

Extend the abstract `SpendRouter` with **one** typed external action plus its
`...WithPermit` variant. That's the whole contract — Echo is ~60 lines:

```solidity
contract EchoSpendRouter is SpendRouter {
    constructor(address token_, address anchor_, address delegationManager_)
        SpendRouter(token_, anchor_, delegationManager_) {}

    function routerType() external pure override returns (bytes32) {
        return keccak256("ECHO_SPEND_ROUTER");
    }

    // Beneficiary-binding derivation: the destination COMMITS to the user.
    function destinationFor(bytes32 topic, address beneficiary) public view returns (address) {
        return address(uint160(uint256(
            keccak256(abi.encode(address(this), anchor, topic, beneficiary)))));
    }

    // Delegation-lane shape (M2): user is msg.sender.
    function pay(bytes32 topic, uint256 amount, bytes32 orderId) external {
        _pay(msg.sender, topic, amount, orderId);
    }

    // Permit lane (M1): keeper submits, user = permit signer.
    function payWithPermit(bytes32 topic, uint256 amount, bytes32 orderId,
        address owner, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        _applyPermit(owner, amount, deadline, v, r, s);
        _pay(owner, topic, amount, orderId);
    }

    function _pay(address user, bytes32 topic, uint256 amount, bytes32 orderId) internal {
        address destination = destinationFor(topic, user);
        _routeSpend(user, destination, amount, orderId);
        emit EchoPaid(topic, user, destination, amount, orderId);
    }
}
```

What the base gives you (never re-implement):

- `_routeSpend(user, destination, amount, orderId)` — the ONLY token-moving
  path: one `transferFrom(user → destination)` with an exact-delivery check,
  a reentrancy lock, and `orderId` consumed before the external call.
- `_applyPermit(owner, value, deadline, v, r, s)` — EIP-2612 application with
  front-run tolerance (if `permit` reverts but the standing allowance already
  covers `value`, proceed; otherwise `PermitRejected`).
- Constructor immutables `token`, `anchor`, `delegationManager` (pass
  `address(0)` for a permit-only M1 deploy — the router never *calls* the
  DelegationManager, it's introspection only), plus the `version()` /
  `routerType()` / `orderConsumed(orderId)` views.

What you must get right:

- **Credit-recipient derivation is structural.** The `user` handed to
  `_routeSpend` is the permit signer in the `...WithPermit` variant and
  `msg.sender` in the plain variant — never a parameter the keeper chooses.
  Echo's `payWithPermit` passes `owner` (whose signature `_applyPermit` just
  checked); a submitted-but-unsigned "user" parameter is the classic mistake
  the invariant suite catches.
- **The destination derivation takes that `user` as the beneficiary input.**
  Echo's `destinationFor(topic, beneficiary)` commits to the beneficiary in
  the hash — a corrupt `topic` still lands funds at an address bound to the
  user, never redirectable to a third party. The real version of this shape
  derives the destination from an escrow vault's claim-bound deposit view
  with `claimTo = user`.
- **The `...WithPermit` tail is a convention:** the last five arguments are
  `owner, deadline, v, r, s` in that order — that is what
  `DelegatedSpend.Keeper.PermitLane.build_call/3` appends after your action
  args (see item 3).
- **One action.** The ABI-pin test enforces exactly your declared
  state-changing selectors, nothing payable, no receive/fallback, and none of
  the forever-absent surfaces (owner/pause/upgrade/rescue/execute).

⚠ Echo itself is **TEST-ONLY** — its hash destinations have no code, no key,
and no refund path. Never deploy it with a real token.

## 2. The funds destination

Two accepted shapes (spec §3.2 item 2):

- **Claim-bound view derivation**: the destination is read from a contract
  view that commits to the beneficiary *before* funding — e.g. an escrow
  vault's CREATE2 deposit address with `claimTo = user`, so funds landing
  there are recoverable by the user through the vault's permissionless
  claim-bound refund, keeper or no keeper.
- **Typed credit interface**: a vault/credit call whose recipient argument IS
  the derived `user`.

Both halves of the destination rule matter:

1. **Binding** — the derivation takes the structurally derived `user` as the
   beneficiary input. The base cannot express this in Solidity; it is
   enforced by `SpendRouterTestBase` via your destination oracle (item on
   testing below).
2. **Recoverability** — the beneficiary must be able to get funds back out.
   The suite cannot check this generically; it is yours to prove — pin it
   with a funded round-trip through your real refund path in your own
   suite. Echo deliberately fails this half — that is why it is test-only.

## 3. Intent calls + typed result handling

Your product code talks to `DelegatedSpend.Keeper` (a GenServer the app
starts — see item 5 for options). `Keeper.start_link` REQUIRES `:chain_id` —
pass the RUNTIME chain id your app derived from its RPC at boot, never a
config constant: it is stamped on every order view so the wallet dapp can
refuse to run against a stale `config.json` (config drift):

```elixir
# Register a server-authoritative order. `source` is the TRUSTED runtime
# envelope sender, checked against the keeper's :source_allowlist —
# anything source-shaped inside the payload is inert data.
{:ok, %{order_id: _, order_ref: ref, expires_at: _, amount: _}} =
  Keeper.register_order(keeper, source, %{
    user_ref: user_ref,          # app-derived opaque ref, never a raw platform id
    amount: amount,              # token units; the permit must cover EXACTLY this
    action_args: [...],          # your action's args, in ABI order (order_id inside them
                                 #   is your on-chain idempotency key)
    expected_owner: claim_wallet # optional wallet binding (see below)
  })

# The wallet dapp drives these two through the intake (item 5), but they are
# plain keeper calls:
{:ok, view} = Keeper.fetch_order(keeper, order_ref, user_ref)
result      = Keeper.execute_with_permit(keeper, order_ref, user_ref, permit)
# result: :pending | {:submitted, tx_hash} | {:mined, tx_hash}
#       | {:failed, :not_found | :expired | :no_grant | :reverted | :rpc_timeout}
#       | :unknown

Keeper.order_status(keeper, order_id)   # durable source of technical truth
Keeper.reconcile_boot(keeper)           # persist receipts found after restart
```

`result_fn` receives `{order_id, result}` after each newly persisted terminal
transition. It is a best-effort technical-status notification: raises, exits,
and throws are logged, never retried, and never crash the Keeper. It can be
lost, so poll `order_status/2` for recovery. **`{:mined, tx}` means one
successful receipt, nothing more** — never use it as product-credit authority;
apply your own confirmation-depth policy and business crediting separately.

**Swarm-object registration (the message door).** If your intent producer is
itself a GenSwarms object, wire the keeper into the swarm instead of calling
it directly — `DelegatedSpend.Keeper.Object` implements the `ObjectHandler`
contract over the same core:

```elixir
objects: [
  %{name: :spend_keeper,
    handler: DelegatedSpend.Keeper.Object,
    config: %{keeper_opts: %{...the Keeper.start_link opts above...}}}
]
```

Your object registers by returning
`{:send, :spend_keeper, Jason.encode!(%{action: "register_order", order: ...}), state}`
— the keeper checks the framework-stamped sender, not anything in the
payload. Messages are one-way, so **you mint the `order_ref` yourself**
(`Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)`) and put it in
the order; the core enforces format and per-user uniqueness. Binary action
args travel as `0x`-hex strings. The keeper acks with a routed reply you may
ignore. The intake HTTP path is unaffected either way — it stays a
synchronous call into the core.

The keeper builds calldata solely from the **stored** order via
`PermitLane.build_call(action, action_args, permit)` using your pinned action
config:

```elixir
# Echo's would be:
action: %{with_permit_name: "payWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]}

# a real consumer's looks the same, just with its own action's signature:
action: %{with_permit_name: "openPositionWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 8}, {:uint, 256}, {:uint, 256}, {:bytes, 32}]}
```

(`arg_types` cover YOUR args only; the `[owner, deadline, v, r, s]` permit
tail is appended by the lane.)

If your credit machinery scans addresses derived from a wallet-on-file, set
`expected_owner` on every order AND start the keeper with
`require_owner_binding: true` — then a permit signed by any other wallet
typed-fails, and an order that *loses* its binding (e.g. a storage bug) fails
CLOSED instead of executing. Set both; the external audit's one critical
finding (F1) was exactly a SQL adapter dropping this field. The dapp enforces
the same binding in the browser: an owner-bound order view carries
`expected_owner`, and a mismatched connected wallet is refused (typed
`wrong_wallet`, pay button hidden) before anything is signed — which is the
ONLY pre-payment check for `user_tx` orders, since the user signs those
directly and the keeper never sees a permit to compare.

Shape your product seam so every failure is `{:error, _}` and the caller
renders its UI exactly as before — the app's ordinary payment path is the
permanent fallback for every typed failure.

## 4. The storage adapter

Implement the `DelegatedSpend.Keeper.Store` behaviour
(`objects/spend_keeper/store.ex`). The callbacks (all take your opaque
`ref` term first — the keeper is started with `store: {YourModule, ref}`):

| Callback | Purpose |
|---|---|
| `put_grant/4`, `get_grant/3`, `grants_for/2`, `revoke_grant/3` | grant registry (stored in M1, redeemed in M2) |
| `record_spend/4`, `spent_since/3` | per-`user_ref` spend accounting |
| `put_order/2`, `get_order/2`, `get_order_by_ref/3` | server-authoritative orders |
| `consume_order/3` | atomic single consumption for non-execution flows such as wallet binding |
| `begin_execution/4` | atomically consume one permit order and create durable `:pending` status |
| `get_execution_status/2` | return `:unknown`, `:pending`, `{:submitted, tx}`, `{:mined, tx}`, or `{:failed, reason}` |
| `update_inflight_hash/3`, `list_inflight/1` | append each same-nonce candidate hash before broadcast and enumerate only unresolved executions |
| `resolve_inflight/4` | atomically persist the first terminal result, remove in-flight state, and record mined spend once; return `:new` or `:existing` |

Semantics every implementation MUST reproduce
(`DelegatedSpend.Keeper.MemoryStore` in the same file is the reference; the
package's tests are the executable contract):

- Orders are **immutable** after `put_order`. `consume_order/3` and
  `begin_execution/4` each consume atomically exactly once; concurrent
  `begin_execution/4` callers yield one `{:ok, order}` and all others
  `:already_consumed`.
- User-facing grant/order reads are scoped by `user_ref` — a wrong `user_ref`
  is indistinguishable from not-found. Internal reconciliation reads such as
  `get_order/2` and `get_execution_status/2` use the server-minted `order_id`.
- Grants are keyed by app-supplied opaque `user_ref` — never raw platform
  ids; never log grant bodies.
- `resolve_inflight/4` is first-terminal-result-wins. Repeated or conflicting
  resolutions return `:existing`, preserve the original terminal result, and
  never duplicate mined spend accounting.
- `update_inflight_hash/3` is append-only and idempotent. It returns
  `:not_found` unless the unresolved row exists; the Signer must not broadcast
  when that durable write fails.
- Keep terminal status for as long as the corresponding order is queryable.
  `list_inflight/1` returns unresolved rows with `tx_hashes` newest-first; an
  empty list means `:pending`, while the newest hash is the public
  `{:submitted, hash}` status. Reconciliation must check every hash because
  any same-nonce candidate may mine.
- Preserve existing unresolved rows during migration. Legacy terminal results
  whose rows were already deleted cannot be reconstructed and remain
  `:unknown`.
- A crash after `begin_execution/4` but before a hash is known leaves an honest
  durable `:pending` status. Never automatically resubmit it.
- This package adds no signed-raw-transaction journal, callback
  acknowledgements, topology-aware callback delivery, automatic swarm
  callback router, separate store object, or product persistence. Micromarkets
  is not changed here; its adapter needs a coordinated schema/API migration
  before upgrading to 0.4.0.
- Round-trip **every** order field — including `kind`, `tx`, `display`,
  `expected_owner`, and `expires_at`. Dropping `expected_owner` silently is
  the audit's F1; pair your adapter with `require_owner_binding: true` so that
  failure mode is CLOSED.

Money-lane bookkeeping should not be in-memory-only in production —
`MemoryStore` is reference semantics, not a production store.

## 5. Config + deploys

- **Router deploy + attestation.** Deploy your concrete router with its
  immutables (`token`, your `anchor`, `delegationManager` — `address(0)` for
  M1), then run:

  ```bash
  scripts/attest.sh <rpc-url> <deployed-address> YourRouter.sol YourRouter
  ```

  It diffs the deployed runtime bytecode against your local build modulo
  immutables, prints the **runtime codehash** (pin it in your boot
  verification env, e.g. `SPEND_ROUTER_CODEHASH`), and echoes the
  introspection views. Feed the pins to
  `DelegatedSpend.Keeper.BootCheck.verify(rpc_mod, rpc, %{chain_id: id,
  codehashes: %{addr => hash}})` before enabling the keeper — wrong network
  or wrong contract fails closed.

- **Wallet dapp build on your domain.** `webapp/` is a static, zero-dependency
  build parameterized by `webapp/config.json`:
  `version, chainId, token, tokenName, tokenVersion, router, intakeUrl,
  actionLabel, dappLinkPrefix`. Serve it over HTTPS on the app's domain and
  attach `go.html?order=<order_ref>&token=<token>` (or `go.html?bind=<bind_ref>&token=<token>`)
  as the bot button. `go.html` routes mobile users into the configured wallet
  dapp browser and desktop users straight to `index.html`, preserving query
  params. The `version` stamp must match the package tag — the intake 409s a
  stale build at runtime. The `chainId` stamp must match the keeper's runtime
  chain: every order view carries the keeper's `chain_id`, and the dapp goes
  to a dead state (nothing connected, nothing signed) when the deployed
  `config.json` disagrees — moving `RPC_URL` to another chain without
  redeploying the dapp is a fund-loss class misdeploy, not a UX nit.

- **Intake mounted.** The package ships five PURE handlers —
  `DelegatedSpend.Intake.handle_order/2`, `handle_grant/2`,
  `handle_wallet/2`, `handle_submitted/2`, and `handle_terms/2`, each
  `params → {status, body_map}` — and YOU supply the HTTP serving and the
  fail-closed bind (loopback unless explicitly published). The ctx:

  ```elixir
  %{bot_token: bot_token,          # Telegram initData HMAC key
    max_age_s: 900,                # initData freshness window
    user_ref_fn: fn user_id -> ... end,  # verified Telegram id -> opaque user_ref
    token_secret: token_secret,    # optional ref-scoped URL-token secret
    keeper: keeper_pid,
    wallet_fn: fn user_ref, address, bind_ref -> ... end,        # optional bind
    wallet_view_fn: fn user_ref -> current_wallet_or_nil end,    # optional bind view
    submitted_fn: fn order_id, tx_hash -> ... end,               # optional watcher nudge
    pinned: %{chain_id: id, token: token, router: router, version: version},
    rate: {DelegatedSpend.Intake.Rate.start(60), 30}}   # optional
  ```

  The wallet dapp POSTs `{intakeUrl}/orders`, `{intakeUrl}/grants`,
  `{intakeUrl}/wallet`, `{intakeUrl}/orders/submitted`, and, when compliance
  is enabled, `{intakeUrl}/terms`, with either `token` or `init_data` plus `v`
  in the body. A ~60-line Plug over Bandit is all the serving glue takes:
  route first, cap the body (64 kB → 413), decode-error → 400 — auth still
  happens inside the handlers.

- **Keeper key provisioned.** The keeper signs with its OWN key
  (`SPEND_KEEPER_PRIVATE_KEY` in the template) — **never** the app's
  bot/treasury key; the compromise blast radii must stay separate. Fund it
  for gas only. See `.env.example` for the full environment template,
  including which values are required vs optional.

## 6. Compliance layer

The consuming app supplies trusted request metadata to every three-arity
handler. A compact Plug mapping looks like this (the surrounding Plug still
owns body limits, JSON decoding, and response encoding):

```elixir
def call(conn, ctx) do
  conn = Plug.Conn.fetch_cookies(conn)

  meta =
    DelegatedSpend.Compliance.Meta.build(
      conn.remote_ip,
      conn.req_headers,
      conn.req_cookies,
      # EXACTLY the number of reverse proxies you operate in front of this
      # listener (CDN + Caddy/nginx hops). 0 = the socket peer IS the client.
      trusted_hops: 1,
      # The header your TRUSTED EDGE sets with the visitor country.
      country_header: "cf-ipcountry"
    )

  {status, body} = case {conn.method, conn.path_info} do
    {"POST", ["spend", "orders"]} -> Intake.handle_order(conn.params, meta, ctx)
    {"POST", ["spend", "grants"]} -> Intake.handle_grant(conn.params, meta, ctx)
    {"POST", ["spend", "wallet"]} -> Intake.handle_wallet(conn.params, meta, ctx)
    {"POST", ["spend", "orders", "submitted"]} -> Intake.handle_submitted(conn.params, meta, ctx)
    {"POST", ["spend", "terms"]} -> Intake.handle_terms(conn.params, meta, ctx)
  end

  conn |> Plug.Conn.put_status(status) |> json(body)
end
```

The country never comes from the client. Behind Cloudflare, `cf-ipcountry`
is set by the edge. Behind your own Caddy or nginx you must (a) resolve the
country at the edge with a GeoIP module (nginx `ngx_http_geoip2_module`, a
Caddy MaxMind plugin) into a header of your choosing, and (b) strip or
overwrite that header on every inbound request so a client can never supply
it. `trusted_hops` must equal the exact number of proxies you operate: too
low records your own proxy as every user's IP (worthless evidence), too high
lets clients spoof `x-forwarded-for` entries. `Meta.build/4` refuses to
guess — a forwarding chain shorter than the hop count records `ip: nil`.
The package intentionally has no browser-geolocation, blocklist, GeoIP
database, or network-lookup mode.

> **Compliance warning:** once `ctx.compliance` is configured, calling a
> two-arity handler supplies no metadata and therefore denies every request
> (each such call logs a warning naming the mistake); an empty geo allowlist
> also denies everyone. Use all five three-arity forms, and call
> `DelegatedSpend.Compliance.check!(ctx)` at boot so a config that would
> deny-all fails the deploy instead of serving 451/503 to everyone.
> `record_acceptance` is fail-closed: a failure returns `503`, and acceptance
> is not acknowledged.

### Session/cookie evidence

The app owns the first-party `spend_session` cookie and should mint it with
`HttpOnly; Secure; SameSite=Lax; Path=/`. The package only normalizes and
persists the opaque value passed as `meta.session_id`. This relies on the
existing same-origin intake assumption (`intakeUrl: "/spend"`), under which
browser fetches already carry first-party cookies.

`session_id: nil` is accepted because Telegram webviews, ITP, privacy settings,
or disabled cookies may drop the cookie. Legal must sign off on nullable
session evidence. Adapters must never store or log raw `initData`, access
tokens, authentication bodies, or Telegram/other platform identifiers.

### Compliance context

Read and hash the deployed terms file at boot, then serve those exact bytes at
the configured URL:

```elixir
terms_bytes = File.read!(System.fetch_env!("SPEND_TERMS_PATH"))

compliance = %{
  geo_allow: System.fetch_env!("SPEND_GEOFENCE_COUNTRIES") |> String.split(",", trim: true),
  terms: %{
    hash: DelegatedSpend.Compliance.Terms.hash_terms(terms_bytes),
    url: System.fetch_env!("SPEND_TERMS_URL")
  },
  store: {MyApp.ComplianceStore, MyApp.Repo}
}

ctx = Map.put(ctx, :compliance, compliance)
:ok = DelegatedSpend.Compliance.check!(ctx)
```

`check!/1` is the `BootCheck` idiom for this config: it validates the
allowlist, the terms pin, and the store adapter's callbacks at boot, so a
misconfiguration fails the deploy instead of denying every request.

A hand-copied terms hash is not configuration: hash the bytes read from
`SPEND_TERMS_PATH`, and make the terms route return those same bytes. Countries
are comma-separated ISO 3166-1 alpha-2 codes; use an allowlist, not a
blocklist.

Implement the four `DelegatedSpend.Compliance.Store` callbacks:
`record_acceptance/2`, `get_acceptance/3`, `record_event/2`, and
`events_for/2`. The executable adapter specification is
`test/compliance_store_test.exs`. The app's `tg_ci` is the blinded, opaque
`user_ref`; it is never a raw Telegram or other platform identifier.

Production adapters must make `record_acceptance/2` atomic first-write-wins
per `{user_ref, v_hash}` without overwriting the original evidence, and must
make `record_event/2` append-only.

`record_event` is best-effort because it runs after an already-executed money
operation. Persist the audit kinds `wallet_bound`, `grant_submitted`, and
`tx_submitted`. This differs deliberately from request-critical acceptance
persistence; legal must sign off on that durability asymmetry.

### Terms route and UI states

Mount `POST /spend/terms` on `handle_terms/3`. Its body is the signed
acceptance envelope plus the active authentication material:

```json
{
  "v": "0.5.0",
  "token": "<ref-scoped token, or send init_data instead>",
  "ref": "<user-approved active order or bind ref>",
  "acceptance": {
    "v": "0.5.0",
    "chain_id": 84532,
    "v_hash": "0x...",
    "account": "0x...",
    "issued_at": 1900000000,
    "sig": {"v": 27, "r": "0x...", "s": "0x..."}
  }
}
```

The user-approved top-level `ref` is used only to authenticate the existing
ref-scoped token. It is not signed and is not persisted. Keep the UI's three
dead states explicit: `geo_blocked` (`451`, terminal), `terms_required`
(`428`, prompt acceptance), and `terms_stale` (`409`, reload the current hash
and require a new signature).

Retention periods, legal export/deletion workflows, and GDPR policy remain the
consuming app's responsibility.

### Launch checklist

- The trusted edge overwrites the geo header and the origin cannot be reached
  through a path that preserves a client-supplied value.
- The app serves the exact terms bytes hashed at boot; the production store
  passes `test/compliance_store_test.exs` semantics.
- Legal approved nullable session evidence, audit-event durability, retention,
  export/deletion, and GDPR policy.
- **Fail-closed launch warning:** exercise every route through its three-arity
  handler with a non-empty country allowlist. Two-arity handlers and an empty
  `SPEND_GEOFENCE_COUNTRIES` deny all users once compliance is configured.

## The testing bar

**Your router is not adopted until the inherited invariant suite passes.**
Make your Foundry test contract inherit
`contracts/test/SpendRouterTestBase.sol` and implement its seven hooks —
`EchoSpendRouterSuite.t.sol` is the literal template:

| Hook | You supply |
|---|---|
| `_deployRouter(address token_)` | deploy your router against the suite's mock token |
| `_router()` | return it as `SpendRouter` |
| `_executeAs(asUser, amount, orderId)` | run your plain action pranked as `asUser`, canned args |
| `_executeWithPermit(submitter, ownerPk_, amount, orderId, deadline, v, r, s)` | run your `...WithPermit` variant pranked as `submitter` |
| `_expectedDestination(user_)` | the **destination oracle**: expected funds destination for canned args + user |
| `_allowedMutators()` | the exact state-changing function names (your two selectors) |
| `_artifactPath()` | e.g. `"out/YourRouter.sol/YourRouter.json"` for the ABI pin |

The suite then enforces for free: conservation + zero router residual (both
lanes, fuzzed), credit-recipient-is-signer-not-submitter, `orderId`
idempotency, zero-arg floors, permit front-run tolerance / expired-permit /
allowance-boundary / over-signed-value semantics, and the single-action
no-admin ABI pin. The destination oracle is how the beneficiary-binding
invariant — inexpressible in the Solidity base — gets enforced against YOUR
derivation. Beyond the suite: prove recoverability yourself (item 2), and
add app-side keeper/store/intake tests on the package's seams (typical set:
real-database consumption races, fail-closed UI pins, a golden vector for
your `user_ref` derivation).

## Invariants the adopter must not weaken

The authoritative list is the package `README.md` security section (and spec
§10); the ones adoption work most often bumps into:

- One typed action per router; no owner/pause/upgrade/rescue/execute — ever.
- Credit recipient structurally derived; destination beneficiary-bound AND
  recoverable by the beneficiary.
- `orderId` idempotent per router instance — namespace your order ids per
  instance (the package keeper mints 32 random bytes per order).
- Orders are server-authoritative and immutable; only the envelope sender
  (allowlist) can register them; the permit must cover exactly the order
  amount; TTL is the keeper's job, not the permit deadline's.
- Simulation before EVERY broadcast; a failing simulation spends zero gas.
- Keeper key ≠ bot key. `initData` never logged; raw platform ids never
  persisted (opaque `user_ref` only). Intake fail-closed: loopback bind by
  default, 401 before any work, strict byte-for-byte grant validation
  against pinned config.
- Treat `{:mined, _}` as one successful receipt, never product-credit authority.
