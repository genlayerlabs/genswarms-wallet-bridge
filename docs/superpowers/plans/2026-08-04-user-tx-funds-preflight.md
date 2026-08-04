# User Transaction Funds Preflight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Warn underfunded `user_tx` payers before opening the wallet transaction sheet while preserving fail-soft RPC reads and an explicit one-shot bypass.

**Architecture:** `webapp/lib/flow.mjs` owns balance reads and enforces them inside the existing transaction flow. `webapp/app.mjs` only renders typed failures and wires dedicated Re-check and Sign anyway actions; the existing payment path remains the final gate.

**Tech Stack:** Browser JavaScript ES modules, EIP-1193 JSON-RPC, Node's built-in `node:test` and `assert`.

## Global Constraints

- No new dependencies, server endpoints, keeper changes, intake changes, order-schema changes, or RPC configuration.
- Use only the connected EIP-1193 wallet provider.
- Token checks apply only when `order.amount > 0`; `amount: 0` skips `eth_call`.
- Check token balance before native gas balance with a fixed `10_000_000_000_000n` wei warning floor.
- Every failed or malformed balance read fails soft independently.
- Re-check never opens the wallet; Sign anyway bypasses preflight for one invocation only.
- The feature applies only to `user_tx` orders.
- Bump package version stamps and changelog from `0.9.0` to `0.10.0`.

---

### Task 1: DOM-free funds preflight and flow gate

**Files:**
- Modify: `webapp/lib/flow.mjs:576`
- Test: `webapp/tools/flow.test.mjs:1`

**Interfaces:**
- Produces: `preflightFunds(deps, { order, account }) -> Promise<{ok: true} | {ok: false, reason: "insufficient_token", balance: bigint, needed: bigint} | {ok: false, reason: "insufficient_gas", balance: bigint}>`
- Produces: `runUserTxFlow(deps, orderRef, fetched = null, { skipPreflight = false } = {})`
- Produces on shortage: the preflight failure extended with `{ account, order }`

- [ ] **Step 1: Import the wished-for API and add failing provider tests**

Add `preflightFunds` to the import from `../lib/flow.mjs`, then add focused tests covering the read contract:

```js
test("preflightFunds: short token balance wins before the gas read", async () => {
  const order = { amount: 1_000_000 };
  const provider = mockProvider({
    eth_call: () => "0x7a120", // 500_000
    eth_getBalance: () => { throw new Error("token shortage must return first"); },
  });

  assert.deepEqual(
    await preflightFunds({ provider, config: CONFIG }, { order, account: ACCOUNT }),
    { ok: false, reason: "insufficient_token", balance: 500_000n, needed: 1_000_000n },
  );
});

test("preflightFunds: funded token and gas balances proceed", async () => {
  const provider = mockProvider({
    eth_call: () => "0xf4240",
    eth_getBalance: () => "0x9184e72a000",
  });
  assert.deepEqual(
    await preflightFunds({ provider, config: CONFIG }, { order: { amount: 1_000_000 }, account: ACCOUNT }),
    { ok: true },
  );
});

test("preflightFunds: amount zero skips token and still warns on gas", async () => {
  const provider = mockProvider({
    eth_call: () => { throw new Error("must not call token"); },
    eth_getBalance: () => "0x0",
  });
  assert.deepEqual(
    await preflightFunds({ provider, config: CONFIG }, { order: { amount: 0 }, account: ACCOUNT }),
    { ok: false, reason: "insufficient_gas", balance: 0n },
  );
  assert.ok(!provider.calls.some(({ method }) => method === "eth_call"));
});

test("preflightFunds: read failures are independently fail-soft", async () => {
  const tokenError = mockProvider({
    eth_call: () => { throw new Error("offline"); },
    eth_getBalance: () => "0x0",
  });
  assert.deepEqual(
    await preflightFunds({ provider: tokenError, config: CONFIG }, { order: { amount: 1 }, account: ACCOUNT }),
    { ok: false, reason: "insufficient_gas", balance: 0n },
  );

  const gasError = mockProvider({
    eth_call: () => "0x1",
    eth_getBalance: () => { throw new Error("offline"); },
  });
  assert.deepEqual(
    await preflightFunds({ provider: gasError, config: CONFIG }, { order: { amount: 1 }, account: ACCOUNT }),
    { ok: true },
  );
});
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `node --test --test-name-pattern='preflightFunds' webapp/tools/flow.test.mjs`

Expected: FAIL because `preflightFunds` is not exported.

- [ ] **Step 3: Implement the minimum preflight**

Add the selector encoder, strict hex-quantity parser, and independent read guards near `runUserTxFlow`:

```js
const GAS_DUST_WEI = 10_000_000_000_000n;

function rpcQuantity(value) {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]+$/.test(value)) throw new Error("bad quantity");
  return BigInt(value);
}

export async function preflightFunds({ provider, config }, { order, account }) {
  const needed = BigInt(order.amount);
  if (needed > 0n) {
    try {
      const data = "0x70a08231" + account.replace(/^0x/, "").toLowerCase().padStart(64, "0");
      const balance = rpcQuantity(await provider.request({
        method: "eth_call",
        params: [{ to: config.token, data }, "latest"],
      }));
      if (balance < needed) return { ok: false, reason: "insufficient_token", balance, needed };
    } catch (_) {}
  }

  try {
    const balance = rpcQuantity(await provider.request({ method: "eth_getBalance", params: [account, "latest"] }));
    if (balance < GAS_DUST_WEI) return { ok: false, reason: "insufficient_gas", balance };
  } catch (_) {}
  return { ok: true };
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `node --test --test-name-pattern='preflightFunds' webapp/tools/flow.test.mjs`

Expected: all matching tests PASS.

- [ ] **Step 5: Add failing transaction-gate and bypass tests**

```js
test("runUserTxFlow blocks a short token balance before wallet send", async () => {
  const order = { order_ref: "r1", kind: "user_tx", amount: 1_000_000, tx: { to: "0x" + "11".repeat(20), data: "0x", value: 0 } };
  let sends = 0;
  const provider = mockProvider({
    eth_call: () => "0x0",
    eth_sendTransaction: () => { sends += 1; return "0x" + "ef".repeat(32); },
  });
  const fetchFn = mockFetch({ orders: () => ({ status: 200, json: order }) });

  assert.deepEqual(
    await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "" }, "r1"),
    { ok: false, reason: "insufficient_token", balance: 0n, needed: 1_000_000n, account: ACCOUNT, order },
  );
  assert.equal(sends, 0);
});

test("runUserTxFlow skipPreflight bypasses balance reads once", async () => {
  const order = { order_ref: "r1", kind: "user_tx", amount: 1_000_000, tx: { to: "0x" + "11".repeat(20), data: "0x", value: 0 } };
  let sends = 0;
  const provider = mockProvider({
    eth_call: () => { throw new Error("must not read"); },
    eth_getBalance: () => { throw new Error("must not read"); },
    eth_sendTransaction: () => { sends += 1; return "0x" + "ef".repeat(32); },
  });
  const fetchFn = mockFetch({ orders: () => ({ status: 200, json: order }) });

  assert.equal((await runUserTxFlow(
    { provider, fetchFn, config: CONFIG, initData: "" }, "r1", null, { skipPreflight: true },
  )).ok, true);
  assert.equal(sends, 1);
  assert.ok(!provider.calls.some(({ method }) => method === "eth_call" || method === "eth_getBalance"));
});
```

- [ ] **Step 6: Run the gate tests and verify RED**

Run: `node --test --test-name-pattern='runUserTxFlow (blocks|skipPreflight)' webapp/tools/flow.test.mjs`

Expected: shortage test sends a transaction and bypass test still performs preflight.

- [ ] **Step 7: Gate `runUserTxFlow` after terms and before send**

Change the signature and add:

```js
export async function runUserTxFlow(deps, orderRef, fetched = null, { skipPreflight = false } = {}) {
  // existing fetch, config, kind, connect, chain, owner, and terms gates
  if (!skipPreflight) {
    const funds = await preflightFunds(deps, { order: fetched.order, account: conn.account });
    if (!funds.ok) return { ...funds, account: conn.account, order: fetched.order };
  }
  // existing eth_sendTransaction and report
}
```

- [ ] **Step 8: Run the complete flow test file and commit**

Run: `node --test webapp/tools/flow.test.mjs`

Expected: all tests PASS.

```bash
git add webapp/lib/flow.mjs webapp/tools/flow.test.mjs
git commit -m "feat: preflight user transaction funds"
```

---

### Task 2: Dedicated warning actions in the dapp

**Files:**
- Modify: `webapp/index.html:35`
- Modify: `webapp/app.mjs:1,520`
- Test: `webapp/tools/app.test.mjs:1`

**Interfaces:**
- Consumes: `preflightFunds(deps, { order, account })` from Task 1
- Consumes: `runUserTxFlow(..., { skipPreflight: true })` from Task 1
- Produces: exported `setupUserTx(deps, order, orderRef, tg, get = $)` for headless UI tests
- Produces DOM IDs: `funds-actions`, `funds-recheck`, `funds-sign-anyway`

- [ ] **Step 1: Add failing markup and UI-flow tests**

Extend `fakeDom()` with the three new elements, import `setupUserTx`, and add:

```js
test("funds warning actions are present and initially hidden", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /<div id="funds-actions" hidden>/);
  assert.match(html, /<button id="funds-recheck"[^>]*>Re-check<\/button>/);
  assert.match(html, /<button id="funds-sign-anyway"[^>]*>Sign anyway<\/button>/);
});

test("user transaction Re-check clears a token warning without opening the wallet", async () => {
  const { elements, get } = fakeDom();
  const order = { order_ref: "r1", kind: "user_tx", amount: 1_000_000, tx: { to: TREASURY, data: "0x", value: 0 }, display: {} };
  let tokenBalance = "0x7a120";
  let sends = 0;
  const deps = {
    provider: mockAuthProvider({
      eth_call: () => tokenBalance,
      eth_getBalance: () => "0x9184e72a000",
      eth_sendTransaction: () => { sends += 1; return HASH; },
    }),
    config: { intakeUrl: "/spend", version: "0.10.0", chainId: 84_532, token: TREASURY, tokenName: "USDC" },
    fetchFn: async () => ({ status: 200, json: async () => order }),
  };

  await setupUserTx(deps, order, "r1", null, get);
  await elements.pay.onclick();
  assert.equal(elements.pay.hidden, true);
  assert.equal(elements["funds-actions"].hidden, false);
  assert.match(elements.status.textContent, /0\.50 USDC.*1\.00 USDC/);
  assert.equal(sends, 0);

  tokenBalance = "0xf4240";
  await elements["funds-recheck"].onclick();
  assert.equal(elements["funds-actions"].hidden, true);
  assert.equal(elements.pay.hidden, false);
  assert.equal(sends, 0);
});

test("user transaction Sign anyway performs one bypassed send", async () => {
  const { elements, get } = fakeDom();
  const order = { order_ref: "r1", kind: "user_tx", amount: 1_000_000, tx: { to: TREASURY, data: "0x", value: 0 }, display: {} };
  let sends = 0;
  const deps = {
    provider: mockAuthProvider({
      eth_call: () => "0x0",
      eth_getBalance: () => "0x0",
      eth_sendTransaction: () => { sends += 1; return HASH; },
    }),
    config: { intakeUrl: "/spend", version: "0.10.0", chainId: 84_532, token: TREASURY, tokenName: "USDC" },
    fetchFn: async () => ({ status: 200, json: async () => order }),
  };

  await setupUserTx(deps, order, "r1", null, get);
  await elements.pay.onclick();
  await elements["funds-sign-anyway"].onclick();
  assert.equal(sends, 1);
  assert.match(elements.status.textContent, /^Transaction sent/);
});
```

- [ ] **Step 2: Run the focused app tests and verify RED**

Run: `node --test --test-name-pattern='funds warning|user transaction (Re-check|Sign anyway)' webapp/tools/app.test.mjs`

Expected: FAIL because the markup and exported setup function do not exist.

- [ ] **Step 3: Add the dedicated hidden actions**

Place immediately after the normal pay button:

```html
<div id="funds-actions" hidden>
  <button id="funds-recheck" type="button">Re-check</button>
  <button id="funds-sign-anyway" type="button">Sign anyway</button>
</div>
```

- [ ] **Step 4: Wire typed warnings, Re-check, and one-shot bypass**

Import `preflightFunds` and `formatUnits`, give `setupUserTx` a `get = $` seam, and keep the state logic local to that function:

```js
export async function setupUserTx(deps, order, orderRef, tg, get = $) {
  const pay = get("pay");
  const actions = get("funds-actions");
  const recheck = get("funds-recheck");
  const signAnyway = get("funds-sign-anyway");

  const showFundsWarning = (result) => {
    pay.hidden = true;
    actions.hidden = false;
    const decimals = Number.isInteger(deps.config.tokenDecimals) ? deps.config.tokenDecimals : 6;
    const token = deps.config.tokenName || "tokens";
    const message = result.reason === "insufficient_token"
      ? `This wallet holds ${formatUnits(result.balance, decimals)} ${token} — this order needs ${formatUnits(result.needed, decimals)} ${token}. Top it up, then re-check.`
      : "This wallet has too little ETH for gas — the transaction is likely to fail.";
    paintStatus(get("status"), message, "warning");

    recheck.onclick = async () => {
      recheck.disabled = signAnyway.disabled = true;
      paintStatus(get("status"), "Checking balances…");
      const checked = await preflightFunds(deps, { order: result.order, account: result.account });
      recheck.disabled = signAnyway.disabled = false;
      if (!checked.ok) return showFundsWarning({ ...checked, order: result.order, account: result.account });
      actions.hidden = true;
      pay.hidden = false;
      pay.disabled = false;
      paintStatus(get("status"), "Funds available — review and sign when ready.");
    };
    signAnyway.onclick = () => run(undefined, { skipPreflight: true });
  };

  const run = async (fetched, options = {}) => {
    pay.disabled = true;
    actions.hidden = true;
    paintStatus(get("status"), "Opening wallet…");
    const result = await runUserTxFlow(deps, orderRef, fetched, options);
    if (!result.ok && (result.reason === "insufficient_token" || result.reason === "insufficient_gas"))
      return showFundsWarning(result);
    // preserve the existing success, owner, terms, geo, and generic failure branches
  };
  // preserve summary, owner-at-load, initial pay wiring
}
```

Replace `$()` references inside this function with `get()` and pass `get` to `enforceOwnerAtLoad`, `blockWrongWallet`, `showTermsPrompt`, and `enterGeoDeadState`.

- [ ] **Step 5: Run the focused app tests and verify GREEN**

Run: `node --test --test-name-pattern='funds warning|user transaction (Re-check|Sign anyway)' webapp/tools/app.test.mjs`

Expected: all matching tests PASS.

- [ ] **Step 6: Run all webapp tests and commit**

Run: `node --test webapp/tools/`

Expected: all tests PASS with no warnings.

```bash
git add webapp/index.html webapp/app.mjs webapp/tools/app.test.mjs
git commit -m "feat: render user transaction funds warnings"
```

---

### Task 3: Release stamps and full verification

**Files:**
- Modify: `VERSION:1`
- Modify: `vectors/VERSION:1`
- Regenerate: `vectors/permit/*.json`
- Regenerate: `vectors/terms/*.json`
- Modify: `mix.exs:9`
- Modify: `webapp/config.json:2`
- Modify: `CHANGELOG.md:9`

**Interfaces:**
- Consumes: completed preflight and UI behavior from Tasks 1-2
- Produces: internally consistent package release `0.10.0`

- [ ] **Step 1: Add the changelog release entry and update all stamps**

Insert before `0.9.0`:

```markdown
## [0.10.0] - 2026-08-04

### Added

- The `user_tx` wallet flow now checks token and native gas balances before
  opening the transaction sheet, shows typed shortfall warnings with Re-check
  and Sign anyway actions, and fails soft when wallet RPC reads are unavailable.
```

Change the package version in `VERSION`, `vectors/VERSION`, `mix.exs`, and
`webapp/config.json` from `0.9.0` to `0.10.0`. Leave `CONTRACT_VERSION` unchanged.

Run `node webapp/tools/gen-vectors.mjs` so every committed permit and terms
vector embeds `0.10.0`, then stage `vectors/` before the full check because its
reproducibility gate compares regenerated files with the Git index.

- [ ] **Step 2: Verify all version stamps**

Run: `./scripts/check-version.sh`

Expected: exit 0 with package stamps at `0.10.0` and the unchanged contract pin accepted.

- [ ] **Step 3: Run the complete repository verification**

Run: `./scripts/check.sh`

Expected: version checks, Mix tests, Node tests, vector diff, Forge tests, and Anvil E2E all PASS; final line is `All layers green.`

- [ ] **Step 4: Inspect the final diff and commit**

Run: `git diff --check && git diff --stat HEAD`

Expected: no whitespace errors; only the planned flow, UI, tests, release stamps, changelog, spec, and plan are present.

```bash
git add -f docs/superpowers/plans/2026-08-04-user-tx-funds-preflight.md
git add VERSION vectors/ mix.exs webapp/config.json CHANGELOG.md
git commit -m "release: 0.10.0"
```
