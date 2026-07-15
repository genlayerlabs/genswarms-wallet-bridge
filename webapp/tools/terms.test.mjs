import test from "node:test";
import assert from "node:assert/strict";
import { buildTermsEnvelope, buildTermsTypedData } from "../lib/terms.mjs";

const V_HASH = "0x" + "ab".repeat(32);
const ACCOUNT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";

test("buildTermsTypedData returns the exact terms acceptance payload", () => {
  assert.deepEqual(
    buildTermsTypedData({
      chainId: 84532,
      vHash: V_HASH,
      account: ACCOUNT,
      issuedAt: 1_750_000_000,
    }),
    {
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
        chainId: 84532,
      },
      message: {
        termsHash: V_HASH,
        account: ACCOUNT,
        issuedAt: "1750000000",
      },
    }
  );
});

test("buildTermsEnvelope returns the exact envelope and converts issuedAt", () => {
  const signature = "0x" + "11".repeat(32) + "22".repeat(32) + "1b";

  assert.deepEqual(
    buildTermsEnvelope({
      version: "0.4.0",
      chainId: 84532,
      vHash: V_HASH,
      account: ACCOUNT,
      issuedAt: "1750000000",
      signature,
    }),
    {
      v: "0.4.0",
      chain_id: 84532,
      v_hash: V_HASH,
      account: ACCOUNT,
      issued_at: 1_750_000_000,
      sig: {
        v: 27,
        r: "0x" + "11".repeat(32),
        s: "0x" + "22".repeat(32),
      },
    }
  );
});

test("buildTermsEnvelope inherits splitSignature normalization and rejection", () => {
  const input = {
    version: "0.4.0",
    chainId: 84532,
    vHash: V_HASH,
    account: ACCOUNT,
    issuedAt: 1_750_000_000,
  };
  const signature = (v) => "0x" + "11".repeat(32) + "22".repeat(32) + v;

  assert.equal(buildTermsEnvelope({ ...input, signature: signature("00") }).sig.v, 27);
  assert.equal(buildTermsEnvelope({ ...input, signature: signature("01") }).sig.v, 28);
  assert.throws(
    () => buildTermsEnvelope({ ...input, signature: "0x1234" }),
    /signature must be 65 bytes/
  );
});
