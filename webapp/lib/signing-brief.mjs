// What the user is about to sign, in words — and in the wallet's own numbers.
//
// The wallet screen cannot be improved from here. EIP-3009 fixes the struct
// the token contract will verify, so every wallet renders the same raw
// fields: `value 1000000`, `validBefore 1785096363`, a bare `to` address. A
// person cannot read money out of that. `1000000` is one million units, which
// is 1.00 USDC only if you already know the token carries six decimals.
//
// So the page's job is to say, BEFORE the wallet opens, exactly what the
// wallet is going to show and what each number means — turning an unreadable
// screen into one the user can check line by line. This module computes that
// brief; it renders nothing and reads no DOM.

const SECONDS_PER_DAY = 86400;

/** Whole-token amount from base units, e.g. (1000000, 6) -> "1.00". */
export function formatUnits(units, decimals = 6, minFractionDigits = 2) {
  const value = Number(units) / 10 ** decimals;
  if (!Number.isFinite(value)) return "0.00";
  const digits = Math.max(minFractionDigits, 0);
  return value.toFixed(digits);
}

/**
 * Expiry as something a person can act on.
 *
 * A unix timestamp is not a time to anyone reading it in a wallet, and "in
 * 900 seconds" is not either. Near-term expiries — which every payment
 * authorization is — are clearest as the remaining minutes.
 */
export function formatExpiry(validBefore, now = new Date()) {
  const seconds = Number(validBefore);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;

  const at = new Date(seconds * 1000);
  const remainingMs = at.getTime() - now.getTime();

  if (remainingMs <= 0) return { at, label: "expired" };

  const minutes = Math.floor(remainingMs / 60000);

  if (remainingMs >= SECONDS_PER_DAY * 1000) {
    return { at, label: `expires ${at.toLocaleString()}` };
  }

  const clock = at.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

  if (minutes < 1) return { at, label: `expires in under a minute (${clock})` };
  if (minutes === 1) return { at, label: `expires in 1 minute (${clock})` };
  return { at, label: `expires in ${minutes} minutes (${clock})` };
}

/**
 * The brief for an authorization order, or null when the order has not been
 * enriched yet (terms still pending — the server withholds the signable
 * fields until then, and a brief built from absent fields would state
 * confident nonsense).
 *
 * `steps` exists because the terms flow asks for TWO signatures back to back.
 * Unannounced, the second one reads as "it didn't work, it's asking again".
 */
export function authorizationBrief(order, config = {}, now = new Date()) {
  if (!order || !order.to || order.value == null) return null;

  const decimals = Number.isInteger(config.tokenDecimals) ? config.tokenDecimals : 6;
  const token = config.tokenName || "tokens";

  return {
    amount: formatUnits(order.value, decimals),
    token,
    destination: order.to,
    // The exact string the wallet will print next to `value`, so the user is
    // comparing identical characters rather than interpreting.
    rawValue: String(order.value),
    decimals,
    expiry: formatExpiry(order.valid_before, now),
    steps: order?.terms?.required === true ? { current: 1, total: 2 } : null,
  };
}

/**
 * The brief as display lines. Kept here (not in the DOM glue) so the wording
 * is testable and identical wherever it is rendered.
 */
export function briefLines(brief, productName) {
  if (!brief) return [];

  const destination = productName ? `${productName}'s wallet` : "the destination wallet";

  const lines = [
    {
      key: "headline",
      text: `${brief.amount} ${brief.token} to ${destination}`,
    },
    {
      key: "destination",
      text: brief.destination,
    },
    {
      key: "nature",
      text:
        `This is a signature, not a payment. It authorizes exactly this amount, ` +
        `once. It cannot be reused and cannot take more. We submit it and pay the ` +
        `network fee.`,
    },
    {
      key: "raw",
      text:
        `Your wallet will show value ${brief.rawValue} — that is ${brief.amount} ` +
        `${brief.token} (${brief.token} uses ${brief.decimals} decimals). The ` +
        `address it shows must match the one above.`,
    },
  ];

  if (brief.expiry) lines.push({ key: "expiry", text: `This authorization ${brief.expiry.label}.` });

  if (brief.steps) {
    lines.unshift({
      key: "steps",
      text: `Step ${brief.steps.current} of ${brief.steps.total} — accept the terms first, then the payment signature.`,
    });
  }

  lines.push({
    key: "next",
    text: "After you sign we submit it and confirm in the chat, usually within a minute.",
  });

  return lines;
}
