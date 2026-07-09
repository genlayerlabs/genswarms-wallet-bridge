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
end
