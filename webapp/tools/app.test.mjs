import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { MESSAGES, entryRef, paintStatus, showTermsPrompt } from "../app.mjs";

const ACCOUNT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const HASH = "0x" + "11".repeat(32);

function fakeDom() {
  const elements = {
    terms: { hidden: true },
    "terms-link": { href: "" },
    "terms-accept": { disabled: false, onclick: null },
    pay: { hidden: false, disabled: false },
    manual: { hidden: false },
    "manual-address": { textContent: "" },
    "manual-amount": { textContent: "" },
    status: { textContent: "", dataset: {} },
  };
  return { elements, get: (id) => elements[id] };
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
