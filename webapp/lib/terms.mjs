import { splitSignature } from "./permit.mjs";

/** EIP-712 typed data for accepting the pinned terms version. */
export function buildTermsTypedData({ chainId, vHash, account, issuedAt }) {
  return {
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "uint256" },
      ],
      TermsAcceptance: [
        { name: "termsHash", type: "bytes32" },
        { name: "account", type: "address" },
        { name: "issuedAt", type: "uint256" },
      ],
    },
    primaryType: "TermsAcceptance",
    domain: {
      name: "genswarms-wallet-bridge/terms",
      version: "1",
      chainId,
    },
    message: {
      termsHash: vHash,
      account,
      issuedAt: String(issuedAt),
    },
  };
}

/** Acceptance envelope posted to the intake terms endpoint. */
export function buildTermsEnvelope({ version, chainId, vHash, account, issuedAt, signature }) {
  return {
    v: version,
    chain_id: chainId,
    v_hash: vHash,
    account,
    issued_at: Number(issuedAt),
    sig: splitSignature(signature),
  };
}
