// node --test suite for the wallet dapp flow logic with a mock EIP-1193
// provider + mock fetch (spec §8 "mock EIP-1193 provider flows automated").
// Run: node --test webapp/tools/

import test from "node:test";
import assert from "node:assert/strict";
import { acceptTerms, configDrift, fetchOrder, ownerMismatch, runBindFlow, runPermitFlow, runUserTxFlow, shortAddress, termsRequired, walletDappLink, wrongWalletMessage } from "../lib/flow.mjs";
import { buildGrantEnvelope } from "../lib/permit.mjs";
import { buildTermsEnvelope, buildTermsTypedData } from "../lib/terms.mjs";

const CONFIG = {
  version: "0.1.0",
  chainId: 84532,
  token: "0x000000000000000000000000000000000000aaaa",
  tokenName: "Mock USD Coin",
  tokenVersion: "2",
  router: "0x000000000000000000000000000000000000bbbb",
  intakeUrl: "https://app.example/spend",
  actionLabel: "Open position",
};

const ACCOUNT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const SIG = "0x" + "11".repeat(32) + "22".repeat(32) + "1b";
const ORDER = { order_ref: "oref-1", kind: "permit", amount: 25_000_000, expires_at: 1_900_000_000, display: {} };

function mockProvider(overrides = {}) {
  const calls = [];
  return {
    calls,
    request: async ({ method, params }) => {
      calls.push({ method, params });
      if (method in overrides) return overrides[method]({ method, params });
      switch (method) {
        case "eth_requestAccounts":
          return [ACCOUNT];
        case "eth_chainId":
          return "0x14a34"; // 84532
        case "eth_call":
          return "0x" + "0".repeat(64); // nonce 0
        case "eth_signTypedData_v4":
          return SIG;
        default:
          throw new Error(`unmocked ${method}`);
      }
    },
  };
}

function mockFetch(routes) {
  const posts = [];
  const fn = async (url, opts) => {
    const body = JSON.parse(opts.body);
    posts.push({ url, body });
    const route =
      url.endsWith("/orders/submitted") ? routes.submitted :
      url.endsWith("/orders") ? routes.orders :
      url.endsWith("/wallet") ? routes.wallet :
      url.endsWith("/terms") ? routes.terms :
      routes.grants;
    const { status, json } = route(body);
    return { status, json: async () => json };
  };
  fn.posts = posts;
  return fn;
}

const happyRoutes = {
  orders: () => ({ status: 200, json: ORDER }),
  grants: () => ({ status: 200, json: { status: "submitted", tx: "0xabc" } }),
};

test("happy path: connect → fetch → sign → submit; envelope is EXACTLY the encoder's output", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch(happyRoutes);
  const deps = { provider, fetchFn, config: CONFIG, initData: "id-blob" };

  const result = await runPermitFlow(deps, "oref-1");
  assert.equal(result.ok, true);
  assert.equal(result.status, "submitted");

  const grantPost = fetchFn.posts.find((p) => p.url.endsWith("/grants"));
  const orderPost = fetchFn.posts.find((p) => p.url.endsWith("/orders"));
  assert.equal(orderPost.body.v, CONFIG.version);
  assert.ok(grantPost, "grant POSTed");
  assert.equal(grantPost.body.init_data, "id-blob");
  assert.equal(grantPost.body.order_ref, "oref-1");
  assert.equal(grantPost.body.v, CONFIG.version);

  const expectedEnvelope = buildGrantEnvelope({
    version: CONFIG.version,
    chainId: CONFIG.chainId,
    token: CONFIG.token,
    spender: CONFIG.router,
    owner: ACCOUNT,
    value: ORDER.amount,
    deadline: ORDER.expires_at,
    signature: SIG,
  });
  assert.deepEqual(grantPost.body.permit, expectedEnvelope);

  // the typed data sent to the wallet binds spender = ROUTER and the order amount
  const signCall = provider.calls.find((c) => c.method === "eth_signTypedData_v4");
  const typed = JSON.parse(signCall.params[1]);
  assert.equal(typed.message.spender, CONFIG.router);
  assert.equal(typed.message.value, String(ORDER.amount));
  assert.equal(typed.domain.verifyingContract, CONFIG.token);
});

test("user rejects the signature → typed failure, NO grant POSTed", async () => {
  const provider = mockProvider({
    eth_signTypedData_v4: () => {
      const e = new Error("rejected");
      e.code = 4001;
      throw e;
    },
  });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "user_rejected" });
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/grants")).length, 0);
});

test("order not found → typed failure before ANY wallet interaction (fetch precedes connect since 0.3.1)", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 404, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "gone");
  assert.deepEqual(result, { ok: false, reason: "order_not_found" });
  assert.equal(provider.calls.length, 0);
});

test("intake version mismatch (stale build) → version_mismatch", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, grants: () => ({ status: 409, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "version_mismatch" });
});

test("wrong chain → typed failure, nothing signed, no grant POSTed", async () => {
  const provider = mockProvider({ eth_chainId: () => "0x1" });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "wrong_chain");
  // the order fetch precedes connect (0.3.1 drift guard); it is the ONLY request
  assert.deepEqual(fetchFn.posts.map((p) => p.url), [`${CONFIG.intakeUrl}/orders`]);
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
});

test("fetchPermitNonce: eth_call shape is nonces(owner) on the pinned token; nonce + deadline propagate into the typed data", async () => {
  const provider = mockProvider({
    // nonce 5
    eth_call: () => "0x" + "0".repeat(63) + "5",
  });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.equal(result.ok, true);

  // (a) the eth_call is nonces(address) against the pinned token
  const call = provider.calls.find((c) => c.method === "eth_call");
  assert.ok(call, "eth_call recorded");
  const [tx, block] = call.params;
  assert.equal(tx.to, CONFIG.token);
  assert.equal(tx.data, "0x7ecebe00" + "0".repeat(24) + ACCOUNT.slice(2).toLowerCase());
  assert.equal(block, "latest");

  // (b) the signed typed data carries the chain nonce and the order deadline
  const signCall = provider.calls.find((c) => c.method === "eth_signTypedData_v4");
  const typed = JSON.parse(signCall.params[1]);
  assert.equal(typed.message.nonce, "5");
  assert.equal(typed.message.deadline, String(ORDER.expires_at));
});

// Deliberate pin change (0.3.1): the order is now fetched BEFORE connect so
// the config-drift guard can block ahead of any wallet interaction — a
// connect refusal therefore no longer implies "nothing fetched", only that
// nothing was signed and no grant left the page.
test("wallet returns no accounts → no_account, nothing signed, no grant POSTed", async () => {
  const provider = mockProvider({ eth_requestAccounts: () => [] });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "no_account" });
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/grants")).length, 0);
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
});

test("non-4001 signing error → sign_failed (not user_rejected), NO grant POSTed", async () => {
  const provider = mockProvider({
    eth_signTypedData_v4: () => {
      throw new Error("wallet exploded"); // no .code
    },
  });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "sign_failed" });
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/grants")).length, 0);
});

test("401 from fetchOrder → unauthorized, nothing signed", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 401, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "unauthorized" });
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
});

test("410 from fetchOrder → expired, nothing signed", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 410, json: { error: "expired" } }) });
  const result = await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "expired" });
  assert.ok(!provider.calls.some((c) => c.method === "eth_sendTransaction"));
});

test("typed keeper failure (expired) surfaces as the reason", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    ...happyRoutes,
    grants: () => ({ status: 422, json: { status: "failed", reason: "expired" } }),
  });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "expired" });
});

test("fetchOrder sends token + v instead of init_data when token is present", async () => {
  const bodies = [];
  const fetchFn = mockFetch({
    orders: (body) => {
      bodies.push(body);
      return { status: 200, json: ORDER };
    },
  });

  await fetchOrder({ fetchFn, config: CONFIG, initData: "IGNORED", token: "tok" }, "oref-1");
  assert.equal(bodies[0].token, "tok");
  assert.equal(bodies[0].init_data, undefined);
  assert.equal(bodies[0].v, CONFIG.version);
});

test("walletDappLink strips the scheme and prefixes the universal link", () => {
  assert.equal(
    walletDappLink("https://pay.example/wallet/index.html?order=ab&token=cd"),
    "https://link.metamask.io/dapp/pay.example/wallet/index.html?order=ab&token=cd"
  );
  const custom = walletDappLink("https://x.example/i.html?a=1&token=t", "https://go.cb-w.com/dapp?cb_url=");
  const parsed = new URL(custom);
  assert.equal(parsed.searchParams.get("token"), null);
  assert.equal(parsed.searchParams.get("cb_url"), "x.example/i.html?a=1&token=t");
});

test("runUserTxFlow: connect → fetch → eth_sendTransaction → submitted report", async () => {
  const sent = [];
  const provider = mockProvider({
    eth_sendTransaction: ({ params }) => {
      sent.push(params[0]);
      return "0x" + "ef".repeat(32);
    },
  });
  const submitted = [];
  const fetchFn = mockFetch({
    orders: () => ({
      status: 200,
      json: {
        order_ref: "r1",
        kind: "user_tx",
        amount: 0,
        expires_at: 9_999_999_999,
        tx: {
          to: "0x" + "11".repeat(20),
          data: "0xdeadbeef",
          value: 9,
          gas: "0x5208",
          maxFeePerGas: "0x59682f00",
          maxPriorityFeePerGas: "0x3b9aca00",
          chainId: "0x14a34",
        },
        display: { summary_lines: ["Sell YES"] },
      },
    }),
    submitted: (body) => {
      submitted.push(body);
      return { status: 200, json: { status: "noted" } };
    },
  });

  const res = await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "tok" }, "r1");
  assert.equal(res.ok, true);
  assert.equal(sent[0].to, "0x" + "11".repeat(20));
  assert.equal(sent[0].data, "0xdeadbeef");
  assert.equal(sent[0].value, "0x9");
  assert.equal(sent[0].gas, "0x5208");
  assert.equal(sent[0].maxFeePerGas, "0x59682f00");
  assert.equal(sent[0].maxPriorityFeePerGas, "0x3b9aca00");
  assert.equal(sent[0].chainId, "0x14a34");
  assert.equal(sent[0].from, ACCOUNT);
  assert.equal(submitted[0].tx_hash, "0x" + "ef".repeat(32));
  assert.equal(submitted[0].token, "tok");
  assert.equal(submitted[0].v, CONFIG.version);
});

test("runUserTxFlow: user rejection is typed, no submitted report", async () => {
  const provider = mockProvider({
    eth_sendTransaction: () => {
      const e = new Error("denied");
      e.code = 4001;
      throw e;
    },
  });
  const fetchFn = mockFetch({
    orders: () => ({
      status: 200,
      json: { order_ref: "r1", kind: "user_tx", amount: 0, expires_at: 9_999_999_999, tx: { to: "0x1", data: "0x", value: 0 }, display: {} },
    }),
  });

  const res = await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "r1");
  assert.deepEqual(res, { ok: false, reason: "user_rejected" });
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/orders/submitted")).length, 0);
});

test("runUserTxFlow: unsafe numeric value is refused before wallet submission", async () => {
  let sendCalls = 0;
  const provider = mockProvider({
    eth_sendTransaction: () => {
      sendCalls += 1;
      return "0x" + "ef".repeat(32);
    },
  });
  const fetchFn = mockFetch({
    orders: () => ({
      status: 200,
      json: {
        order_ref: "r1",
        kind: "user_tx",
        amount: 0,
        expires_at: 9_999_999_999,
        tx: { to: "0x1", data: "0x", value: Number.MAX_SAFE_INTEGER + 1 },
        display: {},
      },
    }),
  });

  const res = await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "r1");
  assert.deepEqual(res, { ok: false, reason: "send_failed" });
  assert.equal(sendCalls, 0);
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/orders/submitted")).length, 0);
});

test("ownerMismatch: unbound orders never mismatch; bound orders compare case-insensitively", () => {
  const bound = "0x000000000000000000000000000000000000dEaD";
  assert.equal(ownerMismatch({}, ACCOUNT), false);
  assert.equal(ownerMismatch({ expected_owner: null }, ACCOUNT), false);
  assert.equal(ownerMismatch({ expected_owner: bound }, null), false); // not connected yet
  assert.equal(ownerMismatch({ expected_owner: ACCOUNT.toLowerCase() }, "0x" + ACCOUNT.slice(2).toUpperCase()), false);
  assert.equal(ownerMismatch({ expected_owner: bound }, ACCOUNT), true);
});

test("wrongWalletMessage shortens the bound address middle", () => {
  assert.equal(shortAddress("0x1234567890abcdef1234567890abcdef1234abcd"), "0x1234…abcd");
  assert.equal(
    wrongWalletMessage("0x1234567890abcdef1234567890abcdef1234abcd"),
    "Wrong wallet connected. Switch to 0x1234…abcd in your wallet, then reload."
  );
});

test("owner-bound permit order + wrong connected wallet → wrong_wallet, nothing signed or POSTed to /grants", async () => {
  const bound = "0x000000000000000000000000000000000000dEaD";
  const provider = mockProvider();
  const fetchFn = mockFetch({
    ...happyRoutes,
    orders: () => ({ status: 200, json: { ...ORDER, expected_owner: bound } }),
  });

  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "wrong_wallet", expected: bound });
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/grants")).length, 0);
});

test("owner-bound user_tx order + wrong connected wallet → wrong_wallet, nothing sent, no submitted report", async () => {
  const bound = "0x000000000000000000000000000000000000dEaD";
  let sendCalls = 0;
  const provider = mockProvider({
    eth_sendTransaction: () => {
      sendCalls += 1;
      return "0x" + "ef".repeat(32);
    },
  });
  const fetchFn = mockFetch({
    orders: () => ({
      status: 200,
      json: {
        order_ref: "r1",
        kind: "user_tx",
        amount: 0,
        expires_at: 9_999_999_999,
        expected_owner: bound,
        tx: { to: "0x" + "11".repeat(20), data: "0xdeadbeef", value: 0 },
        display: {},
      },
    }),
  });

  const res = await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "r1");
  assert.deepEqual(res, { ok: false, reason: "wrong_wallet", expected: bound });
  assert.equal(sendCalls, 0);
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/orders/submitted")).length, 0);
});

test("owner-bound order matching the connected wallet (different case) proceeds unchanged", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    ...happyRoutes,
    orders: () => ({ status: 200, json: { ...ORDER, expected_owner: ACCOUNT.toLowerCase() } }),
  });

  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.equal(result.ok, true);
  assert.equal(result.status, "submitted");
});

const BIND_ORDER = { order_ref: "b1", kind: "bind", amount: 0, expires_at: 9_999_999_999, display: {}, chain_id: CONFIG.chainId };
const bindOrders = () => ({ status: 200, json: BIND_ORDER });

test("runBindFlow: fetch bind order → connect → POST /wallet with connected address", async () => {
  const posts = [];
  const provider = mockProvider();
  const fetchFn = mockFetch({
    orders: bindOrders,
    wallet: (body) => {
      posts.push(body);
      return { status: 200, json: { status: "bound", address: body.address } };
    },
  });

  const res = await runBindFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "b1");
  assert.equal(res.ok, true);
  assert.equal(posts[0].address, ACCOUNT);
  assert.equal(posts[0].bind_ref, "b1");
  assert.equal(posts[0].v, CONFIG.version);
  // external dapp-browser binds have no initData — the token IS the auth
  assert.equal(posts[0].token, "t");
  assert.equal(posts[0].init_data, undefined);
});

test("runBindFlow: stale build 409 → version_mismatch; 410 → expired", async () => {
  const provider = mockProvider();
  const stale = mockFetch({ orders: bindOrders, wallet: () => ({ status: 409, json: { error: "version mismatch" } }) });
  assert.deepEqual(
    await runBindFlow({ provider, fetchFn: stale, config: CONFIG, initData: "", token: "t" }, "b1"),
    { ok: false, reason: "version_mismatch" }
  );

  const gone = mockFetch({ orders: bindOrders, wallet: () => ({ status: 410, json: { error: "expired" } }) });
  assert.deepEqual(
    await runBindFlow({ provider, fetchFn: gone, config: CONFIG, initData: "", token: "t" }, "b1"),
    { ok: false, reason: "expired" }
  );
});

// ── config drift (P1): order.chain_id is the keeper's RUNTIME chain; the
// static config.json can lag an operator RPC move. Drift = inconsistent
// deployment → fail CLOSED before ANY wallet interaction, and never
// auto-switch the wallet to the order's chain. ──────────────────────────────

test("configDrift: absent order chain_id never drifts (older keeper — backward compatible); present must equal config.chainId", () => {
  assert.equal(configDrift({}, CONFIG), false);
  assert.equal(configDrift({ chain_id: null }, CONFIG), false);
  assert.equal(configDrift({ chain_id: CONFIG.chainId }, CONFIG), false);
  assert.equal(configDrift({ chain_id: 8453 }, CONFIG), true);
  // a config missing its chainId cannot match a runtime-stamped order — closed
  assert.equal(configDrift({ chain_id: 8453 }, {}), true);
});

test("config drift on a permit order → config_drift, NO wallet interaction at all, no grant POSTed", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    ...happyRoutes,
    orders: () => ({ status: 200, json: { ...ORDER, chain_id: 8453 } }),
  });

  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "config_drift" });
  assert.equal(provider.calls.length, 0); // no eth_requestAccounts, no eth_chainId, nothing
  assert.deepEqual(fetchFn.posts.map((p) => p.url), [`${CONFIG.intakeUrl}/orders`]);
});

test("config drift on a user_tx order → config_drift, nothing sent, no submitted report", async () => {
  let sendCalls = 0;
  const provider = mockProvider({
    eth_sendTransaction: () => {
      sendCalls += 1;
      return "0x" + "ef".repeat(32);
    },
  });
  const fetchFn = mockFetch({
    orders: () => ({
      status: 200,
      json: {
        order_ref: "r1",
        kind: "user_tx",
        amount: 0,
        expires_at: 9_999_999_999,
        chain_id: 8453,
        tx: { to: "0x" + "11".repeat(20), data: "0xdeadbeef", value: 0 },
        display: {},
      },
    }),
  });

  const res = await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "r1");
  assert.deepEqual(res, { ok: false, reason: "config_drift" });
  assert.equal(provider.calls.length, 0);
  assert.equal(sendCalls, 0);
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/orders/submitted")).length, 0);
});

test("config drift on a bind order → config_drift, no connect, no /wallet POST", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    orders: () => ({ status: 200, json: { ...BIND_ORDER, chain_id: 8453 } }),
    wallet: () => ({ status: 200, json: { status: "bound", address: ACCOUNT } }),
  });

  const res = await runBindFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "b1");
  assert.deepEqual(res, { ok: false, reason: "config_drift" });
  assert.equal(provider.calls.length, 0);
  assert.equal(fetchFn.posts.filter((p) => p.url.endsWith("/wallet")).length, 0);
});

test("order chain_id matching config.chainId → flows unchanged (permit happy path)", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    ...happyRoutes,
    orders: () => ({ status: 200, json: { ...ORDER, chain_id: CONFIG.chainId } }),
  });

  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.equal(result.ok, true);
  assert.equal(result.status, "submitted");
});

// ── compliance status mappings + pre-action terms gates ───────────────────

const TERMS = { required: true, version: "2026-07-01", text: "Terms" };

test("termsRequired is true only for the literal required=true order state", () => {
  assert.equal(termsRequired(), false);
  assert.equal(termsRequired({}), false);
  assert.equal(termsRequired({ terms: null }), false);
  assert.equal(termsRequired({ terms: "malformed" }), false);
  assert.equal(termsRequired({ terms: {} }), false);
  assert.equal(termsRequired({ terms: { required: false } }), false);
  assert.equal(termsRequired({ terms: { required: 1 } }), false);
  assert.equal(termsRequired({ terms: { required: true } }), true);
});

test("fetchOrder maps 451 and 428 to exact compliance failures", async () => {
  const gated = mockFetch({ orders: () => ({ status: 428, json: { terms: TERMS } }) });
  assert.deepEqual(
    await fetchOrder({ fetchFn: gated, config: CONFIG, initData: "x" }, "oref-1"),
    { ok: false, reason: "terms_required", terms: TERMS }
  );

  const geo = mockFetch({ orders: () => ({ status: 451, json: { error: "blocked" } }) });
  assert.deepEqual(
    await fetchOrder({ fetchFn: geo, config: CONFIG, initData: "x" }, "oref-1"),
    { ok: false, reason: "geo_blocked" }
  );
});

test("grant POST maps 451 and 428 to exact compliance failures", async () => {
  for (const [status, json, expected] of [
    [428, { terms: TERMS }, { ok: false, reason: "terms_required", terms: TERMS, account: ACCOUNT }],
    [451, { error: "blocked" }, { ok: false, reason: "geo_blocked" }],
  ]) {
    const provider = mockProvider();
    const fetchFn = mockFetch({ ...happyRoutes, grants: () => ({ status, json }) });
    assert.deepEqual(
      await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1"),
      expected
    );
  }
});

test("wallet POST maps 451 and 428 to exact compliance failures", async () => {
  for (const [status, json, expected] of [
    [428, { terms: TERMS }, { ok: false, reason: "terms_required", terms: TERMS, account: ACCOUNT }],
    [451, { error: "blocked" }, { ok: false, reason: "geo_blocked" }],
  ]) {
    const provider = mockProvider();
    const fetchFn = mockFetch({ orders: bindOrders, wallet: () => ({ status, json }) });
    assert.deepEqual(
      await runBindFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "b1"),
      expected
    );
  }
});

test("permit required terms gate after connect/chain/owner but before nonce, signing, or grant POST", async () => {
  let ownerChecks = 0;
  const order = { ...ORDER, terms: TERMS };
  Object.defineProperty(order, "expected_owner", {
    enumerable: true,
    get() {
      ownerChecks += 1;
      return ACCOUNT.toLowerCase();
    },
  });
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 200, json: order }) });

  assert.deepEqual(
    await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1"),
    { ok: false, reason: "terms_required", terms: TERMS, account: ACCOUNT }
  );
  assert.deepEqual(provider.calls.map(({ method }) => method), ["eth_requestAccounts", "eth_chainId"]);
  assert.equal(ownerChecks, 1);
  assert.deepEqual(fetchFn.posts.map(({ url }) => url), [`${CONFIG.intakeUrl}/orders`]);
});

test("user_tx required terms gate after connect/chain/owner but before send or submitted POST", async () => {
  let ownerChecks = 0;
  const order = {
    order_ref: "r1",
    kind: "user_tx",
    amount: 0,
    expires_at: 9_999_999_999,
    tx: { to: "0x" + "11".repeat(20), data: "0xdeadbeef", value: 0 },
    display: {},
    terms: TERMS,
  };
  Object.defineProperty(order, "expected_owner", {
    enumerable: true,
    get() {
      ownerChecks += 1;
      return ACCOUNT.toLowerCase();
    },
  });
  const provider = mockProvider({ eth_sendTransaction: () => "0x" + "ef".repeat(32) });
  const fetchFn = mockFetch({
    orders: () => ({ status: 200, json: order }),
    submitted: () => ({ status: 200, json: { status: "noted" } }),
  });

  assert.deepEqual(
    await runUserTxFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "r1"),
    { ok: false, reason: "terms_required", terms: TERMS, account: ACCOUNT }
  );
  assert.deepEqual(provider.calls.map(({ method }) => method), ["eth_requestAccounts", "eth_chainId"]);
  assert.equal(ownerChecks, 1);
  assert.deepEqual(fetchFn.posts.map(({ url }) => url), [`${CONFIG.intakeUrl}/orders`]);
});

test("bind required terms gate after connect/chain but before wallet POST", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    orders: () => ({ status: 200, json: { ...BIND_ORDER, terms: TERMS } }),
    wallet: () => ({ status: 200, json: { status: "bound", address: ACCOUNT } }),
  });

  assert.deepEqual(
    await runBindFlow({ provider, fetchFn, config: CONFIG, initData: "", token: "t" }, "b1"),
    { ok: false, reason: "terms_required", terms: TERMS, account: ACCOUNT }
  );
  assert.deepEqual(provider.calls.map(({ method }) => method), ["eth_requestAccounts", "eth_chainId"]);
  assert.deepEqual(fetchFn.posts.map(({ url }) => url), [`${CONFIG.intakeUrl}/orders`]);
});

test("required terms do not outrank wrong-chain or wrong-wallet failures", async () => {
  const wrongChainProvider = mockProvider({ eth_chainId: () => "0x1" });
  const wrongChainFetch = mockFetch({
    ...happyRoutes,
    orders: () => ({ status: 200, json: { ...ORDER, terms: TERMS } }),
  });
  assert.deepEqual(
    await runPermitFlow({ provider: wrongChainProvider, fetchFn: wrongChainFetch, config: CONFIG, initData: "x" }, "oref-1"),
    { ok: false, reason: "wrong_chain", expected: CONFIG.chainId }
  );

  const bound = "0x000000000000000000000000000000000000dEaD";
  const wrongWalletProvider = mockProvider();
  const wrongWalletFetch = mockFetch({
    ...happyRoutes,
    orders: () => ({ status: 200, json: { ...ORDER, terms: TERMS, expected_owner: bound } }),
  });
  assert.deepEqual(
    await runPermitFlow({ provider: wrongWalletProvider, fetchFn: wrongWalletFetch, config: CONFIG, initData: "x" }, "oref-1"),
    { ok: false, reason: "wrong_wallet", expected: bound }
  );
});

test("geo-blocked order fetch is terminal before any provider interaction", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 451, json: {} }) });

  assert.deepEqual(
    await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1"),
    { ok: false, reason: "geo_blocked" }
  );
  assert.equal(provider.calls.length, 0);
});

test("required=false terms preserve the permit happy path", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    ...happyRoutes,
    orders: () => ({ status: 200, json: { ...ORDER, terms: { required: false } } }),
  });

  assert.deepEqual(
    await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1"),
    { ok: true, status: "submitted", tx: "0xabc" }
  );
});

test("permit retry reuses one successful authoritative order fetch", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch(happyRoutes);

  assert.deepEqual(
    await runPermitFlow(
      { provider, fetchFn, config: CONFIG, initData: "x" },
      "oref-1",
      { ok: true, order: ORDER }
    ),
    { ok: true, status: "submitted", tx: "0xabc" }
  );
  assert.equal(fetchFn.posts.filter(({ url }) => url.endsWith("/orders")).length, 0);
  assert.equal(fetchFn.posts.filter(({ url }) => url.endsWith("/grants")).length, 1);
});

test("all retries reuse an authoritative order-fetch failure without another request", async () => {
  const fetched = { ok: false, reason: "http_429" };

  for (const [flow, ref] of [
    [runPermitFlow, "oref-1"],
    [runUserTxFlow, "oref-1"],
    [runBindFlow, "b1"],
  ]) {
    const provider = mockProvider();
    const fetchFn = async () => { throw new Error("unexpected duplicate fetch"); };

    assert.deepEqual(
      await flow({ provider, fetchFn, config: CONFIG, initData: "x" }, ref, fetched),
      fetched
    );
    assert.equal(provider.calls.length, 0);
  }
});

// ── terms acceptance ───────────────────────────────────────────────────────

const TERMS_HASH = "0x" + "33".repeat(32);

test("acceptTerms signs exact typed data and POSTs the exact initData envelope with active ref", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    terms: () => ({ status: 200, json: { status: "accepted", v_hash: TERMS_HASH } }),
  });
  const issuedAt = 1_752_500_123;

  assert.deepEqual(
    await acceptTerms(
      { provider, fetchFn, config: CONFIG, initData: "id-blob", nowFn: () => issuedAt * 1000 + 999 },
      { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
    ),
    { ok: true, status: "accepted", vHash: TERMS_HASH }
  );

  const typedData = buildTermsTypedData({
    chainId: CONFIG.chainId,
    vHash: TERMS_HASH,
    account: ACCOUNT,
    issuedAt,
  });
  assert.deepEqual(provider.calls, [
    { method: "eth_signTypedData_v4", params: [ACCOUNT, JSON.stringify(typedData)] },
  ]);
  assert.deepEqual(fetchFn.posts, [
    {
      url: `${CONFIG.intakeUrl}/terms`,
      body: {
        v: CONFIG.version,
        init_data: "id-blob",
        ref: "oref-1",
        acceptance: buildTermsEnvelope({
          version: CONFIG.version,
          chainId: CONFIG.chainId,
          vHash: TERMS_HASH,
          account: ACCOUNT,
          issuedAt,
          signature: SIG,
        }),
      },
    },
  ]);
});

test("acceptTerms uses token auth instead of initData without changing the active ref", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    terms: () => ({ status: 200, json: { status: "accepted", v_hash: TERMS_HASH } }),
  });

  await acceptTerms(
    { provider, fetchFn, config: CONFIG, initData: "IGNORED", token: "tok", nowFn: () => 0 },
    { account: ACCOUNT, vHash: TERMS_HASH, ref: "bind-1" }
  );

  assert.equal(fetchFn.posts[0].body.token, "tok");
  assert.equal(fetchFn.posts[0].body.init_data, undefined);
  assert.equal(fetchFn.posts[0].body.ref, "bind-1");
});

test("acceptTerms maps wallet rejection and does not POST", async () => {
  const provider = mockProvider({
    eth_signTypedData_v4: () => {
      const error = new Error("no");
      error.code = 4001;
      throw error;
    },
  });
  const fetchFn = mockFetch({ terms: () => ({ status: 200, json: {} }) });

  assert.deepEqual(
    await acceptTerms(
      { provider, fetchFn, config: CONFIG, initData: "x" },
      { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
    ),
    { ok: false, reason: "user_rejected" }
  );
  assert.equal(fetchFn.posts.length, 0);
});

test("acceptTerms maps other signing failures and does not POST", async () => {
  const provider = mockProvider({
    eth_signTypedData_v4: () => {
      throw new Error("broken wallet");
    },
  });
  const fetchFn = mockFetch({ terms: () => ({ status: 200, json: {} }) });

  assert.deepEqual(
    await acceptTerms(
      { provider, fetchFn, config: CONFIG, initData: "x" },
      { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
    ),
    { ok: false, reason: "sign_failed" }
  );
  assert.equal(fetchFn.posts.length, 0);
});

test("acceptTerms maps a rejected request to a retryable typed failure", async () => {
  const provider = mockProvider();
  let requests = 0;
  const fetchFn = async () => {
    requests += 1;
    throw new Error("offline");
  };

  assert.deepEqual(
    await acceptTerms(
      { provider, fetchFn, config: CONFIG, initData: "x", nowFn: () => 0 },
      { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
    ),
    { ok: false, reason: "request_failed" }
  );
  assert.equal(requests, 1);
});

test("acceptTerms maps 451 and 401 without parsing an empty body", async () => {
  for (const [status, expected] of [
    [451, { ok: false, reason: "geo_blocked" }],
    [401, { ok: false, reason: "unauthorized" }],
  ]) {
    let jsonCalls = 0;
    const fetchFn = async () => ({
      status,
      json: async () => {
        jsonCalls += 1;
        throw new SyntaxError("empty body");
      },
    });
    assert.deepEqual(
      await acceptTerms(
        { provider: mockProvider(), fetchFn, config: CONFIG, initData: "x", nowFn: () => 0 },
        { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
      ),
      expected
    );
    assert.equal(jsonCalls, 0);
  }
});

test("acceptTerms safely types malformed JSON responses", async () => {
  for (const [status, expected] of [
    [200, { ok: false, reason: "invalid_response" }],
    [503, { ok: false, reason: "http_503" }],
  ]) {
    const fetchFn = async () => ({
      status,
      json: async () => { throw new SyntaxError("bad JSON"); },
    });
    assert.deepEqual(
      await acceptTerms(
        { provider: mockProvider(), fetchFn, config: CONFIG, initData: "x", nowFn: () => 0 },
        { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
      ),
      expected
    );
  }
});

test("acceptTerms does not confirm a 200 without the accepted status and hash", async () => {
  for (const json of [{ status: "accepted" }, { v_hash: TERMS_HASH }]) {
    const fetchFn = mockFetch({ terms: () => ({ status: 200, json }) });
    assert.deepEqual(
      await acceptTerms(
        { provider: mockProvider(), fetchFn, config: CONFIG, initData: "x", nowFn: () => 0 },
        { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
      ),
      { ok: false, reason: "invalid_response" }
    );
  }
});

test("acceptTerms maps stale/current hash, compliance, validation, and generic HTTP failures", async () => {
  const currentHash = "0x" + "44".repeat(32);
  const currentTerms = { v_hash: currentHash, url: "https://example.test/terms-v2" };
  const cases = [
    [409, { error: "terms_stale", v_hash: currentHash, terms: currentTerms }, { ok: false, reason: "terms_stale", terms: currentTerms }],
    [451, { error: "geo_blocked" }, { ok: false, reason: "geo_blocked" }],
    [401, { error: "unauthorized" }, { ok: false, reason: "unauthorized" }],
    [409, { error: "version mismatch" }, { ok: false, reason: "version_mismatch" }],
    [422, { error: "invalid", field: "sig" }, { ok: false, reason: "invalid", field: "sig" }],
    [503, { error: "unavailable" }, { ok: false, reason: "unavailable" }],
    [418, {}, { ok: false, reason: "http_418" }],
  ];

  for (const [status, json, expected] of cases) {
    const provider = mockProvider();
    const fetchFn = mockFetch({ terms: () => ({ status, json }) });
    assert.deepEqual(
      await acceptTerms(
        { provider, fetchFn, config: CONFIG, initData: "x", nowFn: () => 0 },
        { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
      ),
      expected
    );
  }
});

test("acceptTerms rejects stale responses without one matching current hash and URL", async () => {
  const currentHash = "0x" + "44".repeat(32);
  const malformed = [
    { error: "terms_stale", v_hash: currentHash },
    { error: "terms_stale", v_hash: currentHash, terms: { v_hash: currentHash } },
    { error: "terms_stale", v_hash: currentHash, terms: { v_hash: TERMS_HASH, url: "https://example.test/terms-v2" } },
  ];

  for (const json of malformed) {
    const fetchFn = mockFetch({ terms: () => ({ status: 409, json }) });
    assert.deepEqual(
      await acceptTerms(
        { provider: mockProvider(), fetchFn, config: CONFIG, initData: "x", nowFn: () => 0 },
        { account: ACCOUNT, vHash: TERMS_HASH, ref: "oref-1" }
      ),
      { ok: false, reason: "invalid_response" }
    );
  }
});
