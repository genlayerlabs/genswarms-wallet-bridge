defmodule DelegatedSpend.Compliance.Terms do
  @moduledoc "Pure EIP-712 hashing and verification for terms acceptance evidence."

  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.Keccak

  @domain_typehash Keccak.hash_256("EIP712Domain(string name,string version,uint256 chainId)")
  @name_hash Keccak.hash_256("genswarms-wallet-bridge/terms")
  @version_hash Keccak.hash_256("1")
  @acceptance_typehash Keccak.hash_256(
                         "TermsAcceptance(bytes32 termsHash,address account,uint256 issuedAt)"
                       )
  @max_uint256 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  @secp256k1_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  @doc "Keccak-256 of the exact terms document bytes as canonical `0x` hex."
  def hash_terms(text) when is_binary(text), do: encode_hex(Keccak.hash_256(text))

  @doc "Raw EIP-712 domain separator for the pinned chain ID."
  def domain_separator(chain_id) do
    ensure_uint256!(chain_id, :chain_id)
    Keccak.hash_256(@domain_typehash <> @name_hash <> @version_hash <> <<chain_id::256>>)
  end

  @doc "Raw EIP-712 terms-acceptance digest."
  def digest(chain_id, terms_hash, account, issued_at) do
    terms_hash = decode_hex32!(terms_hash, :terms_hash)
    account = decode_address!(account)
    ensure_uint256!(issued_at, :issued_at)

    struct_hash =
      Keccak.hash_256(
        @acceptance_typehash <> terms_hash <> <<0::96>> <> account <> <<issued_at::256>>
      )

    Keccak.hash_256(<<0x19, 0x01>> <> domain_separator(chain_id) <> struct_hash)
  end

  @doc "Recover the EIP-55 signer of a raw digest, shielding invalid EC arithmetic."
  def recover_signer(
        <<_::binary-size(32)>> = digest,
        v,
        <<_::binary-size(32)>> = r,
        <<_::binary-size(32)>> = s
      )
      when v in [27, 28] do
    if valid_scalar?(r) and valid_scalar?(s) do
      try do
        case Secp256k1.recover(digest, r, s, v - 27) do
          <<4, public_key::binary-size(64)>> ->
            address = public_key |> Keccak.hash_256() |> binary_part(12, 20) |> Address.checksum()
            {:ok, address}

          _ ->
            {:error, :invalid_signature}
        end
      rescue
        _ -> {:error, :invalid_signature}
      catch
        _, _ -> {:error, :invalid_signature}
      end
    else
      {:error, :invalid_signature}
    end
  end

  def recover_signer(_, _, _, _), do: {:error, :invalid_signature}

  @doc "Strictly verify a client terms-acceptance envelope and normalize its evidence."
  def verify_acceptance(
        envelope,
        %{hash: current_hash},
        %{version: version, chain_id: chain_id},
        now_s
      )
      when is_map(envelope) and is_integer(now_s) do
    with :ok <- validate_version(envelope["v"], version),
         :ok <- validate_chain_id(envelope["chain_id"], chain_id),
         {:ok, _hash_bytes, v_hash} <- decode_hex32(envelope["v_hash"], :v_hash),
         :ok <- validate_current_hash(v_hash, current_hash),
         {:ok, account_bytes, account} <- decode_address(envelope["account"], :account),
         :ok <- reject_zero_address(account_bytes),
         {:ok, issued_at} <- validate_issued_at(envelope["issued_at"], now_s),
         {:ok, sig} <- decode_signature(envelope["sig"]),
         digest = digest(chain_id, v_hash, account, issued_at),
         :ok <- validate_signer(digest, sig, account) do
      {:ok,
       %{
         v_hash: v_hash,
         account: account,
         issued_at: issued_at,
         sig: %{v: sig.v, r: sig.r_hex, s: sig.s_hex}
       }}
    end
  end

  def verify_acceptance(_, _, _, _), do: {:error, {:invalid, :envelope}}

  defp validate_version(got, expected) when is_binary(got) do
    if got == expected, do: :ok, else: {:error, {:pinned_mismatch, :version}}
  end

  defp validate_version(_, _), do: {:error, {:invalid, :version}}

  defp validate_chain_id(got, expected) do
    cond do
      not uint256?(got) -> {:error, {:invalid, :chain_id}}
      got != expected -> {:error, {:pinned_mismatch, :chain_id}}
      true -> :ok
    end
  end

  defp validate_current_hash(v_hash, current_hash) do
    case decode_hex32(current_hash, :v_hash) do
      {:ok, _, ^v_hash} -> :ok
      {:ok, _, _} -> {:error, :terms_stale}
      error -> error
    end
  end

  defp reject_zero_address(<<0::160>>), do: {:error, {:invalid, :account}}
  defp reject_zero_address(_), do: :ok

  defp validate_issued_at(value, now_s) do
    if uint256?(value) and value >= now_s - 900 and value <= now_s + 300,
      do: {:ok, value},
      else: {:error, {:invalid, :issued_at}}
  end

  defp decode_signature(%{"v" => v, "r" => r, "s" => s}) when v in [27, 28] do
    with {:ok, r, r_hex} <- decode_hex32(r, :sig),
         {:ok, s, s_hex} <- decode_hex32(s, :sig) do
      {:ok, %{v: v, r: r, s: s, r_hex: r_hex, s_hex: s_hex}}
    end
  end

  defp decode_signature(_), do: {:error, {:invalid, :sig}}

  defp validate_signer(digest, sig, account) do
    case recover_signer(digest, sig.v, sig.r, sig.s) do
      {:ok, recovered} ->
        if Address.eq?(recovered, account), do: :ok, else: {:error, {:invalid, :sig}}

      {:error, _} ->
        {:error, {:invalid, :sig}}
    end
  end

  defp decode_hex32("0x" <> hex, field) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes, encode_hex(bytes)}
      :error -> {:error, {:invalid, field}}
    end
  end

  defp decode_hex32(_, field), do: {:error, {:invalid, field}}

  defp decode_address("0x" <> hex, field) when byte_size(hex) == 40 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes, Address.checksum(bytes)}
      :error -> {:error, {:invalid, field}}
    end
  end

  defp decode_address(_, field), do: {:error, {:invalid, field}}

  defp decode_hex32!(value, field) do
    case decode_hex32(value, field) do
      {:ok, bytes, _} -> bytes
      _ -> raise ArgumentError, "invalid #{field}"
    end
  end

  defp decode_address!(value) do
    case decode_address(value, :account) do
      {:ok, bytes, _} -> bytes
      _ -> raise ArgumentError, "invalid account"
    end
  end

  defp ensure_uint256!(value, field) do
    unless uint256?(value), do: raise(ArgumentError, "invalid #{field}")
  end

  defp uint256?(value), do: is_integer(value) and value >= 0 and value <= @max_uint256

  defp valid_scalar?(bytes) do
    scalar = :binary.decode_unsigned(bytes)
    scalar > 0 and scalar < @secp256k1_order
  end

  defp encode_hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
end
