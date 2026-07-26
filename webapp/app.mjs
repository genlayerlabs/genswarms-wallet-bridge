// DOM glue for the wallet dapp. All decision logic lives in lib/flow.mjs
// (tested headlessly); this file only wires optional Telegram initData,
// the injected EIP-1193 provider, and the DOM elements.

import { applyProductName } from "./lib/brand.mjs";
import { acceptTerms, configDrift, connectWallet, fetchOrder, ownerMismatch, runAuthorizationFlow, runBindFlow, runPermitFlow, runUserTxFlow, shortAddress, termsRequired, walletDappLink, wrongWalletMessage } from "./lib/flow.mjs";

const $ = (id) => document.getElementById(id);

// Theme seam, state half: terminal outcomes stamp data-state="error" or
// "success" on the element they write to, so a theme can color them
// (#status[data-state="error"] { ... }); progress text carries no stamp.
// The neutral default theme leaves every state unstyled and copy never
// changes — without a themed selector this is visually inert.
export function paintStatus(el, text, state) {
  el.textContent = text;
  if (state) el.dataset.state = state;
  else delete el.dataset.state;
}

export const MESSAGES = {
  order_not_found: "This payment link expired or was already used. Go back to the chat and tap again.",
  unauthorized: "Could not verify your Telegram session. Reopen this page from the chat button.",
  version_mismatch: "This page is outdated. Close and reopen it from the chat.",
  user_rejected: "Signature declined — nothing was paid.",
  wrong_chain:
    "Your wallet is on the wrong network for this payment. Tap again and approve the network switch in your wallet.",
  no_account: "No wallet account connected.",
  expired: "This order expired. Go back to the chat and tap again.",
  config_drift: "This page's configuration is out of date (wrong network). Ask the operator to redeploy the wallet app.",
  geo_blocked: "This service isn't available in your region.",
  terms_stale: "The terms were updated — please review and accept the new version.",
};

function showManual(order, get = $) {
  const manual = order?.kind === "permit" && order.display?.manual;
  if (!manual) return;
  get("manual-address").textContent = manual.address;
  get("manual-amount").textContent = `Send exactly ${(manual.amount / 1_000_000).toFixed(2)} USDC on Base to:`;
  get("manual").hidden = false;
}

function enterGeoDeadState(target, get = $) {
  get("pay").hidden = true;
  get("terms").hidden = true;
  get("manual").hidden = true;
  get("terms-accept").disabled = true;
  paintStatus(target, MESSAGES.geo_blocked, "error");
}

export function showTermsPrompt(deps, { account, terms, ref, retry }, get = $, acceptFn = acceptTerms) {
  const box = get("terms");
  const button = get("terms-accept");
  const pay = get("pay");
  const status = get("status");
  let currentTerms = terms;

  get("manual").hidden = true;

  if (!account) {
    box.hidden = true;
    button.disabled = true;
    button.onclick = null;
    pay.hidden = false;
    pay.disabled = false;
    paintStatus(status, MESSAGES.no_account, "error");
    return;
  }

  get("terms-link").href = terms.url;
  box.hidden = false;
  pay.hidden = true;
  pay.disabled = true;
  button.disabled = false;

  button.onclick = async () => {
    button.disabled = true;
    paintStatus(status, "Waiting for your signature…");
    let result;
    try {
      result = await acceptFn(deps, { account, vHash: currentTerms.v_hash, ref });
    } catch (_) {
      result = { ok: false, reason: "request_failed" };
    }
    if (result.ok) {
      let refreshed;
      try {
        refreshed = await fetchOrder(deps, ref);
      } catch (_) {
        refreshed = { ok: false, reason: "request_failed" };
      }
      if (refreshed.ok && configDrift(refreshed.order, deps.config)) {
        box.hidden = true;
        pay.hidden = true;
        get("manual").hidden = true;
        button.disabled = true;
        paintStatus(status, MESSAGES.config_drift, "error");
        return;
      }
      if (refreshed.ok) showManual(refreshed.order, get);
      box.hidden = true;
      pay.hidden = false;
      await retry(refreshed);
    } else if (result.reason === "terms_stale") {
      currentTerms = result.terms;
      get("terms-link").href = currentTerms.url;
      paintStatus(status, MESSAGES.terms_stale, "error");
      button.disabled = false;
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState(status, get);
    } else {
      paintStatus(status, MESSAGES[result.reason] || `Terms acceptance failed (${result.reason}).`, "error");
      button.disabled = false;
    }
  };
}

async function main() {
  const tg = globalThis.Telegram && globalThis.Telegram.WebApp;
  const initData = tg ? tg.initData : "";
  const params = new URLSearchParams(location.search);
  const orderRef = entryRef(tg, params);
  const token = params.get("token") || "";

  const config = await (await fetch("./config.json")).json();
  applyProductName(document, config);
  const provider = globalThis.ethereum;

  if (!provider) {
    // Dead state: the pay button can never arm without a provider — hide it
    // so the open-in-wallet hint is the page's one action.
    $("pay").hidden = true;
    $("summary").textContent =
      "No wallet detected in this browser. On your phone? Tap below to open this page in MetaMask. On desktop? Open this chat on your phone and tap the button there.";
    const a = $("open-wallet");
    a.href = walletDappLink(location.href, config.dappLinkPrefix);
    a.hidden = false;
    return;
  }

  $("open-wallet").hidden = true;
  const deps = { provider, fetchFn: fetch.bind(globalThis), config, initData, token };

  const fetched = await fetchOrder(deps, orderRef);
  if (!fetched.ok) {
    // Dead state: no order to act on (expired / not found / stale build).
    if (fetched.reason === "geo_blocked") enterGeoDeadState($("summary"));
    else {
      $("pay").hidden = true;
      paintStatus($("summary"), MESSAGES[fetched.reason] || `Could not load the order (${fetched.reason}).`, "error");
    }
    return;
  }

  // Config drift dead state (fail CLOSED, before ANY wallet interaction —
  // every setup* path below may connect): the order carries the keeper's
  // runtime chain id; when the static config.json disagrees, the deployment
  // is inconsistent and nothing may be signed. Never auto-switch the wallet
  // to the order's chain — the config's token/router pins are stale too.
  if (configDrift(fetched.order, config)) {
    $("pay").hidden = true;
    paintStatus($("summary"), MESSAGES.config_drift, "error");
    return;
  }

  if (fetched.order.kind === "user_tx") return setupUserTx(deps, fetched.order, orderRef, tg);
  if (fetched.order.kind === "bind") return setupBind(deps, fetched.order, orderRef, tg);
  if (fetched.order.kind === "authorization") return setupAuthorization(deps, fetched.order, orderRef, tg);
  setupPermit(deps, fetched.order, orderRef, tg);
}

// Owner-bound orders (order.expected_owner, exposed by the intake view only
// when set): the paying wallet MUST be the bound one — payouts go to it, so a
// different connected account gets debited while someone else is credited
// (and owner-scoped calldata reverts on-chain). A mismatch is the 0.3.1
// dead-state pattern: hide #pay, stamp the error. The re-check inside each
// pay path is the load-bearing one (accounts change mid-session); this
// load-time pass and the accountsChanged listener just surface it early.
function blockWrongWallet(expected) {
  $("pay").hidden = true;
  paintStatus($("status"), wrongWalletMessage(expected), "error");
}

async function enforceOwnerAtLoad(deps, order) {
  if (!order.expected_owner) return true;
  if (typeof deps.provider.on === "function") {
    deps.provider.on("accountsChanged", (accounts) => {
      if (ownerMismatch(order, accounts && accounts[0])) blockWrongWallet(order.expected_owner);
    });
  }
  const conn = await connectWallet(deps).catch(() => ({ ok: false }));
  if (conn.ok && ownerMismatch(order, conn.account)) {
    blockWrongWallet(order.expected_owner);
    return false;
  }
  return true; // connect refusals stay non-fatal — the pay path re-checks
}

async function setupPermit(deps, order, orderRef, tg) {
  const amount = (order.amount / 1_000_000).toFixed(2);
  $("summary").textContent = `${deps.config.actionLabel}: ${amount} USDC (gasless — the operator pays network fees).`;
  showManual(order);
  if (!(await enforceOwnerAtLoad(deps, order))) return;
  $("pay").disabled = false;

  const run = async (fetched) => {
    $("pay").disabled = true;
    paintStatus($("status"), "Connecting wallet…");
    const result = await runPermitFlow(deps, orderRef, fetched);

    if (result.ok) {
      paintStatus($("status"), "Payment submitted ✓ — you can return to the chat.", "success");
      if (tg) setTimeout(() => tg.close(), 1500);
    } else if (result.reason === "wrong_wallet") {
      blockWrongWallet(result.expected);
    } else if (result.reason === "terms_required") {
      showTermsPrompt(deps, { account: result.account, terms: result.terms, ref: orderRef, retry: run });
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState($("status"));
    } else {
      paintStatus($("status"), MESSAGES[result.reason] || `Payment failed (${result.reason}). Nothing was charged — reopen this page from the chat button to retry, or use the manual send option below if shown.`, "error");
      $("pay").disabled = false;
    }
  };
  $("pay").onclick = () => run();
}

// The authorization (EIP-3009) lane: same skeleton as setupPermit — a
// gasless signature, not a wallet-sent transaction — but the destination and
// amount are shown UP FRONT and prominently: the user must see where the
// money goes before the wallet's own signing prompt ever appears.
//
// `order.to`/`order.value` are WITHHELD by the server
// (`DelegatedSpend.Intake.handle_order/3`) until the current terms are
// accepted — exactly like `user_tx`'s `tx` — while `order.amount` never is
// (review C1: this used to read `order.value`, which is `undefined` in the
// terms-pending state, throwing before the terms prompt could ever be
// reached and permanently bricking the page for every first-time user on a
// compliance-enabled deployment). So the destination line is composed ONLY
// once `termsRequired(order)` is false; the terms-pending case shows the
// amount alone and defers the destination + signing to the first pay click,
// whose `runAuthorizationFlow` re-fetch surfaces `terms_required` and opens
// the very same `showTermsPrompt` every other lane uses.
//
// `get` defaults to the real DOM accessor and is threaded through (instead
// of the module-level `$`) so this function is unit-testable with a fake
// DOM — see webapp/tools/app.test.mjs.
export async function setupAuthorization(deps, order, orderRef, tg, get = $) {
  const amount = (order.amount / 1_000_000).toFixed(2);
  get("summary").textContent = termsRequired(order)
    ? `${deps.config.actionLabel}: ${amount} USDC — accept the terms to see the destination and pay.`
    : `${deps.config.actionLabel}: ${amount} USDC to ${shortAddress(order.to)} ` +
      `(gasless — the operator pays network fees).`;
  if (!(await enforceOwnerAtLoad(deps, order))) return;
  get("pay").disabled = false;

  const run = async (fetched) => {
    get("pay").disabled = true;
    paintStatus(get("status"), "Connecting wallet…");
    const result = await runAuthorizationFlow(deps, orderRef, fetched);

    if (result.ok) {
      paintStatus(get("status"), "Payment submitted ✓ — you can return to the chat.", "success");
      if (tg) setTimeout(() => tg.close(), 1500);
    } else if (result.reason === "wrong_wallet") {
      blockWrongWallet(result.expected);
    } else if (result.reason === "terms_required") {
      showTermsPrompt(deps, { account: result.account, terms: result.terms, ref: orderRef, retry: run }, get);
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState(get("status"), get);
    } else {
      paintStatus(get("status"), MESSAGES[result.reason] || `Payment failed (${result.reason}). Nothing was charged — reopen this page from the chat button to retry.`, "error");
      get("pay").disabled = false;
    }
  };
  get("pay").onclick = () => run();
}

async function setupUserTx(deps, order, orderRef, tg) {
  $("summary").textContent = summaryLines(order);
  $("pay").textContent = "Review & sign in wallet";
  if (!(await enforceOwnerAtLoad(deps, order))) return;
  $("pay").disabled = false;
  const run = async (fetched) => {
    $("pay").disabled = true;
    paintStatus($("status"), "Opening wallet…");
    const result = await runUserTxFlow(deps, orderRef, fetched);
    if (result.ok) {
      paintStatus($("status"), "Transaction sent ✓ — you can return to the chat.", "success");
      if (tg) setTimeout(() => tg.close(), 1500);
    } else if (result.reason === "wrong_wallet") {
      blockWrongWallet(result.expected);
    } else if (result.reason === "terms_required") {
      showTermsPrompt(deps, { account: result.account, terms: result.terms, ref: orderRef, retry: run });
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState($("status"));
    } else {
      paintStatus($("status"), MESSAGES[result.reason] || `Transaction failed (${result.reason}).`, "error");
      $("pay").disabled = false;
    }
  };
  $("pay").onclick = () => run();
}

function setupBind(deps, order, bindRef, tg) {
  $("summary").textContent = order.current_wallet
    ? `Connected wallet on file: ${order.current_wallet} — connect to change it.`
    : "No wallet on file yet.";
  $("pay").textContent = "Connect wallet";
  $("pay").disabled = false;
  const run = async (fetched) => {
    $("pay").disabled = true;
    paintStatus($("status"), "Connecting wallet…");
    const result = await runBindFlow(deps, bindRef, fetched);
    if (result.ok) {
      paintStatus($("status"), "Wallet bound ✓ — you can return to the chat.", "success");
      if (tg) setTimeout(() => tg.close(), 1500);
    } else if (result.reason === "terms_required") {
      showTermsPrompt(deps, { account: result.account, terms: result.terms, ref: bindRef, retry: run });
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState($("status"));
    } else {
      paintStatus($("status"), MESSAGES[result.reason] || `Wallet bind failed (${result.reason}).`, "error");
      $("pay").disabled = false;
    }
  };
  $("pay").onclick = () => run();
}

function summaryLines(order) {
  const lines = order.display && order.display.summary_lines;
  return Array.isArray(lines) && lines.length ? lines.join("\n") : "Review this transaction in your wallet.";
}

export function entryRef(tg, params) {
  return (tg && tg.initDataUnsafe && tg.initDataUnsafe.start_param) || params.get("order") || params.get("bind");
}

// Fatal-error backstop (review C1): `main()` had no `.catch()`, so ANY
// uncaught throw along the way (a malformed order shape, a config.json
// parse failure, …) left the page silently stuck on "Loading order…" with
// #pay disabled forever — no in-dapp signal, no way for the user to tell a
// bug from a slow network. This is the same "dead end with no workaround"
// bug class as C1 itself, one layer further out; every other failure path
// in this file already ends in a typed, visible status.
export function handleFatalError(err, get = $) {
  console.error(err);
  const pay = get("pay");
  if (pay) pay.hidden = true;
  const summary = get("summary");
  if (summary) {
    paintStatus(summary, "Something went wrong loading this page. Reopen it from the chat button.", "error");
  }
}

if (typeof document !== "undefined") main().catch(handleFatalError);
