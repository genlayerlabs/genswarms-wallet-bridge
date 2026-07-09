defmodule DelegatedSpend.Intake.Token do
  @moduledoc """
  Ref-scoped access tokens for wallet dapp entry URLs.

  Format: `v1.<expires_at>.<user_ref>.<hex HMAC-SHA256>`.
  """

  @doc "Mint a token for `ref` carrying opaque `user_ref` until `expires_at`."
  def mint(secret, ref, user_ref, expires_at)
      when is_binary(secret) and is_binary(ref) and is_binary(user_ref) and is_integer(expires_at) do
    "v1.#{expires_at}.#{user_ref}." <> mac(secret, ref, user_ref, expires_at)
  end

  @doc "Verify a token against `ref`; returns `{:ok, user_ref}` or `{:error, reason}`."
  def verify(secret, ref, token, now_s \\ System.os_time(:second))

  def verify(secret, ref, token, now_s) when is_binary(token) do
    with ["v1", exp_s, rest] <- String.split(token, ".", parts: 3),
         {exp, ""} <- Integer.parse(exp_s),
         {:ok, user_ref, mac_hex} <- split_user_ref_and_mac(rest),
         expected = mac(secret, ref, user_ref, exp),
         true <- byte_size(mac_hex) == byte_size(expected),
         true <- :crypto.hash_equals(mac_hex, expected) do
      if now_s <= exp, do: {:ok, user_ref}, else: {:error, :expired}
    else
      _ -> {:error, :bad_token}
    end
  rescue
    _ -> {:error, :bad_token}
  end

  def verify(_, _, _, _), do: {:error, :bad_token}

  defp split_user_ref_and_mac(rest) when is_binary(rest) and byte_size(rest) >= 65 do
    user_ref_size = byte_size(rest) - 65

    case rest do
      <<user_ref::binary-size(user_ref_size), ".", mac_hex::binary-size(64)>> ->
        {:ok, user_ref, mac_hex}

      _ ->
        {:error, :bad_token}
    end
  end

  defp split_user_ref_and_mac(_), do: {:error, :bad_token}

  defp mac(secret, ref, user_ref, expires_at) do
    :crypto.mac(:hmac, :sha256, secret, "spend-token\n#{ref}\n#{user_ref}\n#{expires_at}")
    |> Base.encode16(case: :lower)
  end
end
