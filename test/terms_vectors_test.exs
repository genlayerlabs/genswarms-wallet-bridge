defmodule DelegatedSpend.TermsVectorsTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Compliance.Terms

  @vectors_dir Path.expand(Path.join([__DIR__, "..", "vectors", "terms"]))
  @package_version File.read!("VERSION") |> String.trim()

  defp vector_files, do: @vectors_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
  defp vectors, do: Enum.map(vector_files(), &(&1 |> File.read!() |> Jason.decode!()))
  defp unhex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)

  test "exactly the three EOA vectors exist and pin the package version" do
    assert Enum.map(vector_files(), &Path.basename/1) == [
             "terms-eoa-1.json",
             "terms-eoa-alt-hash.json",
             "terms-eoa-issued-at.json"
           ]

    assert Enum.all?(vectors(), &(&1["version"] == @package_version))
    assert Enum.all?(vectors(), &(&1["account_state"] == "eoa"))
  end

  test "Elixir digest and signer recovery agree with JS typed data signed by cast" do
    for vector <- vectors() do
      acceptance = vector["acceptance"]
      signature = vector["signature"]

      digest =
        Terms.digest(
          vector["domain"]["chain_id"],
          acceptance["terms_hash"],
          acceptance["account"],
          acceptance["issued_at"]
        )

      assert {:ok, recovered} =
               Terms.recover_signer(
                 digest,
                 signature["v"],
                 unhex(signature["r"]),
                 unhex(signature["s"])
               )

      assert String.downcase(recovered) == String.downcase(acceptance["account"])
    end
  end

  test "generated envelopes verify and normalize into exact evidence" do
    for vector <- vectors() do
      acceptance = vector["acceptance"]
      signature = vector["signature"]

      assert Terms.verify_acceptance(
               vector["envelope"],
               %{hash: acceptance["terms_hash"]},
               %{chain_id: vector["domain"]["chain_id"], version: vector["version"]},
               acceptance["issued_at"]
             ) ==
               {:ok,
                %{
                  v_hash: acceptance["terms_hash"],
                  account: acceptance["account"],
                  issued_at: acceptance["issued_at"],
                  sig: %{
                    v: signature["v"],
                    r: signature["r"],
                    s: signature["s"]
                  }
                }}
    end
  end

  test "strict acceptance rejects drift, stale terms, and a tampered signature" do
    assert [vector | _] = vectors()
    envelope = vector["envelope"]
    acceptance = vector["acceptance"]
    pinned = %{chain_id: vector["domain"]["chain_id"], version: vector["version"]}
    current_terms = %{hash: acceptance["terms_hash"]}
    now_s = acceptance["issued_at"]

    assert Terms.verify_acceptance(
             Map.put(envelope, "v", vector["version"] <> "-tampered"),
             current_terms,
             pinned,
             now_s
           ) == {:error, {:pinned_mismatch, :version}}

    assert Terms.verify_acceptance(
             Map.put(envelope, "chain_id", pinned.chain_id + 1),
             current_terms,
             pinned,
             now_s
           ) == {:error, {:pinned_mismatch, :chain_id}}

    assert Terms.verify_acceptance(
             envelope,
             %{hash: "0x" <> String.duplicate("ff", 32)},
             pinned,
             now_s
           ) == {:error, :terms_stale}

    tampered = put_in(envelope, ["sig", "r"], "0x" <> String.duplicate("00", 32))

    assert Terms.verify_acceptance(tampered, current_terms, pinned, now_s) ==
             {:error, {:invalid, :sig}}
  end

  test "typed-data domain has exactly name, version, and chainId" do
    for vector <- vectors() do
      typed_data = vector["typed_data"]

      assert typed_data["types"]["EIP712Domain"] == [
               %{"name" => "name", "type" => "string"},
               %{"name" => "version", "type" => "string"},
               %{"name" => "chainId", "type" => "uint256"}
             ]

      assert typed_data["domain"] == %{
               "name" => "genswarms-wallet-bridge/terms",
               "version" => "1",
               "chainId" => 31_337
             }

      refute Map.has_key?(typed_data["domain"], "verifyingContract")
    end
  end
end
