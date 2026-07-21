defmodule DelegatedSpend.GrantValidationTest do
  use ExUnit.Case, async: true
  alias DelegatedSpend.Intake.GrantValidation

  @pinned %{
    chain_id: 84_532,
    token: "0x0000000000000000000000000000000000000AaA",
    router: "0x0000000000000000000000000000000000000BbB",
    version: "0.2.0"
  }

  defp env(overrides \\ %{}) do
    Map.merge(
      %{
        "v" => "0.2.0",
        "chain_id" => 84_532,
        "token" => "0x0000000000000000000000000000000000000aaa",
        "spender" => "0x0000000000000000000000000000000000000bbb",
        "owner" => "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        "value" => 25_000_000,
        "deadline" => 4_000_000_000,
        "sig" => %{
          "v" => 27,
          "r" => "0x" <> String.duplicate("11", 32),
          "s" => "0x" <> String.duplicate("22", 32)
        }
      },
      overrides
    )
  end

  test "valid envelope passes and maps to the PermitLane shape" do
    assert {:ok, permit} = GrantValidation.validate_permit(env(), @pinned)
    assert permit.owner == "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    assert permit.value == 25_000_000
    assert {permit.v, byte_size(permit.r), byte_size(permit.s)} == {27, 32, 32}
  end

  test "every pinned field rejects on mismatch — byte-for-byte config match" do
    for {key, bad, field} <- [
          {"v", "0.0.9", :version},
          {"chain_id", 8_453, :chain_id},
          {"token", "0x0000000000000000000000000000000000000ccc", :token},
          {"spender", "0x0000000000000000000000000000000000000ccc", :spender}
        ] do
      assert {:error, {:pinned_mismatch, ^field}} =
               GrantValidation.validate_permit(env(%{key => bad}), @pinned)
    end
  end

  test "address case differences are NOT a mismatch (EIP-55 vs lowercase)" do
    assert {:ok, _} =
             GrantValidation.validate_permit(
               env(%{"token" => "0x0000000000000000000000000000000000000AAA"}),
               @pinned
             )
  end

  test "invalid values reject: zero/negative amount, bad deadline, bad sig shapes" do
    assert {:error, {:invalid, :value}} =
             GrantValidation.validate_permit(env(%{"value" => 0}), @pinned)

    assert {:error, {:invalid, :value}} =
             GrantValidation.validate_permit(env(%{"value" => "25"}), @pinned)

    assert {:error, {:invalid, :deadline}} =
             GrantValidation.validate_permit(env(%{"deadline" => -1}), @pinned)

    for bad_sig <- [
          %{
            "v" => 26,
            "r" => "0x" <> String.duplicate("11", 32),
            "s" => "0x" <> String.duplicate("22", 32)
          },
          %{"v" => 27, "r" => "0x1111", "s" => "0x" <> String.duplicate("22", 32)},
          %{
            "v" => 27,
            "r" => String.duplicate("11", 32),
            "s" => "0x" <> String.duplicate("22", 32)
          },
          %{},
          nil
        ] do
      assert {:error, {:invalid, :sig}} =
               GrantValidation.validate_permit(env(%{"sig" => bad_sig}), @pinned)
    end
  end

  test "owner must be a well-formed address" do
    assert {:error, {:invalid, :owner}} =
             GrantValidation.validate_permit(env(%{"owner" => "0xzz"}), @pinned)
  end

  test "non-map envelope rejects" do
    assert {:error, {:invalid, :envelope}} = GrantValidation.validate_permit(nil, @pinned)
  end

  test "malformed pinned-field values route through the addr validator, not pinned_mismatch" do
    # too-short token: rejected as {:invalid, :token} (shape check runs BEFORE
    # the pinned comparison — a garbage address never reads as "mismatch")
    assert {:error, {:invalid, :token}} =
             GrantValidation.validate_permit(env(%{"token" => "0x1234"}), @pinned)

    # non-binary spender
    assert {:error, {:invalid, :spender}} =
             GrantValidation.validate_permit(env(%{"spender" => 42}), @pinned)
  end

  test "owner without 0x prefix rejects as invalid" do
    assert {:error, {:invalid, :owner}} =
             GrantValidation.validate_permit(
               env(%{"owner" => "f39Fd6e51aad88F6F4ce6aB8827279cffFb92266"}),
               @pinned
             )
  end

  test "sig with wrong-length s rejects" do
    bad_sig = %{"v" => 27, "r" => "0x" <> String.duplicate("11", 32), "s" => "0x1111"}

    assert {:error, {:invalid, :sig}} =
             GrantValidation.validate_permit(env(%{"sig" => bad_sig}), @pinned)
  end

  test "sig v=28 branch is accepted and propagated" do
    sig = %{
      "v" => 28,
      "r" => "0x" <> String.duplicate("11", 32),
      "s" => "0x" <> String.duplicate("22", 32)
    }

    assert {:ok, permit} = GrantValidation.validate_permit(env(%{"sig" => sig}), @pinned)
    assert permit.v == 28
  end
end
