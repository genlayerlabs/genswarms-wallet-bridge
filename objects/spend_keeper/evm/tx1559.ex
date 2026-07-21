defmodule DelegatedSpend.Evm.Tx1559 do
  @moduledoc """
  EIP-1559 (type-2) transaction signing — the keeper's money path. Pure given
  inputs (no network). Mirrors the conventions of the production-proven
  legacy (type-0) signer this chain layer was ported from (minimal big-endian
  ints, empty string for :create, raw-bytes data), with the type-2 envelope:

    1. `payload = rlp([chain_id, nonce, max_priority_fee, max_fee, gas, to,
       value, data, access_list=[]])`
    2. `digest = keccak256(0x02 ‖ payload)`
    3. `{r, s, recid} = secp256k1_sign(digest, priv)` — yParity IS recid
       (no EIP-155 arithmetic in type-2).
    4. `raw = 0x02 ‖ rlp([...payload fields..., recid, r, s])`;
       tx hash = `keccak256(raw)`.
  """

  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.Keccak

  @doc """
  Sign a type-2 tx. `params`: `nonce, max_priority_fee, max_fee, gas, to, value,
  data, chain_id`. `:to` is `:create` (deploy), an `0x…` address string, or 20
  raw bytes. `:data` is raw bytes. Returns `{raw_hex, tx_hash_hex}`.
  """
  def sign(params, priv) when is_binary(priv) do
    %{
      nonce: nonce,
      max_priority_fee: prio,
      max_fee: max_fee,
      gas: gas,
      to: to,
      value: value,
      data: data,
      chain_id: cid
    } = params

    fields = [cid, nonce, prio, max_fee, gas, to_field(to), value, data, []]
    digest = Keccak.hash_256(<<2>> <> ExRLP.encode(fields))
    {r, s, recid} = Secp256k1.sign(digest, priv)

    signed =
      <<2>> <>
        ExRLP.encode(fields ++ [recid, :binary.decode_unsigned(r), :binary.decode_unsigned(s)])

    {"0x" <> Base.encode16(signed, case: :lower),
     "0x" <> Base.encode16(Keccak.hash_256(signed), case: :lower)}
  end

  # Empty string for a contract creation; 20 raw bytes for a call.
  defp to_field(:create), do: ""
  defp to_field(<<_::binary-size(20)>> = bin), do: bin
  defp to_field(addr) when is_binary(addr), do: Address.to_bytes(addr)
end
