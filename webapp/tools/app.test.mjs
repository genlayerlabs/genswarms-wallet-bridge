import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { MESSAGES, entryRef, paintStatus, setupAuthorization, showTermsPrompt } from "../app.mjs";

const ACCOUNT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const TREASURY = "0x000000000000000000000000000000000000cccc";
const HASH = "0x" + "11".repeat(32);

function fakeDom() {
  const elements = {
    summary: { textContent: "", dataset: {} },
    terms: { hidden: true },
    "terms-link": { href: "" },
    "terms-accept": { disabled: false, onclick: null },
    pay: { hidden: false, disabled: false, onclick: null },
    manual: { hidden: false },
    "manual-address": { textContent: "" },
    "manual-amount": { textContent: "" },
    status: { textContent: "", dataset: {} },
  };
  return { elements, get: (id) => elements[id] };
}

function mockAuthProvider(overrides = {}) {
  return {
    request: async ({ method, params }) => {
      if (method in overrides) return overrides[method](params);
      switch (method) {
        case "eth_requestAccounts":
          return [ACCOUNT];
        case "eth_chainId":
          return "0x14a34"; // 84532
        default:
          throw new Error(`unmocked ${method}`);
      }
    },
  };
}

test("entryRef accepts order refs, bind refs, and Telegram start_param", () => {
  assert.equal(entryRef(null, new URLSearchParams("order=o1&token=t")), "o1");
  assert.equal(entryRef(null, new URLSearchParams("bind=b1&token=t")), "b1");
  assert.equal(
    entryRef({ initDataUnsafe: { start_param: "tg-ref" } }, new URLSearchParams("order=o1&bind=b1")),
    "tg-ref"
  );
});

test("paintStatus stamps terminal states and clears the stamp on progress text", () => {
  const el = { textContent: "", dataset: {} };

  paintStatus(el, "Payment failed (x).", "error");
  assert.equal(el.textContent, "Payment failed (x).");
  assert.equal(el.dataset.state, "error");

  paintStatus(el, "Connecting wallet…");
  assert.equal(el.textContent, "Connecting wallet…");
  assert.equal(el.dataset.state, undefined);

  paintStatus(el, "Payment submitted ✓", "success");
  assert.equal(el.dataset.state, "success");
});

test("compliance messages are exact", () => {
  assert.equal(MESSAGES.geo_blocked, "This service isn't available in your region.");
  assert.equal(MESSAGES.terms_stale, "The terms were updated — please review and accept the new version.");
});

test("terms controls are hidden and accessible with a safely opened link", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /<div id="terms" hidden>/);
  assert.match(html, /<a id="terms-link" target="_blank" rel="noopener noreferrer">[^<]+<\/a>/);
  assert.match(html, /<button id="terms-accept"[^>]*>[^<]+<\/button>/);
});

test("terms prompt wires URL/hash/ref/account and retries the original action after confirmed acceptance", async () => {
  const { elements, get } = fakeDom();
  const calls = [];
  let retries = 0;
  const acceptFn = async (deps, args) => {
    calls.push({ deps, args });
    return { ok: true, status: "accepted", vHash: HASH };
  };
  const deps = { marker: "deps" };

  showTermsPrompt(
    deps,
    {
      account: ACCOUNT,
      terms: { url: "https://example.test/terms", v_hash: HASH },
      ref: "oref-1",
      retry: async () => { retries += 1; },
    },
    get,
    acceptFn
  );

  assert.equal(elements.terms.hidden, false);
  assert.equal(elements["terms-link"].href, "https://example.test/terms");
  assert.equal(elements.pay.hidden, true);
  assert.equal(elements.pay.disabled, true);
  assert.equal(elements.manual.hidden, true);

  await elements["terms-accept"].onclick();
  assert.deepEqual(calls, [{ deps, args: { account: ACCOUNT, vHash: HASH, ref: "oref-1" } }]);
  assert.equal(elements.terms.hidden, true);
  assert.equal(elements.pay.hidden, false);
  assert.equal(retries, 1);
});

test("accepted terms restore the server-authorized manual fallback before retry", async () => {
  const { elements, get } = fakeDom();
  const manual = {
    address: "0x0000000000000000000000000000000000000001",
    amount: 2_500_000,
  };
  const deps = {
    config: { intakeUrl: "/spend", version: "0.5.0" },
    initData: "signed-init-data",
    fetchFn: async () => ({
      status: 200,
      json: async () => ({ kind: "permit", display: { manual } }),
    }),
  };
  let retriedWith;

  showTermsPrompt(
    deps,
    {
      account: ACCOUNT,
      terms: { url: "https://example.test/terms", v_hash: HASH },
      ref: "oref-1",
      retry: async (fetched) => { retriedWith = fetched; },
    },
    get,
    async () => ({ ok: true, status: "accepted", vHash: HASH })
  );

  await elements["terms-accept"].onclick();

  assert.equal(elements.manual.hidden, false);
  assert.equal(elements["manual-address"].textContent, manual.address);
  assert.equal(elements["manual-amount"].textContent, "Send exactly 2.50 USDC on Base to:");
  assert.deepEqual(retriedWith, {
    ok: true,
    order: { kind: "permit", display: { manual } },
  });
});

test("accepted terms keep every action hidden when the refreshed order has config drift", async () => {
  const { elements, get } = fakeDom();
  let retries = 0;
  const deps = {
    config: { intakeUrl: "/spend", version: "0.5.0", chainId: 84_532 },
    initData: "signed-init-data",
    fetchFn: async () => ({
      status: 200,
      json: async () => ({
        kind: "permit",
        chain_id: 1,
        display: {
          manual: {
            address: "0x0000000000000000000000000000000000000001",
            amount: 2_500_000,
          },
        },
      }),
    }),
  };

  showTermsPrompt(
    deps,
    {
      account: ACCOUNT,
      terms: { url: "https://example.test/terms", v_hash: HASH },
      ref: "oref-1",
      retry: async () => { retries += 1; },
    },
    get,
    async () => ({ ok: true, status: "accepted", vHash: HASH })
  );

  await elements["terms-accept"].onclick();

  assert.equal(elements.manual.hidden, true);
  assert.equal(elements.pay.hidden, true);
  assert.equal(elements.terms.hidden, true);
  assert.equal(elements["terms-accept"].disabled, true);
  assert.equal(elements.status.textContent, MESSAGES.config_drift);
  assert.equal(elements.status.dataset.state, "error");
  assert.equal(retries, 0);
});

test("stale terms replace the hash and require a second signature click", async () => {
  const { elements, get } = fakeDom();
  const currentHash = "0x" + "22".repeat(32);
  const currentTerms = { v_hash: currentHash, url: "https://example.test/terms-v2" };
  const signedHashes = [];
  let retries = 0;
  const acceptFn = async (_deps, { vHash }) => {
    signedHashes.push(vHash);
    return signedHashes.length === 1
      ? { ok: false, reason: "terms_stale", terms: currentTerms }
      : { ok: true, status: "accepted", vHash: currentHash };
  };

  showTermsPrompt(
    {},
    { account: ACCOUNT, terms: { url: "https://example.test/terms", v_hash: HASH }, ref: "oref-1", retry: async () => { retries += 1; } },
    get,
    acceptFn
  );

  await elements["terms-accept"].onclick();
  assert.deepEqual(signedHashes, [HASH]);
  assert.equal(elements.status.textContent, MESSAGES.terms_stale);
  assert.equal(elements.status.dataset.state, "error");
  assert.equal(elements["terms-link"].href, currentTerms.url);
  assert.equal(elements["terms-accept"].disabled, false);
  assert.equal(retries, 0);

  await elements["terms-accept"].onclick();
  assert.deepEqual(signedHashes, [HASH, currentHash]);
  assert.equal(retries, 1);
});

test("geo-blocked acceptance enters a terminal error state and hides every action", async () => {
  const { elements, get } = fakeDom();
  let retries = 0;
  showTermsPrompt(
    {},
    { account: ACCOUNT, terms: { url: "https://example.test/terms", v_hash: HASH }, ref: "oref-1", retry: async () => { retries += 1; } },
    get,
    async () => ({ ok: false, reason: "geo_blocked" })
  );

  await elements["terms-accept"].onclick();
  assert.equal(elements.status.textContent, MESSAGES.geo_blocked);
  assert.equal(elements.status.dataset.state, "error");
  assert.equal(elements.terms.hidden, true);
  assert.equal(elements.pay.hidden, true);
  assert.equal(elements.manual.hidden, true);
  assert.equal(elements["terms-accept"].disabled, true);
  assert.equal(retries, 0);
});

test("nonterminal acceptance failure shows its typed message and re-enables acceptance", async () => {
  const { elements, get } = fakeDom();
  let retries = 0;
  showTermsPrompt(
    {},
    { account: ACCOUNT, terms: { url: "https://example.test/terms", v_hash: HASH }, ref: "oref-1", retry: async () => { retries += 1; } },
    get,
    async () => ({ ok: false, reason: "unauthorized" })
  );

  await elements["terms-accept"].onclick();
  assert.equal(elements.status.textContent, MESSAGES.unauthorized);
  assert.equal(elements.status.dataset.state, "error");
  assert.equal(elements.terms.hidden, false);
  assert.equal(elements.pay.hidden, true);
  assert.equal(elements["terms-accept"].disabled, false);
  assert.equal(retries, 0);
});

test("terms-required without a proven account never signs and re-enables the payment action", () => {
  const { elements, get } = fakeDom();
  let accepts = 0;
  let retries = 0;
  showTermsPrompt(
    {},
    { account: undefined, terms: { url: "https://example.test/terms", v_hash: HASH }, ref: "oref-1", retry: async () => { retries += 1; } },
    get,
    async () => { accepts += 1; return { ok: true }; }
  );

  assert.equal(accepts, 0);
  assert.equal(retries, 0);
  assert.equal(elements.terms.hidden, true);
  assert.equal(elements.pay.hidden, false);
  assert.equal(elements.pay.disabled, false);
  assert.equal(elements.status.textContent, MESSAGES.no_account);
  assert.equal(elements.status.dataset.state, "error");
  assert.equal(elements["terms-accept"].onclick, null);
});

test("thrown acceptance request stays nonterminal and re-enables acceptance without retrying the action", async () => {
  const { elements, get } = fakeDom();
  let retries = 0;
  showTermsPrompt(
    {},
    { account: ACCOUNT, terms: { url: "https://example.test/terms", v_hash: HASH }, ref: "oref-1", retry: async () => { retries += 1; } },
    get,
    async () => { throw new Error("offline"); }
  );

  await assert.doesNotReject(elements["terms-accept"].onclick());
  assert.equal(elements.status.textContent, "Terms acceptance failed (request_failed).");
  assert.equal(elements.status.dataset.state, "error");
  assert.equal(elements.terms.hidden, false);
  assert.equal(elements.pay.hidden, true);
  assert.equal(elements["terms-accept"].disabled, false);
  assert.equal(retries, 0);
});

// Review C1: `setupAuthorization` used to read `order.value`/`order.to`
// unconditionally — fields `Intake.handle_order/3` WITHHOLDS until the
// current terms are accepted — so a first-time user on a compliance-enabled
// deployment hit a TypeError before the terms prompt could ever render.
describe("setupAuthorization (review C1)", () => {
  test("a terms-pending order (value/to withheld) never throws and defers to the terms prompt on pay", async () => {
    const { elements, get } = fakeDom();
    const order = {
      kind: "authorization",
      amount: 1_500_000,
      terms: { required: true, v_hash: HASH, url: "https://example.test/terms" },
      // value/to/domain/nonce intentionally ABSENT — exactly what the server
      // serves while the current terms are unaccepted (probe P6).
    };
    const deps = {
      provider: mockAuthProvider(),
      config: { intakeUrl: "/spend", version: "0.5.0", chainId: 84_532, actionLabel: "Top up" },
      fetchFn: async () => ({ status: 200, json: async () => order }),
    };

    // The bug reproduced as an unhandled rejection/throw right here.
    await assert.doesNotReject(setupAuthorization(deps, order, "oref-1", null, get));

    assert.equal(elements.summary.textContent.includes("NaN"), false);
    assert.match(elements.summary.textContent, /1\.50 USDC/);
    assert.equal(elements.pay.disabled, false);

    // Clicking pay re-fetches the order (still terms-pending), connects the
    // wallet, and — same as every other lane — opens the terms prompt
    // instead of signing.
    await assert.doesNotReject(elements.pay.onclick());
    assert.equal(elements.terms.hidden, false);
    assert.equal(elements["terms-link"].href, order.terms.url);
    assert.equal(elements.pay.hidden, true);
  });

  test("a terms-accepted order renders the destination/amount up front and enables pay", async () => {
    const { elements, get } = fakeDom();
    const order = {
      kind: "authorization",
      amount: 2_000_000,
      to: TREASURY,
      value: 2_000_000,
      domain: { name: "USDC", version: "2", chainId: 84_532, verifyingContract: "0x000000000000000000000000000000000000aaaa" },
      nonce: "0x" + "ab".repeat(32),
      terms: { required: false, v_hash: HASH, url: "https://example.test/terms" },
    };
    const deps = {
      provider: mockAuthProvider(),
      config: { intakeUrl: "/spend", version: "0.5.0", chainId: 84_532, actionLabel: "Top up" },
      fetchFn: async () => ({ status: 200, json: async () => order }),
    };

    await assert.doesNotReject(setupAuthorization(deps, order, "oref-2", null, get));

    assert.match(elements.summary.textContent, /2\.00 USDC/);
    assert.match(elements.summary.textContent, /0x0000…cccc/);
    assert.equal(elements.pay.disabled, false);
  });

  // Review N1: the C1 fix's own copy promises "accept the terms to see the
  // destination and pay" on the terms-pending render, but nothing ever
  // recomposed the summary after the terms were actually accepted — the user
  // reached eth_signTypedData_v4 with the summary still reading the
  // terms-pending copy. Probe C: capture #summary at the instant the wallet
  // is asked to sign, on the accept-then-pay path.
  test("(review N1) accepting terms then paying recomposes the summary with the destination before signing", async () => {
    const { elements, get } = fakeDom();
    const pending = {
      kind: "authorization",
      amount: 1_500_000,
      terms: { required: true, v_hash: HASH, url: "https://example.test/terms" },
      // value/to/domain/nonce withheld — same shape as probe P6.
    };
    const enriched = {
      kind: "authorization",
      amount: 1_500_000,
      to: TREASURY,
      value: 1_500_000,
      domain: { name: "USDC", version: "2", chainId: 84_532, verifyingContract: "0x000000000000000000000000000000000000aaaa" },
      nonce: "0x" + "ab".repeat(32),
      valid_after: 0,
      valid_before: 1_900_000_000,
      token: "0x000000000000000000000000000000000000aaaa",
      terms: { required: false, v_hash: HASH, url: "https://example.test/terms" },
    };
    let fetchCalls = 0;
    const summaryAtSignTime = [];
    const deps = {
      provider: mockAuthProvider({
        // eth_signTypedData_v4 fires twice on this path: once for the terms
        // acceptance signature (primaryType "TermsAcceptance"), once for the
        // actual money-moving signature (primaryType
        // "TransferWithAuthorization"). Only the latter is the binding-rule
        // moment probe-C cares about (to/value must be VISIBLE before THAT
        // signature) — filter on typed-data shape rather than call order.
        eth_signTypedData_v4: (params) => {
          const typedData = JSON.parse(params[1]);
          if (typedData.primaryType === "TransferWithAuthorization") {
            summaryAtSignTime.push(elements.summary.textContent);
          }
          // Valid-shaped ECDSA sig (r + s + v=0x1c): the terms-acceptance leg
          // of this path runs the signature through splitSignature, which
          // rejects a v byte outside {27,28} — unlike SIG constants used
          // elsewhere in this suite that never reach splitSignature.
          return "0x" + "11".repeat(32) + "22".repeat(32) + "1c";
        },
      }),
      config: { intakeUrl: "/spend", version: "0.5.0", chainId: 84_532, actionLabel: "Top up" },
      fetchFn: async (url) => {
        if (url.endsWith("/orders")) {
          fetchCalls += 1;
          return { status: 200, json: async () => (fetchCalls === 1 ? pending : enriched) };
        }
        if (url.endsWith("/terms")) {
          return { status: 200, json: async () => ({ status: "accepted", v_hash: HASH }) };
        }
        if (url.endsWith("/authorization")) {
          return { status: 200, json: async () => ({ status: "submitted", tx: "0x" + "bb".repeat(32) }) };
        }
        throw new Error(`unmocked fetch ${url}`);
      },
    };

    await assert.doesNotReject(setupAuthorization(deps, pending, "oref-n1", null, get));
    assert.match(elements.summary.textContent, /accept the terms to see the destination/);

    // First pay click: terms-pending re-fetch surfaces terms_required and
    // opens the prompt (same as the C1-era test above).
    await assert.doesNotReject(elements.pay.onclick());
    assert.equal(elements.terms.hidden, false);

    // Accept: showTermsPrompt re-fetches (now enriched), must recompose the
    // summary BEFORE retry() drives the signature.
    await assert.doesNotReject(elements["terms-accept"].onclick());

    assert.equal(summaryAtSignTime.length, 1, "eth_signTypedData_v4 must have been reached exactly once");
    assert.match(summaryAtSignTime[0], /0x0000…cccc/, "destination must be visible at sign time");
    assert.match(summaryAtSignTime[0], /1\.50 USDC/, "amount must be visible at sign time");
    assert.doesNotMatch(summaryAtSignTime[0], /accept the terms/, "stale terms-pending copy must not survive to sign time");
  });
});

// Review N2: `shortAddress`'s falsy guard let a disabled-lane order (no
// enrichment, terms NOT required — e.g. a config-drifted restart that lands
// the keeper back on a permit-only build, probe P8) render a fabricated
// destination with pay ENABLED, walking the user into a wallet prompt for
// structurally invalid typed data. Probe D: pay must stay disabled and the
// signing call must be unreachable; an explicit message must render instead.
describe("setupAuthorization (review N2)", () => {
  test("a disabled-lane order (enrichment missing, terms not required) never enables pay", async () => {
    const { elements, get } = fakeDom();
    const order = {
      kind: "authorization",
      amount: 1_000_000,
      terms: { required: false, v_hash: HASH, url: "https://example.test/terms" },
      // to/value/domain/nonce intentionally ABSENT, exactly probe P8's shape,
      // and terms.required is false — so this is NOT the C1/N1 terms-pending
      // case; it is a broken/disabled deployment state.
    };
    let signAttempts = 0;
    const deps = {
      provider: mockAuthProvider({
        eth_signTypedData_v4: () => {
          signAttempts += 1;
          // Valid-shaped ECDSA sig (r + s + v=0x1c): the terms-acceptance leg
          // of this path runs the signature through splitSignature, which
          // rejects a v byte outside {27,28} — unlike SIG constants used
          // elsewhere in this suite that never reach splitSignature.
          return "0x" + "11".repeat(32) + "22".repeat(32) + "1c";
        },
      }),
      config: { intakeUrl: "/spend", version: "0.5.0", chainId: 84_532, actionLabel: "Top up" },
      fetchFn: async () => ({ status: 200, json: async () => order }),
    };

    await assert.doesNotReject(setupAuthorization(deps, order, "oref-n2", null, get));

    assert.equal(elements.pay.hidden, true, "pay must not be enabled/shown for a broken enrichment state");
    assert.equal(elements.summary.textContent, MESSAGES.authorization_unavailable);
    assert.equal(elements.summary.dataset.state, "error");
    assert.equal(elements.pay.onclick, null, "no signing call must be reachable — onclick was never wired");
    assert.equal(signAttempts, 0);
  });
});
