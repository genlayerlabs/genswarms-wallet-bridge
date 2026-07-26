import { test } from "node:test";
import assert from "node:assert/strict";
import { authorizationBrief, briefLines, formatExpiry, formatUnits } from "../lib/signing-brief.mjs";

const CONFIG = { tokenName: "USDC", productName: "Wingston" };
const TREASURY = "0x1f8D48380f88D12a3B702701A9cd4D93948EC160";
const NOW = new Date("2026-07-26T21:00:00Z");

const order = (overrides = {}) => ({
  kind: "authorization",
  to: TREASURY,
  value: 1000000,
  valid_before: Math.floor(NOW.getTime() / 1000) + 900,
  ...overrides,
});

test("base units become money", () => {
  assert.equal(formatUnits(1000000), "1.00");
  assert.equal(formatUnits(1500000), "1.50");
  assert.equal(formatUnits(250000), "0.25");
  assert.equal(formatUnits(0), "0.00");
  assert.equal(formatUnits(1000000000000000000n, 18), "1.00", "decimals are not hardcoded to six");
});

test("expiry is stated as remaining time, never as a unix timestamp", () => {
  const in15 = formatExpiry(Math.floor(NOW.getTime() / 1000) + 900, NOW);
  assert.match(in15.label, /expires in 15 minutes \(/);
  assert.doesNotMatch(in15.label, /\d{10}/, "the raw timestamp must not leak into the copy");

  assert.match(formatExpiry(Math.floor(NOW.getTime() / 1000) + 30, NOW).label, /under a minute/);
  assert.match(formatExpiry(Math.floor(NOW.getTime() / 1000) + 90, NOW).label, /in 1 minute/);
  assert.equal(formatExpiry(Math.floor(NOW.getTime() / 1000) - 1, NOW).label, "expired");
  assert.equal(formatExpiry(undefined, NOW), null);
  assert.equal(formatExpiry(0, NOW), null);
});

test("the brief restates the wallet's own raw number and what it means", () => {
  const brief = authorizationBrief(order(), CONFIG, NOW);

  assert.equal(brief.amount, "1.00");
  assert.equal(brief.rawValue, "1000000", "the exact string the wallet prints, for character-by-character comparison");
  assert.equal(brief.destination, TREASURY, "the FULL address — a truncated one cannot be compared");

  const raw = briefLines(brief, "Wingston").find((l) => l.key === "raw").text;
  assert.match(raw, /value 1000000/);
  assert.match(raw, /1\.00 USDC/);
  assert.match(raw, /6 decimals/);
});

test("the brief says a signature is not a payment, and what happens after", () => {
  const lines = briefLines(authorizationBrief(order(), CONFIG, NOW), "Wingston");
  const text = lines.map((l) => l.text).join(" ");

  assert.match(text, /signature, not a payment/);
  assert.match(text, /once/, "single use is the reassurance that makes signing safe to do");
  assert.match(text, /pay the network fee/);
  assert.match(lines.find((l) => l.key === "next").text, /confirm in the chat/);
});

test("a terms-gated order announces that TWO signatures are coming", () => {
  const gated = authorizationBrief(order({ terms: { required: true } }), CONFIG, NOW);
  assert.deepEqual(gated.steps, { current: 1, total: 2 });

  const first = briefLines(gated, "Wingston")[0];
  assert.equal(first.key, "steps", "the step count leads — it reframes everything below it");
  assert.match(first.text, /Step 1 of 2/);

  const plain = authorizationBrief(order(), CONFIG, NOW);
  assert.equal(plain.steps, null);
  assert.equal(briefLines(plain, "Wingston")[0].key, "headline", "no invented step count when there is one signature");
});

test("an order with no signable fields yet has NO brief (half a brief states nonsense)", () => {
  assert.equal(authorizationBrief(order({ to: undefined }), CONFIG, NOW), null);
  assert.equal(authorizationBrief(order({ value: undefined }), CONFIG, NOW), null);
  assert.equal(authorizationBrief(null, CONFIG, NOW), null);
  assert.deepEqual(briefLines(null, "Wingston"), []);
});

test("the destination is named when the deployment has a product name, generic when not", () => {
  const brief = authorizationBrief(order(), CONFIG, NOW);
  assert.match(briefLines(brief, "Wingston")[0].text, /to Wingston's wallet$/);
  assert.match(briefLines(brief, null)[0].text, /to the destination wallet$/);
});

test("the token label falls back to the token's own domain name before it gives up", () => {
  const withDomain = order({ domain: { name: "USDC", version: "2" } });

  assert.equal(authorizationBrief(withDomain, { tokenName: "USDC" }, NOW).token, "USDC");
  assert.equal(
    authorizationBrief(withDomain, {}, NOW).token,
    "USDC",
    "the EIP-712 domain name is the string the wallet itself will print",
  );
  assert.equal(authorizationBrief(order(), {}, NOW).token, "tokens", "last resort only");
});
