# User Transaction Funds Preflight Design

## Goal

Warn a `user_tx` payer about insufficient token or native gas balance before
opening the wallet transaction sheet, without turning fallible RPC reads into
a hard payment gate.

## Flow

Add a DOM-free `preflightFunds(deps, { order, account })` to
`webapp/lib/flow.mjs`. It uses the connected EIP-1193 provider, parses RPC
quantities as `BigInt`, and converts only safely represented integer order
amounts to `BigInt`.

For orders with a positive safe-integer `amount`, it first calls the configured
ERC-20 token's `balanceOf(account)`. A short balance returns:

```js
{ ok: false, reason: "insufficient_token", balance, needed }
```

It then calls `eth_getBalance` and compares the native balance with a fixed
`10_000_000_000_000n` wei warning floor. A short balance returns:

```js
{ ok: false, reason: "insufficient_gas", balance }
```

Each read fails soft independently: a failed or malformed token read skips the
token warning but still permits the gas read; a failed or malformed gas read
skips the gas warning. Token shortage takes precedence when both balances are
short. Orders with `amount: 0` never issue the token call. Because the current
transport schema encodes amounts as JSON numbers, amounts above
`Number.MAX_SAFE_INTEGER` also skip the token check rather than compare an
inexact value; changing the schema to decimal strings would remove this limit.

`runUserTxFlow` calls the preflight after chain, owner, and terms gates and
before `eth_sendTransaction`. Insufficient-funds results also carry the checked
`account` and `order` for UI re-checks. A per-invocation `skipPreflight` option
supports the explicit escape hatch; it never bypasses fetch, config drift,
kind, wallet, chain, owner, or terms gates.

## UI

Add a hidden funds-warning action group to `webapp/index.html` containing
dedicated **Re-check** and **Sign anyway** buttons. While a funds warning is
active, hide the normal payment button and show both warning actions.

The warning copy uses the existing `formatUnits()` helper, configured token
decimals (six by default), and token name. The gas copy says the wallet has too
little ETH for gas rather than claiming the fixed floor is an exact fee quote.

**Re-check** calls `preflightFunds` for the returned account and order only. If
the wallet is now funded, it clears the warning and restores the normal payment
button without opening the wallet. The subsequent normal payment attempt runs
the full flow and preflight again, so account or balance changes cannot evade
the check.

**Sign anyway** reruns the complete flow with `skipPreflight` for that invocation
only. It remains a deliberate user action and does not persist a bypass.

## Tests and Release

Extend the existing Node test suite with mock-provider coverage for short token
balance, funded balances, short gas balance, independent fail-soft reads,
`amount: 0`, wallet-send suppression, Re-check, and Sign anyway. Existing flow
tests continue to prove the wallet/chain/owner/terms ordering.

Bump all package version stamps and the changelog from `0.9.0` to `0.10.0`.
No keeper, intake, order-schema, server, RPC-config, or dependency changes are
in scope. The preflight applies only to `user_tx` as requested by issue #15.
