defmodule DelegatedSpend.OrdersTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Orders

  # Pinned KAT from the reference consumer (selector via keccak, ex_abi
  # byte-match): transfer(0x9858EfFD232B4033E47d90003D41EC34EcaEda94,
  # 2_500_000 units). Independently computed: selector a9059cbb; address
  # left-padded to 32 bytes; 2_500_000 = 0x2625a0 left-padded to 32 bytes.
  @recipient "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
  @token "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  @expected_calldata "0xa9059cbb" <>
                       "0000000000000000000000009858effd232b4033e47d90003d41ec34ecaeda94" <>
                       "00000000000000000000000000000000000000000000000000000000002625a0"

  # 100 whole 6-decimal tokens — the reference consumer's cap, stated by the
  # TEST, not baked into the package.
  @max_units 100_000_000

  describe "transfer_calldata/2" do
    test "pinned transfer vector byte-for-byte" do
      assert Orders.transfer_calldata(@recipient, 2_500_000) == @expected_calldata
    end

    test "lowercases a checksummed recipient inside the calldata" do
      lower = String.downcase(@recipient)
      assert Orders.transfer_calldata(lower, 2_500_000) == @expected_calldata
    end

    test "raises on malformed addresses" do
      for bad <- [
            "9858EfFD232B4033E47d90003D41EC34EcaEda94",
            "0x9858EfFD232B4033E47d90003D41EC34EcaEda9",
            "0x9858EfFD232B4033E47d90003D41EC34EcaEda9400",
            "0xZZ58EfFD232B4033E47d90003D41EC34EcaEda94",
            "",
            nil,
            42
          ] do
        assert_raise ArgumentError, fn -> Orders.transfer_calldata(bad, 1) end
      end
    end

    test "raises on non-positive or non-integer or oversized units" do
      assert_raise ArgumentError, fn -> Orders.transfer_calldata(@recipient, 0) end
      assert_raise ArgumentError, fn -> Orders.transfer_calldata(@recipient, -1) end
      assert_raise ArgumentError, fn -> Orders.transfer_calldata(@recipient, 2.5) end

      assert_raise ArgumentError, fn ->
        Orders.transfer_calldata(@recipient, Integer.pow(2, 256))
      end

      # max uint256 itself is fine
      max = Integer.pow(2, 256) - 1
      assert String.length(Orders.transfer_calldata(@recipient, max)) == 2 + 8 + 64 + 64
    end
  end

  describe "erc20_transfer_order/3" do
    test "builds the exact user_tx shape the keeper validates" do
      assert Orders.erc20_transfer_order(@token, @recipient, 2_500_000) == %{
               to: @token,
               data: @expected_calldata,
               value: 0
             }
    end

    test "the tx map registers as a user_tx order" do
      store = DelegatedSpend.Keeper.MemoryStore.start()

      {:ok, keeper} =
        DelegatedSpend.Keeper.start_link(%{
          store: {DelegatedSpend.Keeper.MemoryStore, store},
          source_allowlist: ["app"],
          order_ttl_s: 900,
          chain_id: 84_532
        })

      assert {:ok, _ack} =
               DelegatedSpend.Keeper.register_order(keeper, "app", %{
                 order_ref: Orders.mint_order_ref(),
                 user_ref: Orders.user_ref("12345", "test-salt"),
                 amount: 2_500_000,
                 action_args: [],
                 kind: "user_tx",
                 tx: Orders.erc20_transfer_order(@token, @recipient, 2_500_000)
               })
    end

    test "raises on a malformed token address before building anything" do
      assert_raise ArgumentError, ~r/token_address/, fn ->
        Orders.erc20_transfer_order("0xnope", @recipient, 1)
      end
    end
  end

  describe "parse_token_amount/3" do
    test "accept table (6 decimals, 100-whole-token cap)" do
      for {text, units} <- [
            {"2.5", 2_500_000},
            {"1", 1_000_000},
            {"0.1", 100_000},
            {"0.000001", 1},
            {"100", 100_000_000},
            {"0.10", 100_000},
            {" 5 ", 5_000_000}
          ] do
        assert Orders.parse_token_amount(text, 6, max_units: @max_units) == {:ok, units},
               "expected #{inspect(text)} -> #{units}"
      end
    end

    test "reject table (6 decimals, 100-whole-token cap)" do
      for text <- [
            "0",
            "0.0",
            "0.000000",
            "-1",
            "+1",
            "1.",
            "0.0000001",
            ".5",
            "nonsense",
            "1e2",
            "1E2",
            "100.000001",
            "101",
            "",
            "  ",
            "2,5",
            "1.2.3",
            "0x10"
          ] do
        assert Orders.parse_token_amount(text, 6, max_units: @max_units) == :error,
               "expected #{inspect(text)} -> :error"
      end
    end

    test "without a max_units cap only positivity bounds acceptance" do
      assert Orders.parse_token_amount("1000000000", 6) == {:ok, 1_000_000_000_000_000}
      assert Orders.parse_token_amount("0", 6) == :error
    end

    test "decimals bound the fractional digits" do
      assert Orders.parse_token_amount("1.55", 2) == {:ok, 155}
      assert Orders.parse_token_amount("1.555", 2) == :error
      assert Orders.parse_token_amount("5", 0) == {:ok, 5}
      assert Orders.parse_token_amount("5.1", 0) == :error
    end

    test "non-binary text and bad decimals are :error" do
      assert Orders.parse_token_amount(nil, 6) == :error
      assert Orders.parse_token_amount(25, 6) == :error
      assert Orders.parse_token_amount("1", -1) == :error
      assert Orders.parse_token_amount("1", "6") == :error
    end
  end

  describe "format_units/2" do
    test "round-trips human amounts" do
      assert Orders.format_units(2_500_000, 6) == "2.5"
      assert Orders.format_units(1_000_000, 6) == "1"
      assert Orders.format_units(1, 6) == "0.000001"
      assert Orders.format_units(0, 6) == "0"
      assert Orders.format_units(100_000_000, 6) == "100"
      assert Orders.format_units(155, 2) == "1.55"
      assert Orders.format_units(5, 0) == "5"
    end

    test "parse/format round-trip" do
      for text <- ["2.5", "0.000001", "99.999999", "1"] do
        {:ok, units} = Orders.parse_token_amount(text, 6, max_units: @max_units)
        assert Orders.format_units(units, 6) == text
      end
    end
  end

  describe "mint_order_ref/0" do
    test "is 64 lowercase hex chars and unique — the keeper's caller-minted shape" do
      refs = for _ <- 1..64, do: Orders.mint_order_ref()

      Enum.each(refs, fn ref ->
        assert Regex.match?(~r/^[0-9a-f]{64}$/, ref)
      end)

      assert length(Enum.uniq(refs)) == 64
    end

    test "the keeper accepts a minted ref through the object door format check" do
      store = DelegatedSpend.Keeper.MemoryStore.start()

      {:ok, keeper} =
        DelegatedSpend.Keeper.start_link(%{
          store: {DelegatedSpend.Keeper.MemoryStore, store},
          source_allowlist: ["app"],
          order_ttl_s: 900,
          chain_id: 84_532
        })

      ref = Orders.mint_order_ref()

      assert {:ok, %{order_ref: ^ref}} =
               DelegatedSpend.Keeper.register_order(keeper, "app", %{
                 order_ref: ref,
                 user_ref: "u",
                 amount: 1,
                 action_args: []
               })
    end
  end

  describe "user_ref/2" do
    test "is deterministic, salted, and one-way-shaped (64 lowercase hex)" do
      ref = Orders.user_ref("5681202", "salt-a")
      assert ref == Orders.user_ref("5681202", "salt-a")
      assert Regex.match?(~r/^[0-9a-f]{64}$/, ref)
    end

    test "different salts and different ids give different refs" do
      assert Orders.user_ref("5681202", "salt-a") != Orders.user_ref("5681202", "salt-b")
      assert Orders.user_ref("5681202", "salt-a") != Orders.user_ref("5681203", "salt-a")
    end

    test "salt/id concatenation cannot collide across the separator" do
      # domain separation: ("ab", "c") vs ("b", "ca") must differ
      assert Orders.user_ref("ab", "c") != Orders.user_ref("b", "ca")
    end

    test "an empty salt raises — the unsalted-enumerable weakness is not constructible" do
      assert_raise ArgumentError, ~r/salt is required/, fn ->
        Orders.user_ref("5681202", "")
      end
    end

    test "non-binary arguments raise" do
      assert_raise ArgumentError, fn -> Orders.user_ref(5_681_202, "salt") end
      assert_raise ArgumentError, fn -> Orders.user_ref("5681202", nil) end
    end
  end
end
