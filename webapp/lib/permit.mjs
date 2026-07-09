// genswarms-delegated-spend wallet dapp — permit encoding (THE encoding code).
// Golden-vector discipline (spec §6.2/§8): vectors/permit/*.json are generated
// by THESE functions; Foundry redeems them and the Elixir keeper parses them.
// Change anything here and the cross-check fails until all three agree.
//
// Zero dependencies. Wallet-transport-agnostic: the typed data goes to
// eth_signTypedData_v4 whatever carries it (injected provider today,
// Connect SDK relay later).

/** EIP-712 typed data for an EIP-2612 permit (USDC-shaped: nonce in struct). */
export function buildPermitTypedData({
  chainId,
  token,
  tokenName,
  tokenVersion,
  owner,
  spender,
  value,
  nonce,
  deadline,
}) {
  return {
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    },
    primaryType: "Permit",
    domain: {
      name: tokenName,
      version: tokenVersion,
      chainId,
      verifyingContract: token,
    },
    message: {
      owner,
      spender,
      value: String(value),
      nonce: String(nonce),
      deadline: String(deadline),
    },
  };
}

/** Split a 65-byte 0x signature into {v, r, s}; normalizes yParity 0/1 → 27/28. */
export function splitSignature(sigHex) {
  const hex = sigHex.replace(/^0x/, "");
  if (hex.length !== 130) throw new Error("signature must be 65 bytes");
  const r = "0x" + hex.slice(0, 64);
  const s = "0x" + hex.slice(64, 128);
  let v = parseInt(hex.slice(128, 130), 16);
  if (v === 0 || v === 1) v += 27;
  if (v !== 27 && v !== 28) throw new Error("bad v");
  return { v, r, s };
}

/**
 * The intake grant envelope (POST /grants body's "permit" field). Shape is
 * byte-matched with DelegatedSpend.Intake.GrantValidation at every tag
 * (spec §3.1) — the Elixir vector test enforces it.
 */
export function buildGrantEnvelope({
  version,
  chainId,
  token,
  spender,
  owner,
  value,
  deadline,
  signature,
}) {
  const sig = splitSignature(signature);
  return {
    v: version,
    chain_id: chainId,
    token,
    spender,
    owner,
    value: Number(value),
    deadline: Number(deadline),
    sig,
  };
}
