defmodule DelegatedSpend.Compliance.TermsTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias DelegatedSpend.Compliance.Terms
  alias DelegatedSpend.Evm.{Address, Secp256k1}

  @private_key Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @other_private_key <<2::256>>
  @account "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @chain_id 84_532
  @now 1_700_000_000
  @version "0.4.0"
  @terms_hash "0x05ec2d1346c2f47de055470f4c389c6486f689c1bfff62162464d40236cd78f0"
  @max_uint256 (1 <<< 256) - 1
  @secp256k1_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  defp pinned, do: %{chain_id: @chain_id, version: @version}
  defp ctx_terms, do: %{hash: @terms_hash}

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)
  defp upper_hex("0x" <> body), do: "0x" <> String.upcase(body)

  defp signed_envelope(overrides \\ %{}, private_key \\ @private_key) do
    envelope =
      Map.merge(
        %{
          "v" => @version,
          "chain_id" => @chain_id,
          "v_hash" => @terms_hash,
          "account" => @account,
          "issued_at" => @now
        },
        overrides
      )

    digest =
      Terms.digest(
        envelope["chain_id"],
        envelope["v_hash"],
        envelope["account"],
        envelope["issued_at"]
      )

    {r, s, recid} = Secp256k1.sign(digest, private_key)
    Map.put(envelope, "sig", %{"v" => recid + 27, "r" => hex(r), "s" => hex(s)})
  end

  test "hashes exact terms bytes to canonical lowercase hex" do
    assert Terms.hash_terms("Terms v1\n") == @terms_hash
    refute Terms.hash_terms("Terms v1") == @terms_hash
  end

  test "domain separator and digest match fixed EIP-712 encodings" do
    assert hex(Terms.domain_separator(@chain_id)) ==
             "0x906f06d67dc6296a0770c13a15516cc685bbeaa774394d93a8282dc662ae6902"

    assert hex(Terms.digest(@chain_id, @terms_hash, @account, @now)) ==
             "0xd89a79c867559468a1fad08c854c0cc268c75c2b4d2562bf5f4ff88d99492b6c"

    assert Terms.digest(@chain_id, upper_hex(@terms_hash), String.downcase(@account), @now) ==
             Terms.digest(@chain_id, @terms_hash, @account, @now)
  end

  test "digest changes when any signed field or the domain chain changes" do
    digest = Terms.digest(@chain_id, @terms_hash, @account, @now)
    other_account = Address.from_private_key(@other_private_key)

    for changed <- [
          Terms.digest(@chain_id + 1, @terms_hash, @account, @now),
          Terms.digest(@chain_id, Terms.hash_terms("other terms"), @account, @now),
          Terms.digest(@chain_id, @terms_hash, other_account, @now),
          Terms.digest(@chain_id, @terms_hash, @account, @now + 1)
        ] do
      refute changed == digest
    end
  end

  test "programmer-facing encoders reject malformed uint256, hash, and address inputs" do
    for bad <- [-1, @max_uint256 + 1, 1.0, "84532", nil] do
      assert_raise ArgumentError, fn -> Terms.domain_separator(bad) end
    end

    for bad_hash <- [
          String.duplicate("11", 32),
          "0x11",
          "0X" <> String.duplicate("11", 32),
          "0x" <> String.duplicate("zz", 32),
          <<1::256>>,
          nil
        ] do
      assert_raise ArgumentError, fn ->
        Terms.digest(@chain_id, bad_hash, @account, @now)
      end
    end

    for bad_account <- [
          String.trim_leading(@account, "0x"),
          "0X" <> String.slice(@account, 2, 40),
          "0x1234",
          "0x" <> String.duplicate("zz", 20),
          <<1::160>>,
          nil
        ] do
      assert_raise ArgumentError, fn ->
        Terms.digest(@chain_id, @terms_hash, bad_account, @now)
      end
    end

    for bad_issued_at <- [-1, @max_uint256 + 1, "1700000000", nil] do
      assert_raise ArgumentError, fn ->
        Terms.digest(@chain_id, @terms_hash, @account, bad_issued_at)
      end
    end
  end

  test "local signature recovery returns the exact EIP-55 signer" do
    digest = Terms.digest(@chain_id, @terms_hash, @account, @now)
    {r, s, recid} = Secp256k1.sign(digest, @private_key)

    assert Terms.recover_signer(digest, recid + 27, r, s) == {:ok, @account}
  end

  test "recovery rejects malformed values and shields point-arithmetic failures" do
    digest = Terms.digest(@chain_id, @terms_hash, @account, @now)
    {r, s, recid} = Secp256k1.sign(digest, @private_key)
    curve_order = <<@secp256k1_order::256>>

    for args <- [
          [binary_part(digest, 0, 31), recid + 27, r, s],
          [digest, 26, r, s],
          [digest, 29, r, s],
          [digest, recid + 27, binary_part(r, 0, 31), s],
          [digest, recid + 27, r, binary_part(s, 0, 31)],
          [digest, recid + 27, <<0::256>>, s],
          [digest, recid + 27, r, <<0::256>>],
          [digest, recid + 27, curve_order, s],
          [digest, recid + 27, r, curve_order]
        ] do
      assert apply(Terms, :recover_signer, args) == {:error, :invalid_signature}
    end

    # R=G and s=z=1 makes Q=r^-1(sR-zG) the point at infinity. The underlying
    # pure recovery raises while destructuring it; the public boundary must not.
    generator_x =
      Base.decode16!("79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")

    assert Terms.recover_signer(<<1::256>>, 27, generator_x, <<1::256>>) ==
             {:error, :invalid_signature}
  end

  test "valid acceptance returns normalized evidence" do
    env = signed_envelope()
    sig = env["sig"]

    mixed_case_env = %{
      env
      | "v_hash" => upper_hex(env["v_hash"]),
        "account" => String.downcase(env["account"]),
        "sig" => %{
          "v" => sig["v"],
          "r" => upper_hex(sig["r"]),
          "s" => upper_hex(sig["s"])
        }
    }

    assert {:ok, evidence} =
             Terms.verify_acceptance(
               mixed_case_env,
               %{hash: upper_hex(@terms_hash)},
               pinned(),
               @now
             )

    assert evidence == %{
             v_hash: @terms_hash,
             account: @account,
             issued_at: @now,
             sig: %{
               v: sig["v"],
               r: String.downcase(sig["r"]),
               s: String.downcase(sig["s"])
             }
           }
  end

  test "strict validation distinguishes pins, stale terms, and malformed fields" do
    valid = signed_envelope()

    cases = [
      {Map.put(valid, "v", "0.3.9"), {:error, {:pinned_mismatch, :version}}},
      {Map.put(valid, "v", nil), {:error, {:invalid, :version}}},
      {Map.put(valid, "chain_id", @chain_id + 1), {:error, {:pinned_mismatch, :chain_id}}},
      {Map.put(valid, "chain_id", "84532"), {:error, {:invalid, :chain_id}}},
      {Map.put(valid, "chain_id", -1), {:error, {:invalid, :chain_id}}},
      {Map.put(valid, "chain_id", @max_uint256 + 1), {:error, {:invalid, :chain_id}}},
      {Map.put(valid, "v_hash", Terms.hash_terms("superseded")), {:error, :terms_stale}},
      {Map.put(valid, "v_hash", "0x1234"), {:error, {:invalid, :v_hash}}},
      {Map.put(valid, "v_hash", "0x" <> String.duplicate("zz", 32)),
       {:error, {:invalid, :v_hash}}},
      {Map.put(valid, "account", "0x" <> String.duplicate("00", 20)),
       {:error, {:invalid, :account}}},
      {Map.put(valid, "account", "0x1234"), {:error, {:invalid, :account}}},
      {Map.put(valid, "account", String.trim_leading(@account, "0x")),
       {:error, {:invalid, :account}}},
      {Map.put(valid, "issued_at", "1700000000"), {:error, {:invalid, :issued_at}}},
      {Map.put(valid, "issued_at", -1), {:error, {:invalid, :issued_at}}},
      {Map.put(valid, "issued_at", @max_uint256 + 1), {:error, {:invalid, :issued_at}}}
    ]

    for {env, expected} <- cases do
      assert Terms.verify_acceptance(env, ctx_terms(), pinned(), @now) == expected
    end

    assert Terms.verify_acceptance(nil, ctx_terms(), pinned(), @now) ==
             {:error, {:invalid, :envelope}}

    assert Terms.verify_acceptance(
             Map.new(valid, fn {k, v} -> {String.to_atom(k), v} end),
             ctx_terms(),
             pinned(),
             @now
           ) ==
             {:error, {:invalid, :version}}
  end

  test "issued_at skew window is inclusive and rejects adjacent seconds" do
    for issued_at <- [@now - 900, @now + 300] do
      assert {:ok, %{issued_at: ^issued_at}} =
               Terms.verify_acceptance(
                 signed_envelope(%{"issued_at" => issued_at}),
                 ctx_terms(),
                 pinned(),
                 @now
               )
    end

    for issued_at <- [@now - 901, @now + 301] do
      assert {:error, {:invalid, :issued_at}} =
               Terms.verify_acceptance(
                 signed_envelope(%{"issued_at" => issued_at}),
                 ctx_terms(),
                 pinned(),
                 @now
               )
    end
  end

  test "all signature shapes and verification failures are reason-blind" do
    valid = signed_envelope()
    sig = valid["sig"]
    curve_order = hex(<<@secp256k1_order::256>>)
    wrong_signer = signed_envelope(%{}, @other_private_key)
    wrong_digest_sig = signed_envelope(%{"issued_at" => @now + 1})["sig"]

    cases = [
      Map.put(valid, "sig", nil),
      Map.put(valid, "sig", %{}),
      Map.put(valid, "sig", %{v: sig["v"], r: sig["r"], s: sig["s"]}),
      put_in(valid, ["sig", "v"], 26),
      put_in(valid, ["sig", "v"], "27"),
      put_in(valid, ["sig", "r"], "0x1234"),
      put_in(valid, ["sig", "r"], "0X" <> String.slice(sig["r"], 2, 64)),
      put_in(valid, ["sig", "r"], "0x" <> String.duplicate("zz", 32)),
      put_in(valid, ["sig", "s"], "0x1234"),
      put_in(valid, ["sig", "r"], "0x" <> String.duplicate("00", 32)),
      put_in(valid, ["sig", "r"], curve_order),
      put_in(valid, ["sig", "s"], curve_order),
      Map.put(valid, "sig", wrong_digest_sig),
      wrong_signer
    ]

    for env <- cases do
      assert Terms.verify_acceptance(env, ctx_terms(), pinned(), @now) ==
               {:error, {:invalid, :sig}}
    end
  end
end
