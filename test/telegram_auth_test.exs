defmodule DelegatedSpend.TelegramAuthTest do
  use ExUnit.Case, async: true
  alias DelegatedSpend.Intake.TelegramAuth

  @bot_token "1234567:TEST-fake-bot-token-for-vectors"
  @now 1_800_000_000

  # Build initData the way Telegram does; the ALGORITHM is pinned by
  # Telegram's published spec — the negative vectors are the real checks.
  defp init_data(fields, token \\ @bot_token) do
    dcs =
      fields
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", token)
    hash = :crypto.mac(:hmac, :sha256, secret, dcs) |> Base.encode16(case: :lower)
    URI.encode_query(Map.put(fields, "hash", hash))
  end

  defp base_fields do
    %{
      "auth_date" => Integer.to_string(@now - 60),
      "query_id" => "AAF03",
      "user" => ~s({"id":777000111,"first_name":"A","username":"aa"})
    }
  end

  test "valid initData verifies and yields the numeric user id" do
    assert {:ok, %{user_id: 777_000_111}} =
             TelegramAuth.verify(init_data(base_fields()), @bot_token, 900, @now)
  end

  test "tampered user field fails closed" do
    data = init_data(base_fields())
    tampered = String.replace(data, "777000111", "666000000")
    assert {:error, :bad_hash} = TelegramAuth.verify(tampered, @bot_token, 900, @now)
  end

  test "signed with the wrong bot token fails closed" do
    data = init_data(base_fields(), "999:OTHER-token")
    assert {:error, :bad_hash} = TelegramAuth.verify(data, @bot_token, 900, @now)
  end

  test "stale auth_date fails closed (replay defense)" do
    fields = %{base_fields() | "auth_date" => Integer.to_string(@now - 10_000)}
    assert {:error, :stale} = TelegramAuth.verify(init_data(fields), @bot_token, 900, @now)
  end

  test "missing hash / missing user / garbage are malformed" do
    assert {:error, :malformed} =
             TelegramAuth.verify(URI.encode_query(base_fields()), @bot_token, 900, @now)

    no_user = init_data(Map.delete(base_fields(), "user"))
    assert {:error, :malformed} = TelegramAuth.verify(no_user, @bot_token, 900, @now)

    assert {:error, _} = TelegramAuth.verify("not=even&valid", @bot_token, 900, @now)
    assert {:error, :malformed} = TelegramAuth.verify(nil, @bot_token, 900, @now)
  end

  test "hash comparison rejects truncated attacker hash without crashing" do
    data = URI.encode_query(Map.put(base_fields(), "hash", "abcd"))
    assert {:error, :bad_hash} = TelegramAuth.verify(data, @bot_token, 900, @now)
  end

  test "validly-hashed payload MISSING auth_date is malformed (freshness cannot be skipped)" do
    # auth_date deleted BEFORE signing: the hash is valid over the remaining
    # fields, so this pins that verify still fails closed on the absent field.
    data = init_data(Map.delete(base_fields(), "auth_date"))
    assert {:error, :malformed} = TelegramAuth.verify(data, @bot_token, 900, @now)
  end

  test "validly-hashed non-numeric auth_date is malformed" do
    fields = %{base_fields() | "auth_date" => "notanumber"}
    assert {:error, :malformed} = TelegramAuth.verify(init_data(fields), @bot_token, 900, @now)

    # trailing garbage after the digits must also reject (strict Integer.parse)
    fields = %{base_fields() | "auth_date" => "1800x"}
    assert {:error, :malformed} = TelegramAuth.verify(init_data(fields), @bot_token, 900, @now)
  end

  test "validly-hashed malformed user JSON is malformed" do
    fields = %{base_fields() | "user" => ~s({"id":"not-integer"})}
    assert {:error, :malformed} = TelegramAuth.verify(init_data(fields), @bot_token, 900, @now)
  end

  test "extra Telegram fields are covered by the data-check-string (all fields except hash)" do
    # Pins the "every field except hash" construction against field-set drift:
    # Telegram adds fields like chat_type/chat_instance/signature over time and
    # they MUST be part of the signed data-check-string, not silently dropped.
    fields =
      Map.merge(base_fields(), %{
        "chat_type" => "private",
        "chat_instance" => "12345",
        "signature" => "abc"
      })

    assert {:ok, %{user_id: 777_000_111}} =
             TelegramAuth.verify(init_data(fields), @bot_token, 900, @now)
  end

  test "future-dated auth_date is currently ACCEPTED (pinned behavior)" do
    # AUDIT NOTE: check_fresh only enforces `now - auth_date <= max_age_s`, so a
    # future auth_date (now - ts is negative) passes freshness. This test pins
    # the current behavior; tightening it would be a deliberate change.
    fields = %{base_fields() | "auth_date" => Integer.to_string(@now + 100)}

    assert {:ok, %{user_id: 777_000_111}} =
             TelegramAuth.verify(init_data(fields), @bot_token, 900, @now)
  end
end
