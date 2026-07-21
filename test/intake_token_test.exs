defmodule DelegatedSpend.Intake.TokenTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Intake.Token

  @secret "test-secret-material"
  @ref String.duplicate("ab", 32)
  @user_ref "0x" <> String.duplicate("11", 32)

  test "mint/verify round-trip returns the user_ref" do
    token = Token.mint(@secret, @ref, @user_ref, 2_000_000_000)
    assert {:ok, @user_ref} = Token.verify(@secret, @ref, token, 1_999_999_999)
  end

  test "opaque user_ref may contain token delimiters" do
    user_ref = "acct.user/123"
    token = Token.mint(@secret, @ref, user_ref, 2_000_000_000)
    assert {:ok, ^user_ref} = Token.verify(@secret, @ref, token, 1_999_999_999)
  end

  test "empty opaque user_ref round-trips" do
    token = Token.mint(@secret, @ref, "", 2_000_000_000)
    assert {:ok, ""} = Token.verify(@secret, @ref, token, 1_999_999_999)
  end

  test "expired token is rejected as :expired" do
    token = Token.mint(@secret, @ref, @user_ref, 1_000)
    assert {:error, :expired} = Token.verify(@secret, @ref, token, 1_001)
  end

  test "token minted for one ref does not open another ref" do
    token = Token.mint(@secret, @ref, @user_ref, 2_000_000_000)
    other_ref = String.duplicate("cd", 32)
    assert {:error, :bad_token} = Token.verify(@secret, other_ref, token, 0)
  end

  test "tampered user_ref, exp, or mac is rejected" do
    token = Token.mint(@secret, @ref, @user_ref, 2_000_000_000)
    [v, exp, ur, mac] = String.split(token, ".")

    assert {:error, :bad_token} =
             Token.verify(@secret, @ref, Enum.join([v, "2000000001", ur, mac], "."), 0)

    assert {:error, :bad_token} =
             Token.verify(
               @secret,
               @ref,
               Enum.join([v, exp, "0x" <> String.duplicate("22", 32), mac], "."),
               0
             )

    assert {:error, :bad_token} =
             Token.verify(
               @secret,
               @ref,
               Enum.join([v, exp, ur, String.duplicate("0", 64)], "."),
               0
             )
  end

  test "wrong secret and malformed tokens are :bad_token, never a crash" do
    token = Token.mint(@secret, @ref, @user_ref, 2_000_000_000)
    assert {:error, :bad_token} = Token.verify("other-secret", @ref, token, 0)

    for bad <- [
          nil,
          42,
          "",
          "v1",
          "v2.1.2.3",
          "v1.x.y.z",
          "v1.1.short",
          "v1.1." <> String.duplicate("a", 65)
        ] do
      assert {:error, :bad_token} = Token.verify(@secret, @ref, bad, 0)
    end

    assert {:error, :bad_token} = Token.verify(:not_binary_secret, @ref, token, 0)
  end
end
