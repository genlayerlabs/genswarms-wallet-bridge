// DOM glue for the wallet dapp. All decision logic lives in lib/flow.mjs
// (tested headlessly); this file only wires optional Telegram initData,
// the injected EIP-1193 provider, and the DOM elements.

import { connectWallet, fetchOrder, fetchPermitNonce, runBindFlow, runUserTxFlow, signAndSubmit, walletDappLink } from "./lib/flow.mjs";

const $ = (id) => document.getElementById(id);

const MESSAGES = {
  order_not_found: "This payment link expired or was already used. Go back to the chat and tap again.",
  unauthorized: "Could not verify your Telegram session. Reopen this page from the chat button.",
  version_mismatch: "This page is outdated. Close and reopen it from the chat.",
  user_rejected: "Signature declined — nothing was paid.",
  wrong_chain: "Your wallet is on the wrong network for this payment.",
  no_account: "No wallet account connected.",
  expired: "This order expired. Go back to the chat and tap again.",
};

async function main() {
  const tg = globalThis.Telegram && globalThis.Telegram.WebApp;
  const initData = tg ? tg.initData : "";
  const params = new URLSearchParams(location.search);
  const orderRef = entryRef(tg, params);
  const token = params.get("token") || "";

  const config = await (await fetch("./config.json")).json();
  const provider = globalThis.ethereum;

  if (!provider) {
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
    $("summary").textContent = MESSAGES[fetched.reason] || `Could not load the order (${fetched.reason}).`;
    return;
  }

  if (fetched.order.kind === "user_tx") return setupUserTx(deps, fetched.order, orderRef, tg);
  if (fetched.order.kind === "bind") return setupBind(deps, fetched.order, orderRef, tg);
  setupPermit(deps, fetched.order, orderRef, tg, config);
}

function setupPermit(deps, order, orderRef, tg, config) {
  const amount = (order.amount / 1_000_000).toFixed(2);
  $("summary").textContent = `${config.actionLabel}: ${amount} USDC (gasless — the operator pays network fees).`;
  const manual = order.display && order.display.manual;
  if (manual) {
    $("manual-address").textContent = manual.address;
    $("manual-amount").textContent = `Send exactly ${(manual.amount / 1_000_000).toFixed(2)} USDC on Base to:`;
    $("manual").hidden = false;
  }
  $("pay").disabled = false;

  $("pay").onclick = async () => {
    $("pay").disabled = true;
    $("status").textContent = "Connecting wallet…";

    const conn = await connectWallet(deps);
    if (!conn.ok || conn.chainId !== config.chainId) {
      $("status").textContent = MESSAGES[conn.ok ? "wrong_chain" : conn.reason];
      $("pay").disabled = false;
      return;
    }

    $("status").textContent = "Waiting for your signature…";
    const nonce = await fetchPermitNonce(deps, conn.account);

    const result = await signAndSubmit(deps, {
      orderRef,
      order,
      account: conn.account,
      nonce,
    });

    if (result.ok) {
      $("status").textContent = "Payment submitted ✓ — you can return to the chat.";
      if (tg) setTimeout(() => tg.close(), 1500);
    } else {
      $("status").textContent = MESSAGES[result.reason] || `Payment failed (${result.reason}). The transfer option in chat still works.`;
      $("pay").disabled = false;
    }
  };
}

function setupUserTx(deps, order, orderRef, tg) {
  $("summary").textContent = summaryLines(order);
  $("pay").textContent = "Review & sign in wallet";
  $("pay").disabled = false;
  $("pay").onclick = async () => {
    $("pay").disabled = true;
    $("status").textContent = "Opening wallet…";
    const result = await runUserTxFlow(deps, orderRef);
    if (result.ok) {
      $("status").textContent = "Transaction sent ✓ — you can return to the chat.";
      if (tg) setTimeout(() => tg.close(), 1500);
    } else {
      $("status").textContent = MESSAGES[result.reason] || `Transaction failed (${result.reason}).`;
      $("pay").disabled = false;
    }
  };
}

function setupBind(deps, order, bindRef, tg) {
  $("summary").textContent = order.current_wallet
    ? `Connected wallet on file: ${order.current_wallet} — connect to change it.`
    : "No wallet on file yet.";
  $("pay").textContent = "Connect wallet";
  $("pay").disabled = false;
  $("pay").onclick = async () => {
    $("pay").disabled = true;
    $("status").textContent = "Connecting wallet…";
    const result = await runBindFlow(deps, bindRef);
    if (result.ok) {
      $("status").textContent = "Wallet bound ✓ — you can return to the chat.";
      if (tg) setTimeout(() => tg.close(), 1500);
    } else {
      $("status").textContent = MESSAGES[result.reason] || `Wallet bind failed (${result.reason}).`;
      $("pay").disabled = false;
    }
  };
}

function summaryLines(order) {
  const lines = order.display && order.display.summary_lines;
  return Array.isArray(lines) && lines.length ? lines.join("\n") : "Review this transaction in your wallet.";
}

export function entryRef(tg, params) {
  return (tg && tg.initDataUnsafe && tg.initDataUnsafe.start_param) || params.get("order") || params.get("bind");
}

if (typeof document !== "undefined") main();
