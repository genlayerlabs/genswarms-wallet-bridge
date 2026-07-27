// Wallet discovery (EIP-6963), so the user picks which wallet pays.
//
// Before EIP-6963 a page could only read `window.ethereum`, a single slot that
// every installed extension overwrites on injection. With two wallets
// installed the page silently gets whichever won a race the user cannot see
// or change — and if that is not the wallet holding their funds, the payment
// simply cannot be made from this page.
//
// EIP-6963 replaces the race with an announcement: the page dispatches
// `eip6963:requestProvider`, every wallet answers with an
// `eip6963:announceProvider` event carrying its own provider and identity, and
// the page lists what answered.
//
// Announcements are asynchronous with no completion signal, so discovery is
// bounded by a short timeout. Wallets that predate the standard announce
// nothing; for them the legacy injected slot is kept as a last resort, never
// as a peer (it may be one of the announcers, and would then appear twice).

export const LEGACY_RDNS = "legacy.injected";

const REQUEST_EVENT = "eip6963:requestProvider";
const ANNOUNCE_EVENT = "eip6963:announceProvider";

function usable(detail) {
  return (
    detail &&
    detail.provider &&
    typeof detail.provider.request === "function" &&
    detail.info &&
    typeof detail.info.rdns === "string" &&
    detail.info.rdns !== ""
  );
}

/**
 * Wallets available to this page, as [{ info: { rdns, name, icon }, provider }].
 *
 * `rdns` is the identity to dedupe on: `uuid` is minted per announcement, so a
 * wallet that answers twice (some announce on both load and request) would
 * otherwise be listed twice. First announcement of an rdns wins.
 *
 * Returns [] when nothing is available — the caller's dead state, unchanged.
 */
export async function discoverProviders({
  target,
  injected,
  timeoutMs = 300,
  setTimeoutFn = setTimeout,
} = {}) {
  const found = new Map();

  if (target && typeof target.addEventListener === "function") {
    const onAnnounce = (event) => {
      const detail = event && event.detail;
      if (usable(detail) && !found.has(detail.info.rdns)) {
        found.set(detail.info.rdns, { info: detail.info, provider: detail.provider });
      }
    };

    target.addEventListener(ANNOUNCE_EVENT, onAnnounce);
    target.dispatchEvent(new CustomEvent(REQUEST_EVENT));
    await new Promise((resolve) => setTimeoutFn(resolve, timeoutMs));
    target.removeEventListener(ANNOUNCE_EVENT, onAnnounce);
  }

  const announced = [...found.values()].sort((a, b) =>
    String(a.info.name || a.info.rdns).localeCompare(String(b.info.name || b.info.rdns)),
  );

  if (announced.length > 0) return announced;

  // Nothing announced: fall back to the pre-6963 slot if something is there.
  if (injected && typeof injected.request === "function") {
    return [{ info: { rdns: LEGACY_RDNS, name: "Browser wallet" }, provider: injected }];
  }

  return [];
}

/**
 * Whether the user must be asked. One wallet is not a choice, and asking
 * would be a click that can only have one outcome.
 */
export function needsChoice(providers) {
  return Array.isArray(providers) && providers.length > 1;
}
