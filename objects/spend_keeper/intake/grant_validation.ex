defmodule DelegatedSpend.Intake.GrantValidation do
  @moduledoc """
  Strict grant validation (spec §6.1, §10 do-not-weaken): every submitted
  envelope is validated byte-for-byte against the app's PINNED config and
  rejected on any mismatch. Whatever a (possibly compromised) wallet dapp
  served, our keeper can never store or act on a grant shaped for any other
  chain, token, or router.
  """

  @doc """
  Validate a permit envelope against `pinned = %{chain_id:, token:, router:, version:}`.
  Envelope (client JSON, string keys):
  `%{"v" => version, "chain_id" => int, "token" => addr, "spender" => addr,
     "owner" => addr, "value" => int, "deadline" => int,
     "sig" => %{"v" => 27|28, "r" => 0xhex32, "s" => 0xhex32}}`
  Returns `{:ok, permit_map} | {:error, {:pinned_mismatch, field} | {:invalid, field}}`
  where `permit_map` is the `DelegatedSpend.Keeper.PermitLane` shape.
  """
  def validate_permit(env, pinned) when is_map(env) and is_map(pinned) do
    with :ok <- pin(env["v"], pinned.version, :version),
         :ok <- pin(env["chain_id"], pinned.chain_id, :chain_id),
         :ok <- pin_addr(env["token"], pinned.token, :token),
         :ok <- pin_addr(env["spender"], pinned.router, :spender),
         {:ok, owner} <- addr(env["owner"], :owner),
         {:ok, value} <- pos_int(env["value"], :value),
         {:ok, deadline} <- pos_int(env["deadline"], :deadline),
         {:ok, {v, r, s}} <- sig(env["sig"]) do
      {:ok, %{owner: owner, value: value, deadline: deadline, v: v, r: r, s: s}}
    end
  end

  def validate_permit(_, _), do: {:error, {:invalid, :envelope}}

  defp pin(got, expected, _field) when got == expected, do: :ok
  defp pin(_got, _expected, field), do: {:error, {:pinned_mismatch, field}}

  defp pin_addr(got, expected, field) do
    with {:ok, g} <- addr(got, field) do
      if String.downcase(g) == String.downcase(expected),
        do: :ok,
        else: {:error, {:pinned_mismatch, field}}
    end
  end

  defp addr("0x" <> hex = a, field) do
    case byte_size(hex) == 40 and match?({:ok, _}, Base.decode16(hex, case: :mixed)) do
      true -> {:ok, a}
      false -> {:error, {:invalid, field}}
    end
  end

  defp addr(_, field), do: {:error, {:invalid, field}}

  defp pos_int(n, _field) when is_integer(n) and n > 0, do: {:ok, n}
  defp pos_int(_, field), do: {:error, {:invalid, field}}

  defp sig(%{"v" => v, "r" => "0x" <> r_hex, "s" => "0x" <> s_hex}) when v in [27, 28] do
    with {:ok, r} when byte_size(r) == 32 <- Base.decode16(r_hex, case: :mixed),
         {:ok, s} when byte_size(s) == 32 <- Base.decode16(s_hex, case: :mixed) do
      {:ok, {v, r, s}}
    else
      _ -> {:error, {:invalid, :sig}}
    end
  end

  defp sig(_), do: {:error, {:invalid, :sig}}

  @doc """
  Validate an EIP-3009 authorization envelope against
  `pinned = %{chain_id:, token:, router:, version:}` — the `router` pin is
  UNUSED here: this lane calls the token directly and never touches the
  router. Envelope (client JSON, string keys):
  `%{"v" => version, "chain_id" => int, "token" => addr, "from" => addr,
     "value" => int, "valid_after" => int, "valid_before" => int,
     "signature" => "0x…"}`

  There is deliberately no `"to"` field in this shape, and none is read even
  if a client sends one: the destination is the keeper's own
  `:treasury_address`, set server-side (see `DelegatedSpend.Keeper`) — a
  client-supplied `to` must never be given any authority, not even the
  authority to be parsed.

  Returns `{:ok, auth_map} | {:error, {:pinned_mismatch, field} | {:invalid, field}}`
  where `auth_map` is the `DelegatedSpend.Keeper.execute_with_authorization/4`
  shape: `%{from:, value:, valid_after:, valid_before:, signature:}`.
  """
  def validate_authorization(env, pinned) when is_map(env) and is_map(pinned) do
    with :ok <- pin(env["v"], pinned.version, :version),
         :ok <- pin(env["chain_id"], pinned.chain_id, :chain_id),
         :ok <- pin_addr(env["token"], pinned.token, :token),
         {:ok, from} <- addr(env["from"], :from),
         {:ok, value} <- pos_int(env["value"], :value),
         {:ok, valid_after} <- nonneg_int(env["valid_after"], :valid_after),
         {:ok, valid_before} <- pos_int(env["valid_before"], :valid_before),
         {:ok, signature} <- signature_bytes(env["signature"]) do
      {:ok,
       %{
         from: from,
         value: value,
         valid_after: valid_after,
         valid_before: valid_before,
         signature: signature
       }}
    end
  end

  def validate_authorization(_, _), do: {:error, {:invalid, :envelope}}

  defp nonneg_int(n, _field) when is_integer(n) and n >= 0, do: {:ok, n}
  defp nonneg_int(_, field), do: {:error, {:invalid, field}}

  # Arbitrary-length, non-empty: a wallet-contract (EIP-1271) signature is
  # not fixed at 65 bytes (mirrors Eip3009.transfer_with_authorization_calldata's
  # own only-reject-empty rule) — shape-checking a fixed length here would
  # reject a legitimate smart-wallet signer.
  defp signature_bytes("0x" <> hex) when byte_size(hex) > 0 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      _ -> {:error, {:invalid, :signature}}
    end
  end

  defp signature_bytes(_), do: {:error, {:invalid, :signature}}
end
