import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { MESSAGES, RETURN_DELAY_S, askWhichWallet, entryRef, paintStatus, renderAuthorizationScreen, renderBrief, scheduleReturn, setupAuthorization, setupSelfAuthorization, setupUserTx, showTermsPrompt } from "../app.mjs";

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
    "funds-actions": { hidden: true },
    "funds-recheck": { disabled: false, onclick: null },
    "funds-sign-anyway": { disabled: false, onclick: null },
    manual: { hidden: false },
    "manual-address": { textContent: "" },
    "manual-amount": { textContent: "" },
    status: { textContent: "", dataset: {} },
    brief: { hidden: true },
    "brief-steps": { textContent: "", hidden: true },
    "brief-headline": { textContent: "" },
    "brief-destination": { textContent: "" },
    "brief-nature": { textContent: "" },
    "brief-raw": { textContent: "" },
    "brief-expiry": { textContent: "", hidden: true },
    "brief-next": { textContent: "", hidden: true },
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

test("the brief REPLACES the one-line summary rather than repeating it", () => {
  const { elements, get } = fakeDom();
  const deps = { config: { tokenName: "USDC", productName: "Wingston", actionLabel: "Top up" } };

  renderAuthorizationScreen(deps, { kind: "authorization", to: TREASURY, value: 1000000, valid_before: 4102444800 }, get);

  assert.equal(elements.summary.textContent, "", "the same facts twice, one of them with a truncated address");
  assert.equal(elements.brief.hidden, false);
});

test("with terms pending there is no brief, so the summary still carries the message", () => {
  const { elements, get } = fakeDom();
  const deps = { config: { tokenName: "USDC", actionLabel: "Top up" } };

  renderAuthorizationScreen(deps, { kind: "authorization", amount: 1000000, terms: { required: true } }, get);

  assert.match(elements.summary.textContent, /accept the terms/);
  assert.equal(elements.brief.hidden, true);
});

test("the summary is EMPTIED, never hidden — dead states paint their error into it", async () => {
  const src = await readFile(new URL("../app.mjs", import.meta.url), "utf8");
  const fn = src.slice(src.indexOf("export function renderAuthorizationScreen"));
  const body = fn.slice(0, fn.indexOf("\n}"));
  assert.doesNotMatch(body, /get\("summary"\)\.hidden/);
});

test("the pre-signature brief renders the full destination, not a truncation", () => {
  const { elements, get } = fakeDom();
  const brief = renderBrief(
    { kind: "authorization", to: TREASURY, value: 1000000, valid_before: 4102444800 },
    { tokenName: "USDC", productName: "Wingston" },
    get,
  );

  assert.ok(brief);
  assert.equal(elements.brief.hidden, false);
  assert.equal(
    elements["brief-destination"].textContent,
    TREASURY,
    "the address the user compares against the wallet must be complete",
  );
  assert.match(elements["brief-raw"].textContent, /value 1000000/);
  assert.equal(elements["brief-next"].hidden, false);
  assert.equal(elements["brief-steps"].hidden, true, "one signature: no step counter");
});

test("an order still waiting on terms shows NO brief at all", () => {
  const { elements, get } = fakeDom();

  assert.equal(renderBrief({ kind: "authorization" }, { tokenName: "USDC" }, get), null);
  assert.equal(elements.brief.hidden, true, "hidden, not half-filled");
  assert.equal(elements["brief-next"].hidden, true);
});

// Returning to the chat after a successful payment.
function fakeStatusDom(text = "Payment submitted ✓ — you can return to the chat.") {
  const elements = { status: { textContent: text, dataset: { state: "success" } } };
  return { elements, get: (id) => elements[id] };
}

// A setTimeout stand-in that runs pending callbacks on demand, so the test
// spends no wall-clock waiting for a countdown it is asserting about.
function manualClock() {
  const queue = [];
  const setTimeoutFn = (fn) => queue.push(fn);
  const runAll = () => {
    while (queue.length) queue.shift()();
  };
  return { setTimeoutFn, runAll, pending: () => queue.length };
}

test("a successful payment counts down and then closes the Telegram view", () => {
  const { elements, get } = fakeStatusDom();
  const clock = manualClock();
  let closed = 0;

  const armed = scheduleReturn({ close: () => (closed += 1) }, get, clock.setTimeoutFn);

  assert.equal(armed, true);
  assert.match(elements.status.textContent, new RegExp(`Returning to the chat in ${RETURN_DELAY_S}…$`));
  assert.match(elements.status.textContent, /Payment submitted ✓/, "the confirmation stays readable");
  assert.equal(closed, 0, "it does not close before the countdown runs out");

  clock.runAll();

  assert.equal(closed, 1, "closed exactly once");
  assert.match(elements.status.textContent, /Returning to the chat in 1…$/, "the last frame counted down to 1");
});

test("outside Telegram nothing is scheduled — a page cannot close a tab it did not open", () => {
  const { elements, get } = fakeStatusDom("Payment submitted ✓");
  const clock = manualClock();

  assert.equal(scheduleReturn(undefined, get, clock.setTimeoutFn), false);
  assert.equal(scheduleReturn({}, get, clock.setTimeoutFn), false, "a Telegram object with no close() is not a way out");
  assert.equal(clock.pending(), 0);
  assert.equal(elements.status.textContent, "Payment submitted ✓", "the status text is left alone");
});

// The wallet picker's whole job is that the wallet the user TAPS is the one
// that gets asked to sign. A picker that renders correctly and then resolves
// with the wrong provider would move the payment to the account the user was
// trying to avoid — silently, since both wallets can sign.
function fakePickerDom() {
  const make = () => {
    const node = {
      children: [],
      hidden: false,
      textContent: "",
      appendChild(child) {
        this.children.push(child);
        return child;
      },
      addEventListener(_event, handler) {
        this.onclick = handler;
      },
    };
    return node;
  };

  const elements = { "wallet-picker": make(), "wallet-list": make() };
  const doc = { createElement: () => make(), createTextNode: (text) => ({ text }) };
  return { elements, get: (id) => elements[id], doc };
}

test("the picker resolves with the provider of the wallet the user taps", async () => {
  const rabby = { request: async () => ["0xrabby"] };
  const metamask = { request: async () => ["0xmetamask"] };
  const { elements, get, doc } = fakePickerDom();

  const chosen = askWhichWallet(
    [
      { info: { rdns: "io.metamask", name: "MetaMask" }, provider: metamask },
      { info: { rdns: "io.rabby", name: "Rabby" }, provider: rabby },
    ],
    get,
    doc,
  );

  const list = elements["wallet-list"];
  assert.equal(list.children.length, 2, "one row per wallet");
  assert.equal(elements["wallet-picker"].hidden, false, "the picker is shown while it waits");

  // Tap the SECOND wallet, not the first — a picker that always returned
  // wallets[0] would pass a one-wallet test.
  list.children[1].children[0].onclick();

  assert.equal(await chosen, rabby);
  assert.equal(elements["wallet-picker"].hidden, true, "the picker closes once chosen");
});

test("re-rendering the picker does not stack rows from a previous render", () => {
  const { elements, get, doc } = fakePickerDom();
  const wallets = [{ info: { rdns: "io.rabby", name: "Rabby" }, provider: { request: async () => [] } }];

  askWhichWallet(wallets, get, doc);
  askWhichWallet(wallets, get, doc);

  assert.equal(elements["wallet-list"].textContent, "", "the list is cleared before rendering");
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

test("funds warning actions are present and initially hidden", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /<div id="funds-actions" hidden>/);
  assert.match(html, /<button id="funds-recheck"[^>]*>Re-check<\/button>/);
  assert.match(html, /<button id="funds-sign-anyway"[^>]*>Sign anyway<\/button>/);
});

test("user transaction Re-check clears a token warning without opening the wallet", async () => {
  const { elements, get } = fakeDom();
  const order = {
    order_ref: "r1",
    kind: "user_tx",
    amount: 1_000_000,
    expires_at: 9_999_999_999,
    chain_id: 84_532,
    tx: { to: TREASURY, data: "0x", value: 0 },
    display: {},
  };
  let tokenBalance = "0x7a120";
  let sends = 0;
  const deps = {
    provider: mockAuthProvider({
      eth_call: () => tokenBalance,
      eth_getBalance: () => "0x9184e72a000",
      eth_sendTransaction: () => {
        sends += 1;
        return HASH;
      },
    }),
    config: {
      intakeUrl: "/spend",
      version: "0.10.0",
      chainId: 84_532,
      token: TREASURY,
      tokenName: "USDC",
    },
    fetchFn: async () => ({ status: 200, json: async () => order }),
  };

  await setupUserTx(deps, order, "r1", null, get);
  await elements.pay.onclick();

  assert.equal(elements.pay.hidden, true);
  assert.equal(elements["funds-actions"].hidden, false);
  assert.match(elements.status.textContent, /0\.50 USDC.*1\.00 USDC/);
  assert.equal(elements.status.dataset.state, "warning");
  assert.equal(sends, 0);

  tokenBalance = "0xf4240";
  await elements["funds-recheck"].onclick();

  assert.equal(elements["funds-actions"].hidden, true);
  assert.equal(elements.pay.hidden, false);
  assert.equal(elements.pay.disabled, false);
  assert.equal(elements.status.dataset.state, undefined);
  assert.equal(sends, 0);
});

test("user transaction gas warning renders before wallet send", async () => {
  const { elements, get } = fakeDom();
  const order = {
    order_ref: "r1",
    kind: "user_tx",
    amount: 0,
    expires_at: 9_999_999_999,
    chain_id: 84_532,
    tx: { to: TREASURY, data: "0x", value: 0 },
    display: {},
  };
  let sends = 0;
  const deps = {
    provider: mockAuthProvider({
      eth_getBalance: () => "0x0",
      eth_sendTransaction: () => {
        sends += 1;
        return HASH;
      },
    }),
    config: { intakeUrl: "/spend", version: "0.10.0", chainId: 84_532, token: TREASURY },
    fetchFn: async () => ({ status: 200, json: async () => order }),
  };

  await setupUserTx(deps, order, "r1", null, get);
  await elements.pay.onclick();

  assert.equal(elements["funds-actions"].hidden, false);
  assert.match(elements.status.textContent, /too little ETH for gas/);
  assert.equal(elements.status.dataset.state, "warning");
  assert.equal(sends, 0);
});

test("user transaction Sign anyway performs one bypassed send", async () => {
  const { elements, get } = fakeDom();
  const order = {
    order_ref: "r1",
    kind: "user_tx",
    amount: 1_000_000,
    expires_at: 9_999_999_999,
    chain_id: 84_532,
    tx: { to: TREASURY, data: "0x", value: 0 },
    display: {},
  };
  let reads = 0;
  let sends = 0;
  const deps = {
    provider: mockAuthProvider({
      eth_call: () => {
        reads += 1;
        return "0x0";
      },
      eth_getBalance: () => "0x0",
      eth_sendTransaction: () => {
        sends += 1;
        return HASH;
      },
    }),
    config: {
      intakeUrl: "/spend",
      version: "0.10.0",
      chainId: 84_532,
      token: TREASURY,
      tokenName: "USDC",
    },
    fetchFn: async () => ({ status: 200, json: async () => order }),
  };

  await setupUserTx(deps, order, "r1", null, get);
  await elements.pay.onclick();
  await elements["funds-sign-anyway"].onclick();

  assert.equal(reads, 1);
  assert.equal(sends, 1);
  assert.equal(elements["funds-actions"].hidden, true);
  assert.match(elements.status.textContent, /^Transaction sent/);
  assert.equal(elements.status.dataset.state, "success");
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

    assert.match(elements["brief-headline"].textContent, /2\.00 USDC/);
    assert.equal(
      elements["brief-destination"].textContent,
      TREASURY,
      "the FULL destination, not the truncation the brief replaced",
    );
    assert.equal(elements.summary.textContent, "", "and not repeated in the summary above it");
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
            summaryAtSignTime.push(
              `${elements["brief-headline"].textContent} ${elements["brief-destination"].textContent}`,
            );
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
    assert.ok(
      summaryAtSignTime[0].includes(TREASURY),
      "the full destination must be visible at sign time",
    );
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

test("WB12: the self-submit screen shows the delegation error and never signs", async () => {
  const { elements, get } = fakeDom();
  const order = {
    kind: "authorization_self",
    amount: 1_000_000,
    to: TREASURY,
    value: 1_000_000,
    token: "0x000000000000000000000000000000000000aaaa",
    domain: {
      name: "USDC",
      version: "2",
      chainId: 84_532,
      verifyingContract: "0x000000000000000000000000000000000000aaaa",
    },
    nonce: "0x" + "ab".repeat(32),
    valid_after: 0,
    valid_before: 1_900_000_000,
    chain_id: 84_532,
  };
  let signatures = 0;
  const deps = {
    provider: mockAuthProvider({
      eth_getCode: () => "0xef0100" + "12".repeat(20),
      eth_signTypedData_v4: () => {
        signatures += 1;
        return "0x" + "11".repeat(65);
      },
    }),
    config: {
      intakeUrl: "/spend",
      version: "0.5.0",
      chainId: 84_532,
      actionLabel: "Top up",
    },
    fetchFn: async () => ({ status: 200, json: async () => order }),
  };

  await setupSelfAuthorization(deps, order, "oref-self", null, get);
  await elements.pay.onclick();

  assert.equal(elements.status.textContent, MESSAGES.wallet_has_code);
  assert.equal(
    elements.status.textContent,
    "Your wallet has an active delegation/contract code; EOA-style signing will be rejected by USDC — use the deposit option or remove the delegation.",
  );
  assert.equal(elements.status.dataset.state, "error");
  assert.equal(signatures, 0);
});

for (const [failure, submittedResponse] of [
  ["non-2xx", { status: 503, json: async () => ({ error: "unavailable" }) }],
  ["thrown fetch", null],
]) {
  test(`self-submit ${failure} report renders a sent-not-failed warning with the tx hash`, async () => {
    const { elements, get } = fakeDom();
    const txHash = "0x" + "ef".repeat(32);
    const order = {
      kind: "authorization_self",
      amount: 1_000_000,
      to: TREASURY,
      value: 1_000_000,
      token: "0x000000000000000000000000000000000000aaaa",
      domain: {
        name: "USDC",
        version: "2",
        chainId: 84_532,
        verifyingContract: "0x000000000000000000000000000000000000aaaa",
      },
      nonce: "0x" + "ab".repeat(32),
      valid_after: 0,
      valid_before: 1_900_000_000,
      chain_id: 84_532,
    };
    let closes = 0;
    let sends = 0;
    const deps = {
      provider: mockAuthProvider({
        eth_getCode: () => "0x",
        eth_signTypedData_v4: () => "0x" + "11".repeat(65),
        eth_sendTransaction: () => {
          sends += 1;
          return txHash;
        },
      }),
      config: {
        intakeUrl: "/spend",
        version: "0.5.0",
        chainId: 84_532,
        actionLabel: "Top up",
      },
      initData: "id-blob",
      fetchFn: async (url) => {
        if (url.endsWith("/orders/submitted")) {
          if (submittedResponse) return submittedResponse;
          throw new Error("report endpoint offline");
        }
        if (url.endsWith("/authorization/self")) {
          return {
            status: 200,
            json: async () => ({
              to: order.token,
              data: "0xcf092995" + "00".repeat(224),
              chain_id: order.chain_id,
              valid_before: order.valid_before,
            }),
          };
        }
        if (url.endsWith("/orders")) {
          return { status: 200, json: async () => order };
        }
        throw new Error(`unmocked fetch ${url}`);
      },
    };

    await setupSelfAuthorization(
      deps,
      order,
      "oref-self-report",
      { close: () => (closes += 1) },
      get,
    );
    await elements.pay.onclick();

    assert.equal(elements.status.dataset.state, "warning");
    assert.match(elements.status.textContent, /^Transaction sent, but reporting failed\./);
    assert.match(elements.status.textContent, new RegExp(txHash));
    assert.match(elements.status.textContent, /Do not send it again\./);
    assert.doesNotMatch(elements.status.textContent, /Payment failed|Transaction failed|try again|retry/i);
    assert.equal(elements.pay.disabled, true, "the sent transaction cannot be resubmitted");
    assert.equal(sends, 1);
    assert.equal(closes, 0, "the warning stays visible instead of auto-closing");
  });
}

test("authorization_self orders dispatch to the self-submit page flow", async () => {
  const src = await readFile(new URL("../app.mjs", import.meta.url), "utf8");

  assert.match(
    src,
    /kind === "authorization_self"\) return setupSelfAuthorization\(deps, fetched\.order, orderRef, tg\)/,
  );
});
