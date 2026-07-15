// Wallet dapp permit-lane flow (spec §6.3 steps 2–4), DOM-free and
// dependency-injected so it runs identically under the browser glue
// (app.mjs) and the node --test mock-provider suite.
//
// deps: { provider (EIP-1193), fetchFn, config, initData, token }
// config: { version, chainId, token, tokenName, tokenVersion, router,
//           intakeUrl, actionLabel }
//
// Every failure is a TYPED state — the chat card's transfer-lane fallback is
// the product-side answer to all of them; the wallet dapp only reports.

import { buildPermitTypedData, buildGrantEnvelope } from "./permit.mjs";
import { buildTermsEnvelope, buildTermsTypedData } from "./terms.mjs";

export async function connectWallet({ provider }) {
  const accounts = await provider.request({ method: "eth_requestAccounts" });
  if (!accounts || accounts.length === 0) return { ok: false, reason: "no_account" };
  const chainHex = await provider.request({ method: "eth_chainId" });
  return { ok: true, account: accounts[0], chainId: parseInt(chainHex, 16) };
}

function authBody(deps, extra) {
  const auth = deps.token ? { token: deps.token } : { init_data: deps.initData };
  return JSON.stringify({ v: deps.config.version, ...auth, ...extra });
}

export function walletDappLink(href, prefix = "https://link.metamask.io/dapp/") {
  const noScheme = href.replace(/^https?:\/\//, "");
  return prefix + (prefix.includes("?") ? encodeURIComponent(noScheme) : noScheme);
}

export async function acceptTerms(deps, { account, vHash, ref }) {
  const { provider, fetchFn, config } = deps;
  const issuedAt = Math.floor((deps.nowFn ? deps.nowFn() : Date.now()) / 1000);
  const typedData = buildTermsTypedData({ chainId: config.chainId, vHash, account, issuedAt });

  let signature;
  try {
    signature = await provider.request({
      method: "eth_signTypedData_v4",
      params: [account, JSON.stringify(typedData)],
    });
  } catch (e) {
    return { ok: false, reason: e && e.code === 4001 ? "user_rejected" : "sign_failed" };
  }

  const acceptance = buildTermsEnvelope({
    version: config.version,
    chainId: config.chainId,
    vHash,
    account,
    issuedAt,
    signature,
  });
  let res;
  try {
    res = await fetchFn(`${config.intakeUrl}/terms`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: authBody(deps, { ref, acceptance }),
    });
  } catch (_) {
    return { ok: false, reason: "request_failed" };
  }

  if (res.status === 451) return { ok: false, reason: "geo_blocked" };
  if (res.status === 401) return { ok: false, reason: "unauthorized" };
  let body = {};
  try {
    body = (await res.json()) || {};
  } catch (_) {}

  if (res.status === 200) {
    if (body.status !== "accepted" || typeof body.v_hash !== "string" || !body.v_hash)
      return { ok: false, reason: "invalid_response" };
    return { ok: true, status: "accepted", vHash: body.v_hash };
  }
  if (res.status === 409 && body.error === "terms_stale") {
    const terms = body.terms;
    if (!terms || typeof terms.v_hash !== "string" || !terms.v_hash ||
        typeof terms.url !== "string" || !terms.url || body.v_hash !== terms.v_hash)
      return { ok: false, reason: "invalid_response" };
    return { ok: false, reason: "terms_stale", terms };
  }
  if (res.status === 409) return { ok: false, reason: "version_mismatch" };
  if (res.status === 422) return { ok: false, reason: "invalid", field: body.field };
  return { ok: false, reason: body.error || `http_${res.status}` };
}

/**
 * Config drift (fail-closed, fund-loss class): the order carries the keeper's
 * RUNTIME chain id, while `config.json` is a static file stamped at deploy
 * time. When they disagree the deployment is inconsistent — enforcing the
 * stale config chain would let a server-built transfer succeed on the wrong
 * network to an unwatched address. NOTHING may be signed and the wallet must
 * not even be connected (and never auto-switched: there is no right chain to
 * switch to until the operator redeploys). An order without `chain_id`
 * (older keeper) never drifts — the wallet-vs-config chain check still runs.
 */
export function configDrift(order, config) {
  const runtime = order && order.chain_id;
  if (runtime == null) return false;
  return runtime !== (config && config.chainId);
}

export function termsRequired(order) {
  return order?.terms?.required === true;
}

/**
 * Owner-bound orders (`order.expected_owner`): true when a connected account
 * is NOT the wallet the order is bound to (case-insensitive). Unbound orders
 * and a not-yet-connected account never mismatch — connecting is a separate,
 * already-typed step.
 */
export function ownerMismatch(order, account) {
  const expected = order && order.expected_owner;
  if (!expected || !account) return false;
  return expected.toLowerCase() !== account.toLowerCase();
}

export function shortAddress(address) {
  return address.length > 12 ? `${address.slice(0, 6)}…${address.slice(-4)}` : address;
}

export function wrongWalletMessage(expected) {
  return `Wrong wallet connected. Switch to ${shortAddress(expected)} in your wallet, then reload.`;
}

export async function fetchOrder(deps, orderRef) {
  const { fetchFn, config } = deps;
  const res = await fetchFn(`${config.intakeUrl}/orders`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: authBody(deps, { order_ref: orderRef }),
  });
  if (res.status === 404) return { ok: false, reason: "order_not_found" };
  if (res.status === 401) return { ok: false, reason: "unauthorized" };
  if (res.status === 409) return { ok: false, reason: "version_mismatch" };
  if (res.status === 410) return { ok: false, reason: "expired" };
  if (res.status === 451) return { ok: false, reason: "geo_blocked" };
  if (res.status === 428) return { ok: false, reason: "terms_required", terms: (await res.json()).terms };
  if (res.status !== 200) return { ok: false, reason: `http_${res.status}` };
  return { ok: true, order: await res.json() };
}

/** Read the token nonce for the owner straight from the chain (eth_call). */
export async function fetchPermitNonce({ provider, config }, owner) {
  // nonces(address) selector 0x7ecebe00
  const data = "0x7ecebe00" + owner.replace(/^0x/, "").toLowerCase().padStart(64, "0");
  const result = await provider.request({
    method: "eth_call",
    params: [{ to: config.token, data }, "latest"],
  });
  return parseInt(result, 16);
}

export async function signAndSubmit(deps, { orderRef, order, account, nonce }) {
  const { provider, fetchFn, config } = deps;

  const typedData = buildPermitTypedData({
    chainId: config.chainId,
    token: config.token,
    tokenName: config.tokenName,
    tokenVersion: config.tokenVersion,
    owner: account,
    spender: config.router,
    value: order.amount,
    nonce,
    deadline: order.expires_at,
  });

  let signature;
  try {
    signature = await provider.request({
      method: "eth_signTypedData_v4",
      params: [account, JSON.stringify(typedData)],
    });
  } catch (e) {
    if (e && e.code === 4001) return { ok: false, reason: "user_rejected" };
    return { ok: false, reason: "sign_failed" };
  }

  const envelope = buildGrantEnvelope({
    version: config.version,
    chainId: config.chainId,
    token: config.token,
    spender: config.router,
    owner: account,
    value: order.amount,
    deadline: order.expires_at,
    signature,
  });

  const res = await fetchFn(`${config.intakeUrl}/grants`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: authBody(deps, { order_ref: orderRef, permit: envelope }),
  });

  if (res.status === 409) return { ok: false, reason: "version_mismatch" };
  if (res.status === 401) return { ok: false, reason: "unauthorized" };
  if (res.status === 451) return { ok: false, reason: "geo_blocked" };
  const body = await res.json();
  if (res.status === 428)
    return { ok: false, reason: "terms_required", terms: body.terms, account };
  if (res.status !== 200) return { ok: false, reason: body.reason || body.error || `http_${res.status}` };
  return { ok: true, status: body.status, tx: body.tx };
}

/**
 * The whole §6.3 handshake: fetch order → sign → submit. The order is
 * fetched BEFORE the wallet is connected (0.3.1): a drifted deployment must
 * be refused before ANY wallet interaction, so the config-drift gate needs
 * the order's runtime chain id first. The wallet-vs-config chain check is
 * unchanged — it now runs only when order and config already agree.
 */
export async function runPermitFlow(deps, orderRef, fetched = null) {
  fetched ??= await fetchOrder(deps, orderRef);
  if (!fetched.ok) return fetched;
  if (configDrift(fetched.order, deps.config)) return { ok: false, reason: "config_drift" };

  const conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  if (conn.chainId !== deps.config.chainId)
    return { ok: false, reason: "wrong_chain", expected: deps.config.chainId };
  if (ownerMismatch(fetched.order, conn.account))
    return { ok: false, reason: "wrong_wallet", expected: fetched.order.expected_owner };
  if (termsRequired(fetched.order))
    return { ok: false, reason: "terms_required", terms: fetched.order.terms, account: conn.account };

  const nonce = await fetchPermitNonce(deps, conn.account);

  return signAndSubmit(deps, {
    orderRef,
    order: fetched.order,
    account: conn.account,
    nonce,
  });
}

export async function runUserTxFlow(deps, orderRef, fetched = null) {
  // Fetch-before-connect, same as runPermitFlow: config drift must block
  // before the wallet is ever touched.
  fetched ??= await fetchOrder(deps, orderRef);
  if (!fetched.ok) return fetched;
  if (configDrift(fetched.order, deps.config)) return { ok: false, reason: "config_drift" };
  if (fetched.order.kind !== "user_tx") return { ok: false, reason: "wrong_kind" };

  const conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  if (conn.chainId !== deps.config.chainId)
    return { ok: false, reason: "wrong_chain", expected: deps.config.chainId };
  // The load-bearing wrong-wallet check: paying an owner-bound order from a
  // different account debits that account while payouts go to the bound
  // wallet (and sells revert on-chain). Refuse before the wallet ever opens.
  if (ownerMismatch(fetched.order, conn.account))
    return { ok: false, reason: "wrong_wallet", expected: fetched.order.expected_owner };
  if (termsRequired(fetched.order))
    return { ok: false, reason: "terms_required", terms: fetched.order.terms, account: conn.account };

  let tx;
  try {
    tx = await deps.provider.request({
      method: "eth_sendTransaction",
      params: [{ ...fetched.order.tx, from: conn.account, value: hexQuantity(fetched.order.tx.value) }],
    });
  } catch (e) {
    if (e && e.code === 4001) return { ok: false, reason: "user_rejected" };
    return { ok: false, reason: "send_failed" };
  }

  try {
    await deps.fetchFn(`${deps.config.intakeUrl}/orders/submitted`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: authBody(deps, { order_ref: orderRef, tx_hash: tx }),
    });
  } catch (_) {}

  return { ok: true, tx, order: fetched.order };
}

function hexQuantity(value) {
  if (typeof value === "string" && /^0x[0-9a-fA-F]+$/.test(value)) return value;
  if (Number.isSafeInteger(value) && value >= 0) return "0x" + value.toString(16);
  throw new Error("bad quantity");
}

export async function runBindFlow(deps, bindRef, fetched = null) {
  // Bind pages consume config too (chain gate below), so the drift guard
  // applies here as well: fetch the bind order's view first and refuse a
  // drifted deployment before the wallet is connected — a healthy-looking
  // bind page on top of an inconsistent deployment feeds wallets into flows
  // that would then pay on the wrong network.
  fetched ??= await fetchOrder(deps, bindRef);
  if (!fetched.ok) return fetched;
  if (configDrift(fetched.order, deps.config)) return { ok: false, reason: "config_drift" };

  const conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  if (conn.chainId !== deps.config.chainId)
    return { ok: false, reason: "wrong_chain", expected: deps.config.chainId };
  if (termsRequired(fetched.order))
    return { ok: false, reason: "terms_required", terms: fetched.order.terms, account: conn.account };

  const res = await deps.fetchFn(`${deps.config.intakeUrl}/wallet`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: authBody(deps, { bind_ref: bindRef, address: conn.account }),
  });
  if (res.status === 401) return { ok: false, reason: "unauthorized" };
  if (res.status === 409) return { ok: false, reason: "version_mismatch" };
  if (res.status === 410) return { ok: false, reason: "expired" };
  if (res.status === 451) return { ok: false, reason: "geo_blocked" };
  const body = await res.json();
  if (res.status === 428)
    return { ok: false, reason: "terms_required", terms: body.terms, account: conn.account };
  if (res.status !== 200) return { ok: false, reason: body.error || `http_${res.status}` };
  return { ok: true, address: body.address };
}
