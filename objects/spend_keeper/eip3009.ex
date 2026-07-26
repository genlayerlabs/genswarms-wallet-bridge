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

  alias DelegatedSpend.Evm.Address
  alias DelegatedSpend.Keccak

  @typehash Keccak.hash_256(
              "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            )

  # transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)
  @selector "cf092995"

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

    head =
      pad_address(from) <>
        pad_address(to) <>
        <<value::256>> <>
        <<valid_after::256>> <>
        <<valid_before::256>> <>
        nonce <>
        <<0xE0::256>>

    padded = pad_right_words(signature)
    body = head <> <<byte_size(signature)::256>> <> padded

    "0x" <> @selector <> Base.encode16(body, case: :lower)
  end

  defp pad_address(addr), do: <<0::96>> <> Address.to_bytes(addr)

  defp pad_right_words(bin) do
    case rem(byte_size(bin), 32) do
      0 -> bin
      r -> bin <> <<0::size((32 - r) * 8)>>
    end
  end
end
