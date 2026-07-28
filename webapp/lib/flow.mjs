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
import { buildAuthorizationTypedData, buildAuthorizationEnvelope } from "./authorization.mjs";
import { buildTermsEnvelope, buildTermsTypedData } from "./terms.mjs";

export async function connectWallet({ provider }) {
  const accounts = await provider.request({ method: "eth_requestAccounts" });
  if (!accounts || accounts.length === 0) return { ok: false, reason: "no_account" };
  const chainHex = await provider.request({ method: "eth_chainId" });
  return { ok: true, account: accounts[0], chainId: parseInt(chainHex, 16) };
}

/**
 * Wallet-vs-config chain alignment (EIP-3326 switch + EIP-3085 add). Runs
 * ONLY after the config-drift gate passed — order and config agree, so
 * `config.chainId` is the one right network and asking the wallet to switch
 * is safe: the wallet shows its own confirmation, and the surrounding flow
 * only ever runs from a user tap. A wallet that does not know the chain
 * (4902, plain or MetaMask-mobile-wrapped) is offered the config's optional
 * `chain` metadata. Every failure — rejection, missing metadata, a switch
 * that silently did not land — stays the typed `wrong_chain`; the pinned
 * chain is re-read afterwards so nothing is ever signed on the wrong network
 * on the strength of a resolved promise alone.
 */
export async function ensureChain(deps, conn) {
  const { provider, config } = deps;
  if (conn.chainId === config.chainId) return conn;
  const wrong = { ok: false, reason: "wrong_chain", expected: config.chainId };
  const chainId = "0x" + config.chainId.toString(16);

  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  } catch (e) {
    const params = addChainParams(config);
    if (!unrecognizedChain(e) || !params) return wrong;
    try {
      // MetaMask prompts add + switch as one step; the re-read below verifies.
      await provider.request({ method: "wallet_addEthereumChain", params: [params] });
    } catch (_) {
      return wrong;
    }
  }

  try {
    const chainHex = await provider.request({ method: "eth_chainId" });
    if (parseInt(chainHex, 16) !== config.chainId) return wrong;
  } catch (_) {
    return wrong;
  }
  return { ...conn, chainId: config.chainId };
}

// 4902 = unrecognized chain (EIP-3326). MetaMask mobile has long shipped it
// wrapped inside a -32603 internal error's data.
function unrecognizedChain(e) {
  return !!e && (e.code === 4902 || e?.data?.originalError?.code === 4902);
}

/**
 * EIP-3085 params from the config's optional `chain` block:
 *   "chain": { "name": "…", "rpcUrls": ["https://…"], "explorerUrl": "https://…" }
 * The chain ID always derives from the top-level `chainId` pin (single
 * source of truth); rpc/explorer URLs must be https. Without a valid block
 * the add step is skipped and the mismatch stays a typed `wrong_chain`.
 */
export function addChainParams(config) {
  const chain = config && config.chain;
  const rpcUrls = Array.isArray(chain?.rpcUrls)
    ? chain.rpcUrls.filter((u) => typeof u === "string" && /^https:\/\//.test(u))
    : [];
  if (!chain || typeof chain.name !== "string" || !chain.name || rpcUrls.length === 0) return null;

  const params = {
    chainId: "0x" + config.chainId.toString(16),
    chainName: chain.name,
    rpcUrls,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  };
  if (typeof chain.explorerUrl === "string" && /^https:\/\//.test(chain.explorerUrl))
    params.blockExplorerUrls = [chain.explorerUrl];
  return params;
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
  // Defensive guard (review C1): every real caller passes a server-served
  // address, but a falsy input must render SOMETHING rather than throw —
  // a page that dies on a missing field is the whole bug class this lane
  // exists to avoid.
  if (!address) return "an address";
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
 * the order's runtime chain id first. The wallet-vs-config chain check runs
 * only when order and config already agree — and asks the wallet to switch
 * (ensureChain) instead of dead-ending on a fixable mismatch.
 */
export async function runPermitFlow(deps, orderRef, fetched = null) {
  fetched ??= await fetchOrder(deps, orderRef);
  if (!fetched.ok) return fetched;
  if (configDrift(fetched.order, deps.config)) return { ok: false, reason: "config_drift" };

  let conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  conn = await ensureChain(deps, conn);
  if (!conn.ok) return conn;
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

/**
 * The authorization (EIP-3009) lane's sign step: `to`, `value`, `nonce` and
 * the EIP-712 `domain` all come from the SERVER-served order view (see
 * DelegatedSpend.Intake.handle_order/3) — this page shows them and signs
 * over exactly what it was given, it never recomputes any of them. The
 * keeper re-validates everything against the stored order and its own
 * boot-verified domain before it ever calls the token contract, so a
 * tampered value here would simply fail to execute, never overpay.
 */
export async function signAndSubmitAuthorization(deps, { orderRef, order, account }) {
  const { provider, fetchFn, config } = deps;

  const typedData = buildAuthorizationTypedData({
    domain: order.domain,
    from: account,
    to: order.to,
    value: order.value,
    validAfter: order.valid_after,
    validBefore: order.valid_before,
    nonce: order.nonce,
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

  const envelope = buildAuthorizationEnvelope({
    version: config.version,
    chainId: config.chainId,
    token: order.token,
    from: account,
    value: order.value,
    validAfter: order.valid_after,
    validBefore: order.valid_before,
    signature,
  });

  const res = await fetchFn(`${config.intakeUrl}/authorization`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: authBody(deps, { order_ref: orderRef, authorization: envelope }),
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
 * The authorization lane's whole handshake: fetch order → sign → submit.
 * Same shape as runPermitFlow (fetch-before-connect so config drift blocks
 * before any wallet interaction; the wallet-vs-config chain check only runs
 * once order and config already agree) — this lane needs no on-chain nonce
 * read (the server-picked nonce is deterministic from the order ref, not a
 * per-owner counter), so there is no fetchPermitNonce-equivalent step.
 */
export async function runAuthorizationFlow(deps, orderRef, fetched = null) {
  fetched ??= await fetchOrder(deps, orderRef);
  if (!fetched.ok) return fetched;
  if (configDrift(fetched.order, deps.config)) return { ok: false, reason: "config_drift" };
  if (fetched.order.kind !== "authorization") return { ok: false, reason: "wrong_kind" };

  let conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  conn = await ensureChain(deps, conn);
  if (!conn.ok) return conn;
  if (ownerMismatch(fetched.order, conn.account))
    return { ok: false, reason: "wrong_wallet", expected: fetched.order.expected_owner };
  if (termsRequired(fetched.order))
    return { ok: false, reason: "terms_required", terms: fetched.order.terms, account: conn.account };

  return signAndSubmitAuthorization(deps, {
    orderRef,
    order: fetched.order,
    account: conn.account,
  });
}

export function hasAccountCode(code) {
  if (typeof code !== "string" || !/^0x[0-9a-fA-F]*$/.test(code)) return null;
  return !/^0x0*$/i.test(code);
}

async function checkAccountCode({ provider }, account) {
  try {
    const present = hasAccountCode(
      await provider.request({ method: "eth_getCode", params: [account, "latest"] }),
    );
    if (present == null) return { ok: false, reason: "code_check_failed" };
    return present ? { ok: false, reason: "wallet_has_code" } : { ok: true };
  } catch (_) {
    return { ok: false, reason: "code_check_failed" };
  }
}

async function signSelfAuthorization(deps, { orderRef, order, account }) {
  const { provider, fetchFn, config } = deps;
  const typedData = buildAuthorizationTypedData({
    domain: order.domain,
    from: account,
    to: order.to,
    value: order.value,
    validAfter: order.valid_after,
    validBefore: order.valid_before,
    nonce: order.nonce,
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

  const envelope = buildAuthorizationEnvelope({
    version: config.version,
    chainId: config.chainId,
    token: order.token,
    from: account,
    value: order.value,
    validAfter: order.valid_after,
    validBefore: order.valid_before,
    signature,
  });

  let res;
  try {
    res = await fetchFn(`${config.intakeUrl}/authorization/self`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: authBody(deps, { order_ref: orderRef, authorization: envelope }),
    });
  } catch (_) {
    return { ok: false, reason: "request_failed" };
  }

  if (res.status === 409) return { ok: false, reason: "version_mismatch" };
  if (res.status === 401) return { ok: false, reason: "unauthorized" };
  if (res.status === 451) return { ok: false, reason: "geo_blocked" };

  let body = {};
  try {
    body = (await res.json()) || {};
  } catch (_) {}

  if (res.status === 428)
    return { ok: false, reason: "terms_required", terms: body.terms, account };
  if (res.status !== 200)
    return { ok: false, reason: body.reason || body.error || `http_${res.status}` };

  const validTx =
    typeof body.to === "string" &&
    /^0x[0-9a-fA-F]{40}$/.test(body.to) &&
    typeof body.data === "string" &&
    /^0x[0-9a-fA-F]+$/.test(body.data) &&
    Number.isSafeInteger(body.chain_id) &&
    Number.isSafeInteger(body.valid_before) &&
    body.chain_id === config.chainId &&
    body.valid_before === order.valid_before &&
    typeof order.token === "string" &&
    body.to.toLowerCase() === order.token.toLowerCase();

  return validTx ? { ok: true, transaction: body } : { ok: false, reason: "invalid_response" };
}

/**
 * Self-submit EIP-3009: fetch → connect → reject code-bearing accounts →
 * sign → ask the keeper for verified calldata → send from the payer wallet →
 * report the transaction hash as a best-effort watcher hint.
 */
export async function runSelfAuthorizationFlow(deps, orderRef, fetched = null) {
  fetched ??= await fetchOrder(deps, orderRef);
  if (!fetched.ok) return fetched;
  if (configDrift(fetched.order, deps.config)) return { ok: false, reason: "config_drift" };
  if (fetched.order.kind !== "authorization_self") return { ok: false, reason: "wrong_kind" };

  let conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  conn = await ensureChain(deps, conn);
  if (!conn.ok) return conn;
  if (ownerMismatch(fetched.order, conn.account))
    return { ok: false, reason: "wrong_wallet", expected: fetched.order.expected_owner };

  const code = await checkAccountCode(deps, conn.account);
  if (!code.ok) return code;
  if (termsRequired(fetched.order))
    return { ok: false, reason: "terms_required", terms: fetched.order.terms, account: conn.account };

  const built = await signSelfAuthorization(deps, {
    orderRef,
    order: fetched.order,
    account: conn.account,
  });
  if (!built.ok) return built;

  let tx;
  try {
    tx = await deps.provider.request({
      method: "eth_sendTransaction",
      params: [
        {
          from: conn.account,
          to: built.transaction.to,
          data: built.transaction.data,
          chainId: hexQuantity(built.transaction.chain_id),
        },
      ],
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

export async function runUserTxFlow(deps, orderRef, fetched = null) {
  // Fetch-before-connect, same as runPermitFlow: config drift must block
  // before the wallet is ever touched.
  fetched ??= await fetchOrder(deps, orderRef);
  if (!fetched.ok) return fetched;
  if (configDrift(fetched.order, deps.config)) return { ok: false, reason: "config_drift" };
  if (fetched.order.kind !== "user_tx") return { ok: false, reason: "wrong_kind" };

  let conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  conn = await ensureChain(deps, conn);
  if (!conn.ok) return conn;
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

  let conn = await connectWallet(deps);
  if (!conn.ok) return conn;
  conn = await ensureChain(deps, conn);
  if (!conn.ok) return conn;
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
