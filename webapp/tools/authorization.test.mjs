// node --test suite for the authorization (EIP-3009) lane's wallet dapp flow
// — the sibling of flow.test.mjs's permit-lane coverage. Run: node --test
// webapp/tools/

import test from "node:test";
import assert from "node:assert/strict";
import { configDrift, runAuthorizationFlow, termsRequired } from "../lib/flow.mjs";
import { buildAuthorizationEnvelope, buildAuthorizationTypedData } from "../lib/authorization.mjs";

const CONFIG = {
  version: "0.1.0",
  chainId: 84532,
  token: "0x000000000000000000000000000000000000aaaa",
  intakeUrl: "https://app.example/spend",
  actionLabel: "Top up",
};

const ACCOUNT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const TREASURY = "0x000000000000000000000000000000000000cccc";
const NONCE = "0x" + "ab".repeat(32);
const SIG = "0x" + "11".repeat(65);

const DOMAIN = {
  name: "USDC",
  version: "2",
  chainId: 84532,
  verifyingContract: CONFIG.token,
};

const ORDER = {
  order_ref: "oref-a1",
  kind: "authorization",
  amount: 1_000_000,
  value: 1_000_000,
  to: TREASURY,
  token: CONFIG.token,
  nonce: NONCE,
  valid_after: 0,
  valid_before: 1_900_000_000,
  expires_at: 1_900_000_000,
  chain_id: 84532,
  domain: DOMAIN,
  display: {},
};

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
    const route = url.endsWith("/orders") ? routes.orders : routes.authorization;
    const { status, json } = route(body);
    return { status, json: async () => json };
  };
  fn.posts = posts;
  return fn;
}

const happyRoutes = {
  orders: () => ({ status: 200, json: ORDER }),
  authorization: () => ({ status: 200, json: { status: "submitted", tx: "0xabc" } }),
};

test("buildAuthorizationTypedData: exact EIP-712 shape, no permit/owner fields", () => {
  const typedData = buildAuthorizationTypedData({
    domain: DOMAIN,
    from: ACCOUNT,
    to: TREASURY,
    value: 1_000_000,
    validAfter: 0,
    validBefore: 1_900_000_000,
    nonce: NONCE,
  });

  assert.equal(typedData.primaryType, "TransferWithAuthorization");
  assert.deepEqual(typedData.domain, DOMAIN);
  assert.deepEqual(Object.keys(typedData.message).sort(), [
    "from",
    "nonce",
    "to",
    "validAfter",
    "validBefore",
    "value",
  ]);
  assert.equal(typedData.message.from, ACCOUNT);
  assert.equal(typedData.message.to, TREASURY);
  assert.equal(typedData.message.nonce, NONCE);
  // uint256 fields travel as decimal strings, matching buildPermitTypedData's convention
  assert.equal(typedData.message.value, "1000000");
  assert.equal(typedData.message.validBefore, "1900000000");
});

test("buildAuthorizationEnvelope: no \"to\" field — the server picks the destination", () => {
  const envelope = buildAuthorizationEnvelope({
    version: CONFIG.version,
    chainId: CONFIG.chainId,
    token: CONFIG.token,
    from: ACCOUNT,
    value: 1_000_000,
    validAfter: 0,
    validBefore: 1_900_000_000,
    signature: SIG,
  });

  assert.deepEqual(Object.keys(envelope).sort(), [
    "chain_id",
    "from",
    "signature",
    "token",
    "v",
    "valid_after",
    "valid_before",
    "value",
  ]);
  assert.equal(envelope.v, CONFIG.version);
  assert.equal(envelope.token, CONFIG.token);
  assert.equal(envelope.from, ACCOUNT);
  assert.equal(envelope.value, 1_000_000);
  assert.equal(envelope.signature, SIG);
});

test("happy path: connect → fetch → sign → submit; envelope is EXACTLY the encoder's output", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch(happyRoutes);
  const deps = { provider, fetchFn, config: CONFIG, initData: "id-blob" };

  const result = await runAuthorizationFlow(deps, "oref-a1");
  assert.equal(result.ok, true);
  assert.equal(result.status, "submitted");
  assert.equal(result.tx, "0xabc");

  const authPost = fetchFn.posts.find((p) => p.url.endsWith("/authorization"));
  assert.ok(authPost, "authorization POSTed");
  assert.equal(authPost.body.init_data, "id-blob");
  assert.equal(authPost.body.order_ref, "oref-a1");
  assert.equal(authPost.body.v, CONFIG.version);

  const expectedEnvelope = buildAuthorizationEnvelope({
    version: CONFIG.version,
    chainId: CONFIG.chainId,
    token: ORDER.token,
    from: ACCOUNT,
    value: ORDER.value,
    validAfter: ORDER.valid_after,
    validBefore: ORDER.valid_before,
    signature: SIG,
  });
  assert.deepEqual(authPost.body.authorization, expectedEnvelope);

  // the typed data signed is built from the SERVER's order fields, never
  // client recomputation — `to`/`value`/`nonce`/`domain` all trace back to ORDER
  const signCall = provider.calls.find((c) => c.method === "eth_signTypedData_v4");
  const [, typedDataJson] = signCall.params;
  const typedData = JSON.parse(typedDataJson);
  assert.deepEqual(typedData.domain, ORDER.domain);
  assert.equal(typedData.message.to, ORDER.to);
  assert.equal(typedData.message.nonce, ORDER.nonce);
});

test("terms_required: gates before signing, surfaces the account for the retry", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    orders: () => ({
      status: 200,
      json: { ...ORDER, terms: { required: true, v_hash: "0x" + "1".repeat(64), url: "https://x/terms" } },
    }),
    authorization: () => {
      throw new Error("must not sign/submit before terms are accepted");
    },
  });

  const result = await runAuthorizationFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-a1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "terms_required");
  assert.equal(result.account, ACCOUNT);
  assert.equal(termsRequired({ terms: { required: true } }), true);
});

test("wrong_kind: refuses a non-authorization order fetched by mistake", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    orders: () => ({ status: 200, json: { ...ORDER, kind: "permit" } }),
    authorization: () => {
      throw new Error("must not submit");
    },
  });

  const result = await runAuthorizationFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-a1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "wrong_kind");
});

test("config drift blocks BEFORE any wallet interaction", async () => {
  const provider = mockProvider({
    eth_requestAccounts: () => {
      throw new Error("must not connect on drift");
    },
  });
  const fetchFn = mockFetch({
    orders: () => ({ status: 200, json: { ...ORDER, chain_id: 1 } }),
    authorization: () => {
      throw new Error("must not submit");
    },
  });

  const result = await runAuthorizationFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-a1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "config_drift");
  assert.equal(configDrift({ chain_id: 1 }, CONFIG), true);
});

test("user_rejected / sign_failed are typed, and nothing is POSTed", async () => {
  const rejected = mockProvider({
    eth_signTypedData_v4: () => {
      const e = new Error("rejected");
      e.code = 4001;
      throw e;
    },
  });
  const fetchFn = mockFetch({
    orders: happyRoutes.orders,
    authorization: () => {
      throw new Error("must not submit after a declined signature");
    },
  });

  const result = await runAuthorizationFlow({ provider: rejected, fetchFn, config: CONFIG, initData: "x" }, "oref-a1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "user_rejected");
});

test("a non-200 authorization response maps the body's reason/error, or falls back to http_<status>", async () => {
  const provider = mockProvider();
  const fetchFn = mockFetch({
    orders: happyRoutes.orders,
    authorization: () => ({ status: 422, json: { status: "failed", reason: "expired" } }),
  });

  const result = await runAuthorizationFlow({ provider, fetchFn, config: CONFIG, initData: "x" }, "oref-a1");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "expired");
});
