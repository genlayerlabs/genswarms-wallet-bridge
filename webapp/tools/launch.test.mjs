import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chooseRoute } from "../lib/launch.mjs";

const HREF = "https://pay.example/wallet/go.html?order=ab&token=cd";

test("mobile UA routes into MetaMask's dapp browser with params intact", () => {
  const r = chooseRoute("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", HREF);
  assert.equal(r.mode, "mobile");
  assert.equal(r.target, "https://link.metamask.io/dapp/pay.example/wallet/index.html?order=ab&token=cd");
});

test("Android UA is mobile too", () => {
  assert.equal(chooseRoute("Mozilla/5.0 (Linux; Android 14)", HREF).mode, "mobile");
});

test("desktop UA routes straight to the dapp", () => {
  const r = chooseRoute("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", HREF);
  assert.equal(r.mode, "desktop");
  assert.equal(r.target, "https://pay.example/wallet/index.html?order=ab&token=cd");
});

test("a launcher URL without go.html still lands on index.html", () => {
  const r = chooseRoute("Mozilla/5.0 (Macintosh)", "https://pay.example/wallet/?order=ab");
  assert.equal(r.target, "https://pay.example/wallet/index.html?order=ab");
});

test("a custom dappLinkPrefix replaces the MetaMask default", () => {
  const r = chooseRoute("Mozilla/5.0 (iPhone)", HREF, "https://go.cb-w.com/dapp?cb_url=");
  assert.ok(r.target.startsWith("https://go.cb-w.com/dapp?cb_url="));
  const parsed = new URL(r.target);
  assert.equal(parsed.searchParams.get("token"), null);
  assert.equal(parsed.searchParams.get("cb_url"), "pay.example/wallet/index.html?order=ab&token=cd");
});

test("go.html uses a CSP-compatible external module", async () => {
  const html = await readFile(new URL("../go.html", import.meta.url), "utf8");
  assert.match(html, /script-src 'self'/);
  assert.match(html, /<script type="module" src="\.\/go\.mjs"><\/script>/);
  assert.doesNotMatch(html, /<script type="module">\s*\n/);
});
