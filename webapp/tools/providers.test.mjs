import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { discoverProviders, needsChoice, LEGACY_RDNS } from "../lib/providers.mjs";

// A minimal EventTarget stand-in that also plays the wallets' part: whatever
// is queued in `announce` is dispatched in response to the page's request,
// exactly as an extension would.
function fakeWindow(announce = []) {
  const target = new EventTarget();
  target.addEventListener("eip6963:requestProvider", () => {
    for (const detail of announce) {
      target.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail }));
    }
  });
  return target;
}

const wallet = (rdns, name) => ({
  info: { uuid: `uuid-${rdns}`, rdns, name, icon: "data:image/svg+xml;base64,PHN2Zy8+" },
  provider: { request: async () => [] },
});

// Announcements arrive asynchronously with no "that's all" signal, so the
// timeout is the only thing that ends discovery. Kept at 0 here so the tests
// do not pay for it.
const fast = { timeoutMs: 0 };

test("every announcing wallet is listed, so the user can pick", async () => {
  const target = fakeWindow([wallet("io.rabby", "Rabby"), wallet("io.metamask", "MetaMask")]);
  const found = await discoverProviders({ target, ...fast });

  assert.deepEqual(
    found.map((p) => p.info.rdns),
    ["io.metamask", "io.rabby"],
    "sorted by name so the list does not reorder itself between loads",
  );
  assert.equal(needsChoice(found), true);
});

test("a wallet that announces twice is listed once (rdns, not uuid, is the identity)", async () => {
  const twice = [wallet("io.rabby", "Rabby"), wallet("io.rabby", "Rabby")];
  const found = await discoverProviders({ target: fakeWindow(twice), ...fast });

  assert.equal(found.length, 1);
  assert.equal(needsChoice(found), false, "one wallet is not a choice — do not ask");
});

test("the legacy injected slot is a LAST RESORT, never a peer of an announcer", async () => {
  const injected = { request: async () => [] };

  const withAnnouncer = await discoverProviders({
    target: fakeWindow([wallet("io.rabby", "Rabby")]),
    injected,
    ...fast,
  });
  assert.deepEqual(
    withAnnouncer.map((p) => p.info.rdns),
    ["io.rabby"],
    "the announcer IS the injected wallet — listing both would offer the same wallet twice",
  );

  const legacyOnly = await discoverProviders({ target: fakeWindow([]), injected, ...fast });
  assert.equal(legacyOnly.length, 1);
  assert.equal(legacyOnly[0].rdns, undefined);
  assert.equal(legacyOnly[0].info.rdns, LEGACY_RDNS);
  assert.equal(legacyOnly[0].provider, injected);
});

test("no wallet anywhere is an empty list, not a crash", async () => {
  assert.deepEqual(await discoverProviders({ target: fakeWindow([]), ...fast }), []);
  assert.deepEqual(await discoverProviders({ ...fast }), []);
  assert.equal(needsChoice([]), false);
  assert.equal(needsChoice(undefined), false);
});

test("a malformed announcement is ignored rather than offered as a wallet", async () => {
  const target = fakeWindow([
    { info: { rdns: "io.broken", name: "No provider" } },
    { provider: { request: async () => [] } },
    { info: { rdns: "", name: "Blank" }, provider: { request: async () => [] } },
    { info: { rdns: "io.ok", name: "Fine" }, provider: { request: async () => [] } },
  ]);

  const found = await discoverProviders({ target, ...fast });
  assert.deepEqual(
    found.map((p) => p.info.rdns),
    ["io.ok"],
  );
});

test("discovery stops listening once it returns (a late announcement cannot mutate the result)", async () => {
  const target = new EventTarget();
  const found = await discoverProviders({ target, ...fast });
  assert.deepEqual(found, []);

  // No listener should remain; if one did, this would populate a live Map
  // behind the caller's back.
  target.dispatchEvent(
    new CustomEvent("eip6963:announceProvider", { detail: wallet("io.late", "Late") }),
  );
  assert.deepEqual(found, []);
});

test("the picker's icons are admitted by the page's own CSP", async () => {
  // Wallet icons are data: URIs. A stricter img-src would render the list as
  // broken images and make the choice harder, not easier.
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /img-src 'self' data:/);
  assert.match(html, /id="wallet-picker"/);
});
