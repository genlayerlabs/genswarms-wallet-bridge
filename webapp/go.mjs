import { chooseRoute, DEFAULT_DAPP_LINK_PREFIX } from "./lib/launch.mjs";

const config = await fetch("./config.json").then((r) => r.json()).catch(() => ({}));
const route = chooseRoute(navigator.userAgent, location.href, config.dappLinkPrefix || DEFAULT_DAPP_LINK_PREFIX);

document.getElementById("open").href = route.target;

if (route.mode === "desktop") location.replace(route.target);
else setTimeout(() => { location.href = route.target; }, 150);
