export const DEFAULT_DAPP_LINK_PREFIX = "https://link.metamask.io/dapp/";

export function chooseRoute(userAgent, href, prefix = DEFAULT_DAPP_LINK_PREFIX) {
  const dapp = dappUrl(href);
  if (/Android|iPhone|iPad|iPod/i.test(userAgent || "")) {
    return { mode: "mobile", target: prefix + nestedDapp(dapp, prefix) };
  }
  return { mode: "desktop", target: dapp };
}

function dappUrl(href) {
  const u = new URL(href);
  const dir = u.pathname.replace(/[^/]*$/, "");
  return u.origin + dir + "index.html" + u.search;
}

function nestedDapp(dapp, prefix) {
  const noScheme = dapp.replace(/^https?:\/\//, "");
  return prefix.includes("?") ? encodeURIComponent(noScheme) : noScheme;
}
