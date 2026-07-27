defmodule DelegatedSpend.Keeper.Eip3009 do
  @moduledoc """
  EIP-3009 `transferWithAuthorization`: dígito EIP-712 y calldata.

  Espejo deliberado de `DelegatedSpend.Keeper.PermitLane` — misma forma, otro
  typehash. Puro y sin estado: no lee configuración ni habla con la red.

  SIEMPRE la sobrecarga con la firma en `bytes` (`0xcf092995`). La variante
  `(v, r, s)` sólo sirve para wallets normales; ésta pasa por el verificador
  del token, que acepta además firmas de wallet-contrato (EIP-1271). Un camino
  para los dos casos.

  El `domain_separator` se LEE del contrato (`DOMAIN_SEPARATOR()`), nunca se
  recompone aquí: un dominio mal compuesto produce firmas que la cadena rechaza
  sin explicar por qué.
  """

  alias DelegatedSpend.Evm.{Abi, Address}
  alias DelegatedSpend.Keccak

  @typehash Keccak.hash_256(
              "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            )

  @domain_typehash Keccak.hash_256(
                     "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                   )

  # transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)
  # El selector ya no se escribe a mano: `Abi.encode_call/3` lo deriva de
  # name+types, así un typo no puede acuñar en silencio uno equivocado.
  # Valor esperado (para grep): 0xcf092995.
  @call_types [:address, :address, {:uint, 256}, {:uint, 256}, {:uint, 256}, {:bytes, 32}, :bytes]

  @doc "El typehash EIP-3009, expuesto para el vector dorado (spec §8)."
  def typehash, do: @typehash

  @spec authorization_digest(
          <<_::256>>,
          String.t(),
          String.t(),
          non_neg_integer,
          non_neg_integer,
          non_neg_integer,
          <<_::256>>
        ) :: <<_::256>>
  def authorization_digest(
        <<_::binary-size(32)>> = domain_separator,
        from,
        to,
        value,
        valid_after,
        valid_before,
        <<_::binary-size(32)>> = nonce
      ) do
    struct_hash =
      Keccak.hash_256(
        @typehash <>
          pad_address(from) <>
          pad_address(to) <>
          <<value::256>> <>
          <<valid_after::256>> <>
          <<valid_before::256>> <>
          nonce
      )

    Keccak.hash_256(<<0x19, 0x01>> <> domain_separator <> struct_hash)
  end

  @spec transfer_with_authorization_calldata(
          String.t(),
          String.t(),
          non_neg_integer,
          non_neg_integer,
          non_neg_integer,
          <<_::256>>,
          binary
        ) :: String.t()
  def transfer_with_authorization_calldata(
        from,
        to,
        value,
        valid_after,
        valid_before,
        <<_::binary-size(32)>> = nonce,
        signature
      )
      when is_binary(signature) do
    # 65 bytes = wallet normal. Las wallets-contrato firman longitudes
    # arbitrarias, así que no se fija un tamaño exacto: sólo se rechaza el
    # vacío, que nunca es una firma.
    if byte_size(signature) == 0 do
      raise ArgumentError, "transfer_with_authorization_calldata: firma vacía"
    end

    calldata =
      Abi.encode_call(
        "transferWithAuthorization",
        @call_types,
        [
          Address.to_bytes(from),
          Address.to_bytes(to),
          value,
          valid_after,
          valid_before,
          nonce,
          signature
        ]
      )

    "0x" <> Base.encode16(calldata, case: :lower)
  end

  @doc """
  The EIP-712 domain separator for `(name, version, chainId, verifyingContract)`
  — the same formula the token's own `DOMAIN_SEPARATOR()` computes on-chain.

  Exposed so the keeper can PROVE, at boot, that the `name()`/`version()` it
  just read from the token really are the domain's preimage (spec: do not
  serve an EIP-712 domain to the dapp without verifying it hashes to the
  separator read from the contract). Composing a domain that merely *looks*
  plausible and serving it produces signatures the chain silently rejects —
  see the moduledoc above.
  """
  @spec domain_separator(String.t(), String.t(), non_neg_integer, String.t()) :: <<_::256>>
  def domain_separator(name, version, chain_id, verifying_contract)
      when is_binary(name) and is_binary(version) and is_integer(chain_id) do
    Keccak.hash_256(
      @domain_typehash <>
        Keccak.hash_256(name) <>
        Keccak.hash_256(version) <>
        <<chain_id::256>> <>
        pad_address(verifying_contract)
    )
  end

  defp pad_address(addr), do: <<0::96>> <> Address.to_bytes(addr)
end
