// node --test suite for the Mini App flow logic with a mock EIP-1193
// provider + mock fetch (spec §8 "mock EIP-1193 provider flows automated").
// Run: node --test webapp/tools/flow.test.mjs

import test from "node:test";
import assert from "node:assert/strict";
import { fetchOrder, runBindFlow, runPermitFlow, runUserTxFlow, walletDappLink } from "../lib/flow.mjs";
import { buildGrantEnvelope } from "../lib/permit.mjs";

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

test("order not found → typed failure before any wallet interaction beyond connect", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, orders: () => ({ status: 404, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "gone");
  assert.deepEqual(result, { ok: false, reason: "order_not_found" });
  assert.ok(!provider.calls.some((c) => c.method === "eth_signTypedData_v4"));
});

test("intake version mismatch (stale build) → version_mismatch", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({ ...happyRoutes, grants: () => ({ status: 409, json: {} }) });
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "version_mismatch" });
});

test("wrong chain → typed failure, nothing signed, nothing POSTed", async () => {
  const provider = mockProvider({ eth_chainId: () => "0x1" });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "wrong_chain");
  assert.equal(fetchFn.posts.length, 0);
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

test("wallet returns no accounts → no_account, nothing fetched or signed", async () => {
  const provider = mockProvider({ eth_requestAccounts: () => [] });
  const fetchFn = mockFetch(happyRoutes);
  const result = await runPermitFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-1");
  assert.deepEqual(result, { ok: false, reason: "no_account" });
  assert.equal(fetchFn.posts.length, 0);
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
  assert.ok(walletDappLink("https://x.example/i.html?a=1", "https://go.cb-w.com/dapp?cb_url=").startsWith("https://go.cb-w.com/dapp?cb_url="));
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
          value: "0x20000000000001",
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
  assert.equal(sent[0].value, "0x20000000000001");
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

test("runBindFlow: connect → POST /wallet with connected address", async () => {
  const posts = [];
  const provider = mockProvider();
  const fetchFn = mockFetch({
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
});
