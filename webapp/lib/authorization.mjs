// genswarms-wallet-bridge wallet dapp — EIP-3009 TransferWithAuthorization
// encoding, the sibling of lib/permit.mjs for the authorization lane.
//
// Zero dependencies. Wallet-transport-agnostic: the typed data goes to
// eth_signTypedData_v4 whatever carries it.
//
// `to`, `value` and `nonce` come from the SERVER (the order view — see
// DelegatedSpend.Intake.handle_order/3's authorization_fields/3) and are
// never recomputed here: the page only shows them, and the keeper re-checks
// everything against the stored order and its own boot-verified domain
// before it ever calls the token contract.

/** EIP-712 typed data for an EIP-3009 `TransferWithAuthorization`. */
export function buildAuthorizationTypedData({
  domain,
  from,
  to,
  value,
  validAfter,
  validBefore,
  nonce,
}) {
  return {
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
      TransferWithAuthorization: [
        { name: "from", type: "address" },
        { name: "to", type: "address" },
        { name: "value", type: "uint256" },
        { name: "validAfter", type: "uint256" },
        { name: "validBefore", type: "uint256" },
        { name: "nonce", type: "bytes32" },
      ],
    },
    primaryType: "TransferWithAuthorization",
    domain,
    message: {
      from,
      to,
      value: String(value),
      validAfter: String(validAfter),
      validBefore: String(validBefore),
      nonce,
    },
  };
}

/**
 * The intake authorization envelope (POST /authorization body's
 * "authorization" field). Shape is byte-matched with
 * DelegatedSpend.Intake.GrantValidation.validate_authorization/2 at every
 * tag — no "to": the destination is server-picked, never sent.
 */
export function buildAuthorizationEnvelope({
  version,
  chainId,
  token,
  from,
  value,
  validAfter,
  validBefore,
  signature,
}) {
  return {
    v: version,
    chain_id: chainId,
    token,
    from,
    value: Number(value),
    valid_after: Number(validAfter),
    valid_before: Number(validBefore),
    signature,
  };
}
