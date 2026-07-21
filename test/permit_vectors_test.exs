defmodule DelegatedSpend.PermitVectorsTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.Intake.GrantValidation
  alias DelegatedSpend.Keccak
  alias DelegatedSpend.Keeper.PermitLane

  @moduledoc """
  Elixir leg of the 3-language golden-vector cross-check (spec §8): recompute
  the EIP-2612 digest with the keeper's own primitives, recover the signer,
  and accept the wallet dapp's envelope through the intake's strict validation.
  """

  @vectors_dir Path.expand(Path.join([__DIR__, "..", "vectors", "permit"]))
  @package_version File.read!("VERSION") |> String.trim()

  defp vectors do
    @vectors_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  defp domain_separator(%{
         "name" => name,
         "version" => version,
         "chain_id" => cid,
         "token" => token
       }) do
    Keccak.hash_256(
      Keccak.hash_256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
      ) <>
        Keccak.hash_256(name) <>
        Keccak.hash_256(version) <>
        <<cid::256>> <>
        <<0::96>> <> Address.to_bytes(token)
    )
  end

  defp unhex("0x" <> h), do: Base.decode16!(h, case: :mixed)

  test "vectors exist (generator ran) and pin package version" do
    vs = vectors()
    assert length(vs) == 3
    assert Enum.all?(vs, &(&1["version"] == @package_version))
    assert Enum.all?(vs, &(&1["account_state"] == "eoa"))
  end

  test "digest recompute + signer recovery: keeper primitives agree with JS + cast" do
    for v <- vectors() do
      p = v["permit"]
      ds = domain_separator(v["domain"])

      digest =
        PermitLane.permit_digest(
          ds,
          p["owner"],
          p["spender"],
          p["value"],
          p["nonce"],
          p["deadline"]
        )

      sig = v["signature"]
      recid = sig["v"] - 27
      <<4, pub::binary>> = Secp256k1.recover(digest, unhex(sig["r"]), unhex(sig["s"]), recid)

      recovered =
        "0x" <> (pub |> Keccak.hash_256() |> binary_part(12, 20) |> Base.encode16(case: :lower))

      assert recovered == String.downcase(p["owner"]),
             "vector digest must recover the owner (JS typed-data ↔ Elixir digest agreement)"
    end
  end

  test "envelopes pass the intake's strict validation against matching pinned config" do
    for v <- vectors() do
      pinned = %{
        chain_id: v["domain"]["chain_id"],
        token: v["domain"]["token"],
        router: v["permit"]["spender"],
        version: v["version"]
      }

      assert {:ok, permit} = GrantValidation.validate_permit(v["envelope"], pinned)
      assert permit.value == v["permit"]["value"]
      assert byte_size(permit.r) == 32 and byte_size(permit.s) == 32
    end
  end

  test "envelopes REJECT against any other pinned config (strict validation bites)" do
    [v | _] = vectors()

    base = %{
      chain_id: v["domain"]["chain_id"],
      token: v["domain"]["token"],
      router: v["permit"]["spender"],
      version: v["version"]
    }

    assert {:error, {:pinned_mismatch, :chain_id}} =
             GrantValidation.validate_permit(v["envelope"], %{base | chain_id: 8_453})

    assert {:error, {:pinned_mismatch, :spender}} =
             GrantValidation.validate_permit(v["envelope"], %{
               base
               | router: "0x000000000000000000000000000000000000cccc"
             })
  end

  test "a tampered signature no longer recovers the owner" do
    [v | _] = vectors()
    p = v["permit"]
    ds = domain_separator(v["domain"])

    digest =
      PermitLane.permit_digest(
        ds,
        p["owner"],
        p["spender"],
        p["value"],
        p["nonce"],
        p["deadline"]
      )

    sig = v["signature"]
    <<first, rest::binary>> = unhex(sig["r"])
    tampered_r = <<first + 1, rest::binary>>

    recovered =
      case Secp256k1.recover(digest, tampered_r, unhex(sig["s"]), sig["v"] - 27) do
        <<4, pub::binary>> ->
          "0x" <> (pub |> Keccak.hash_256() |> binary_part(12, 20) |> Base.encode16(case: :lower))

        _ ->
          :invalid
      end

    refute recovered == String.downcase(p["owner"])
  end
end
