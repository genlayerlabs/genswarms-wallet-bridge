// DOM glue for the wallet dapp. All decision logic lives in lib/flow.mjs
// (tested headlessly); this file only wires optional Telegram initData,
// the injected EIP-1193 provider, and the DOM elements.

import { applyProductName, productName } from "./lib/brand.mjs";
import { authorizationBrief, briefLines, formatUnits } from "./lib/signing-brief.mjs";
import { discoverProviders, needsChoice } from "./lib/providers.mjs";
import { acceptTerms, configDrift, connectWallet, fetchOrder, ownerMismatch, preflightFunds, runAuthorizationFlow, runBindFlow, runPermitFlow, runSelfAuthorizationFlow, runUserTxFlow, shortAddress, termsRequired, walletDappLink, wrongWalletMessage } from "./lib/flow.mjs";

const $ = (id) => document.getElementById(id);

// Theme seam, state half: terminal outcomes stamp data-state="error",
// "warning", or "success" on the element they write to, so a theme can color them
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
  // An authentic-but-stale link: the ONE wrong move is re-opening the same
  // page (it will never work again) — say what to do instead. Nothing was
  // signed and nothing was charged.
  link_expired:
    "This payment link has expired — nothing was charged. Send /topup in the chat for a fresh one.",
  // The node refused our broadcast (e.g. the relayer can't cover the network
  // fee right now). The user's signature cost them nothing.
  submit_rejected:
    "We couldn't submit your payment to the network — nothing was charged. Try /topup again in a few minutes.",
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
  authorization_unavailable: "This payment link isn't active — please ask for a new one.",
  wallet_has_code:
    "Your wallet has an active delegation/contract code; EOA-style signing will be rejected by USDC — use the deposit option or remove the delegation.",
  code_check_failed:
    "We couldn't verify whether this wallet can use EOA-style signing. Try again, or use the deposit option.",
};

// How long a finished payment stays on screen before the page returns the
// user to the chat. Long enough to READ the confirmation — the previous 1.5s
// closed the window before most people finished the sentence, which reads as
// "it vanished", not as "it worked".
export const RETURN_DELAY_S = 5;

// Closes the Telegram web view after a successful payment, counting down so
// the close is expected rather than abrupt.
//
// ONLY inside Telegram. In an ordinary browser tab there is nothing to call:
// a page cannot close a tab it did not itself open, so the user closes it. It
// is never called on a failure — an error the user cannot finish reading is
// worse than a tab left open.
export function scheduleReturn(tg, get = $, setTimeoutFn = setTimeout) {
  if (!tg || typeof tg.close !== "function") return false;

  const status = get("status");
  const done = status.textContent;
  let left = RETURN_DELAY_S;

  const tick = () => {
    if (left <= 0) {
      tg.close();
      return;
    }

    status.textContent = `${done} Returning to the chat in ${left}…`;
    left -= 1;
    setTimeoutFn(tick, 1000);
  };

  tick();
  return true;
}

// Renders one button per discovered wallet and resolves with the provider the
// user taps. Nothing else on the page arms until then: the choice decides who
// gets asked to sign, so it cannot be a change made after the fact.
export function askWhichWallet(wallets, get = $, doc = document) {
  const picker = get("wallet-picker");
  const list = get("wallet-list");
  list.textContent = "";

  return new Promise((resolve) => {
    for (const { info, provider } of wallets) {
      const item = doc.createElement("li");
      const button = doc.createElement("button");
      button.type = "button";

      if (info.icon) {
        const icon = doc.createElement("img");
        icon.src = info.icon;
        icon.alt = "";
        button.appendChild(icon);
      }

      button.appendChild(doc.createTextNode(info.name || info.rdns));
      button.addEventListener("click", () => {
        picker.hidden = true;
        resolve(provider);
      });

      item.appendChild(button);
      list.appendChild(item);
    }

    picker.hidden = false;
  });
}

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

export function showTermsPrompt(deps, { account, terms, ref, retry, renderSummary }, get = $, acceptFn = acceptTerms) {
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
      // N1 fix: the enriched order is exactly what just arrived from the
      // re-fetch above — recompose the summary from it BEFORE retry() can
      // reach the signing step, so a lane whose summary depends on
      // server-served fields (destination, amount) never signs while still
      // showing the terms-pending copy. No-op for lanes that don't need it.
      if (refreshed.ok && typeof renderSummary === "function") renderSummary(refreshed.order);
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

  // Which wallet pays is the USER's call when more than one is installed.
  // Reading `globalThis.ethereum` alone would hand the payment to whichever
  // extension won the injection race — invisible, unchangeable, and wrong
  // whenever the funds are in the other one.
  const wallets = await discoverProviders({ target: globalThis, injected: globalThis.ethereum });
  const provider = needsChoice(wallets) ? await askWhichWallet(wallets) : wallets[0]?.provider;

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
  if (fetched.order.kind === "authorization_self") return setupSelfAuthorization(deps, fetched.order, orderRef, tg);
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
// `get` defaults to the real DOM accessor (M9: threaded through so lanes that
// pass their own `get` — e.g. setupAuthorization's fake-DOM tests — can reach
// this branch too; production is unaffected since every existing caller keeps
// the default).
function blockWrongWallet(expected, get = $) {
  get("pay").hidden = true;
  paintStatus(get("status"), wrongWalletMessage(expected), "error");
}

async function enforceOwnerAtLoad(deps, order, get = $) {
  if (!order.expected_owner) return true;
  if (typeof deps.provider.on === "function") {
    deps.provider.on("accountsChanged", (accounts) => {
      if (ownerMismatch(order, accounts && accounts[0])) blockWrongWallet(order.expected_owner, get);
    });
  }
  const conn = await connectWallet(deps).catch(() => ({ ok: false }));
  if (conn.ok && ownerMismatch(order, conn.account)) {
    blockWrongWallet(order.expected_owner, get);
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
      scheduleReturn(tg);
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
//
// (review N1) The destination line only means anything once `order.to` is
// actually present, and that happens at TWO points in time: first paint when
// terms are already accepted, and — for a first-time user — right after
// `showTermsPrompt`'s post-acceptance re-fetch. Both call the same
// `authorizationSummaryText`, so the promised copy ("accept the terms to see
// the destination and pay") is never left stale once it has been kept.
function authorizationSummaryText(deps, order) {
  const amount = (order.amount / 1_000_000).toFixed(2);
  return termsRequired(order)
    ? `${deps.config.actionLabel}: ${amount} USDC — accept the terms to see the destination and pay.`
    : `${deps.config.actionLabel}: ${amount} USDC to ${shortAddress(order.to)} ` +
      `(gasless — the operator pays network fees).`;
}

// Fills the pre-signature brief. Every line is derived from the order the
// server served, never from anything typed here, so what the page promises is
// what the wallet will be handed.
//
// Hidden — not emptied — when there is no brief: an order still waiting on
// terms has no signable fields yet, and half a brief is worse than none.
export function renderBrief(order, config, get = $, now = new Date()) {
  const brief = authorizationBrief(order, config, now);
  const section = get("brief");
  const next = get("brief-next");

  if (!brief) {
    section.hidden = true;
    next.hidden = true;
    return null;
  }

  const lines = new Map(briefLines(brief, productName(config)).map((line) => [line.key, line.text]));

  for (const key of ["headline", "destination", "nature", "raw"]) {
    get(`brief-${key}`).textContent = lines.get(key) || "";
  }

  for (const key of ["steps", "expiry", "next"]) {
    const el = get(`brief-${key}`);
    const text = lines.get(key);
    el.textContent = text || "";
    el.hidden = !text;
  }

  section.hidden = false;
  return brief;
}

// (review N2) `to`/`domain`/`nonce` are withheld ONLY while the current terms
// are unaccepted (see above). If they are missing for any OTHER reason — a
// config-drifted restart that lands the keeper back on a permit-only build is
// the proven case (probe P8) — `shortAddress`'s falsy guard would otherwise
// render a fabricated destination ("to an address") with pay enabled, walking
// the user into a wallet prompt for structurally invalid typed data
// (`domain: undefined`). An honest failure beats a plausible page.
function authorizationEnrichmentMissing(order) {
  return !termsRequired(order) && (!order.to || !order.domain || !order.nonce);
}

// The brief SUPERSEDES the one-line summary — same facts, but with the full
// destination instead of a truncated one. Rendering both says everything
// twice and puts back the shortened address the brief exists to replace.
//
// The summary is emptied rather than hidden: the geo-blocked and
// enrichment-missing dead states paint their message into this same element,
// and an error written into a hidden element is an error the user never sees.
export function renderAuthorizationScreen(deps, order, get = $) {
  const brief = renderBrief(order, deps.config, get);
  get("summary").textContent = brief ? "" : authorizationSummaryText(deps, order);
  return brief;
}

export async function setupAuthorization(deps, order, orderRef, tg, get = $) {
  if (authorizationEnrichmentMissing(order)) {
    get("pay").hidden = true;
    paintStatus(get("summary"), MESSAGES.authorization_unavailable, "error");
    return;
  }

  renderAuthorizationScreen(deps, order, get);
  if (!(await enforceOwnerAtLoad(deps, order, get))) return;
  get("pay").disabled = false;

  const run = async (fetched) => {
    get("pay").disabled = true;
    paintStatus(get("status"), "Connecting wallet…");
    const result = await runAuthorizationFlow(deps, orderRef, fetched);

    if (result.ok) {
      paintStatus(get("status"), "Payment submitted ✓ — you can return to the chat.", "success");
      scheduleReturn(tg, get);
    } else if (result.reason === "wrong_wallet") {
      blockWrongWallet(result.expected, get);
    } else if (result.reason === "terms_required") {
      showTermsPrompt(
        deps,
        {
          account: result.account,
          terms: result.terms,
          ref: orderRef,
          retry: run,
          // The terms signature just cleared, so the server now serves the
          // signable fields: this is the first moment a brief can be built.
          renderSummary: (refreshedOrder) => renderAuthorizationScreen(deps, refreshedOrder, get),
        },
        get
      );
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState(get("status"), get);
    } else {
      paintStatus(get("status"), MESSAGES[result.reason] || `Payment failed (${result.reason}). Nothing was charged — reopen this page from the chat button to retry.`, "error");
      get("pay").disabled = false;
    }
  };
  get("pay").onclick = () => run();
}

export async function setupSelfAuthorization(deps, order, orderRef, tg, get = $) {
  if (authorizationEnrichmentMissing(order)) {
    get("pay").hidden = true;
    paintStatus(get("summary"), MESSAGES.authorization_unavailable, "error");
    return;
  }

  renderAuthorizationScreen(deps, order, get);
  if (!(await enforceOwnerAtLoad(deps, order, get))) return;
  get("pay").disabled = false;

  const run = async (fetched) => {
    get("pay").disabled = true;
    paintStatus(get("status"), "Connecting wallet…");
    const result = await runSelfAuthorizationFlow(deps, orderRef, fetched);

    if (result.warning === "submitted_report_failed") {
      paintStatus(
        get("status"),
        `Transaction sent, but reporting failed. Do not send it again. Transaction hash: ${result.tx}. You can return to the chat.`,
        "warning",
      );
    } else if (result.ok) {
      paintStatus(get("status"), "Transaction sent ✓ — you can return to the chat.", "success");
      scheduleReturn(tg, get);
    } else if (result.reason === "wrong_wallet") {
      blockWrongWallet(result.expected, get);
    } else if (result.reason === "terms_required") {
      showTermsPrompt(
        deps,
        {
          account: result.account,
          terms: result.terms,
          ref: orderRef,
          retry: run,
          renderSummary: (refreshedOrder) => renderAuthorizationScreen(deps, refreshedOrder, get),
        },
        get,
      );
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState(get("status"), get);
    } else {
      paintStatus(
        get("status"),
        MESSAGES[result.reason] || `Payment failed (${result.reason}).`,
        "error",
      );
      get("pay").disabled = false;
    }
  };
  get("pay").onclick = () => run();
}

export async function setupUserTx(deps, order, orderRef, tg, get = $) {
  const pay = get("pay");
  const actions = get("funds-actions");
  const recheck = get("funds-recheck");
  const signAnyway = get("funds-sign-anyway");

  get("summary").textContent = summaryLines(order);
  pay.textContent = "Review & sign in wallet";
  actions.hidden = true;
  if (!(await enforceOwnerAtLoad(deps, order, get))) return;
  pay.disabled = false;

  function showFundsWarning(result) {
    const decimals = Number.isInteger(deps.config.tokenDecimals) ? deps.config.tokenDecimals : 6;
    const token = deps.config.tokenName || "tokens";
    const message = result.reason === "insufficient_token"
      ? `This wallet holds ${formatUnits(result.balance, decimals, decimals)} ${token} — this order needs ${formatUnits(result.needed, decimals, decimals)} ${token}. Top it up, then re-check.`
      : "This wallet has too little ETH for gas — the transaction is likely to fail.";

    pay.hidden = true;
    actions.hidden = false;
    recheck.disabled = false;
    signAnyway.disabled = false;
    paintStatus(get("status"), message, "warning");

    recheck.onclick = async () => {
      recheck.disabled = true;
      signAnyway.disabled = true;
      paintStatus(get("status"), "Checking balances…");
      const checked = await preflightFunds(deps, {
        order: result.order,
        account: result.account,
      });
      if (!checked.ok)
        return showFundsWarning({ ...checked, order: result.order, account: result.account });

      actions.hidden = true;
      pay.hidden = false;
      pay.disabled = false;
      paintStatus(get("status"), "You can review and sign when ready; balances will be checked again first.");
    };
    signAnyway.onclick = () => run(undefined, { skipPreflight: true });
  }

  const run = async (fetched, options = {}) => {
    pay.disabled = true;
    actions.hidden = true;
    paintStatus(get("status"), "Opening wallet…");
    const result = await runUserTxFlow(deps, orderRef, fetched, options);
    if (result.ok) {
      paintStatus(get("status"), "Transaction sent ✓ — you can return to the chat.", "success");
      scheduleReturn(tg);
    } else if (result.reason === "insufficient_token" || result.reason === "insufficient_gas") {
      showFundsWarning(result);
    } else if (result.reason === "wrong_wallet") {
      blockWrongWallet(result.expected, get);
    } else if (result.reason === "terms_required") {
      showTermsPrompt(
        deps,
        { account: result.account, terms: result.terms, ref: orderRef, retry: run },
        get,
      );
    } else if (result.reason === "geo_blocked") {
      enterGeoDeadState(get("status"), get);
    } else {
      paintStatus(get("status"), MESSAGES[result.reason] || `Transaction failed (${result.reason}).`, "error");
      pay.hidden = false;
      pay.disabled = false;
    }
  };
  pay.onclick = () => run();
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
      scheduleReturn(tg);
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
