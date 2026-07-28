defmodule DelegatedSpend.KeeperTest do
  use ExUnit.Case
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.{Eip3009, MemoryStore, Signer}

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @anvil1 Base.decode16!("59C6995E998F97A5A0044966F0945389DC9E86DAE88C7A8412F4603B6B78690D")
  @secp256k1_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @secp256k1_half_order div(@secp256k1_order, 2)
  @uint256_max Integer.pow(2, 256) - 1
  @router "0x00000000000000000000000000000000000000e1"
  @action %{
    with_permit_name: "payWithPermit",
    arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
  }

  # Authorization lane (EIP-3009) fixtures — distinct from @router/@action
  # (the permit lane's SpendRouter target) since the authorization lane calls
  # the TOKEN directly (`transferWithAuthorization`), never the router.
  @token "0x" <> String.duplicate("11", 20)
  @treasury "0x" <> String.duplicate("99", 20)
  @golden_order_ref String.duplicate("ab", 32)
  @golden_signature Base.decode16!(
                      "fc34e4400f892e892fd64241dbee86cc4176bc638d347ea397c9bedd221f6e6a" <>
                        "5710b62f7006a38bebb549e25f03337be8ff23776a67994762bdb6ea8dc2ee2e1b",
                      case: :lower
                    )
  @golden_calldata "0xcf092995000000000000000000000000f39fd6e51aad88f6f4ce6a" <>
                     "b8827279cfffb922660000000000000000000000009999999999999999999999999999" <>
                     "99999999999900000000000000000000000000000000000000000000000000000000" <>
                     "000f4240000000000000000000000000000000000000000000000000000000000000" <>
                     "000000000000000000000000000000000000000000000000000000000000ee6b2800" <>
                     "8817131248d609f6b5fbd43abf3b986ecd7c4d646cd2cb5d2a189f53ebcb8ae00000" <>
                     "0000000000000000000000000000000000000000000000000000000000e000000000" <>
                     "00000000000000000000000000000000000000000000000000000041fc34e4400f89" <>
                     "2e892fd64241dbee86cc4176bc638d347ea397c9bedd221f6e6a5710b62f7006a38b" <>
                     "ebb549e25f03337be8ff23776a67994762bdb6ea8dc2ee2e1b000000000000000000" <>
                     "00000000000000000000000000000000000000000000"

  # Fix wave re-review regression double (Important): every callback
  # delegates straight to MemoryStore EXCEPT record_gas_spend/4, which
  # raises — simulating an accounting-write failure so a test can prove it
  # stays isolated from the hash-persistence result that decides whether an
  # order gets durably marked failed.
  defmodule RaisingGasSpendStore do
    alias DelegatedSpend.Keeper.MemoryStore

    def put_order(ref, order), do: MemoryStore.put_order(ref, order)
    def get_order(ref, order_id), do: MemoryStore.get_order(ref, order_id)

    def get_order_by_ref(ref, order_ref, user_ref),
      do: MemoryStore.get_order_by_ref(ref, order_ref, user_ref)

    def consume_order(ref, order_id, user_ref),
      do: MemoryStore.consume_order(ref, order_id, user_ref)

    def begin_execution(ref, order_id, user_ref, action_key),
      do: MemoryStore.begin_execution(ref, order_id, user_ref, action_key)

    def get_execution_status(ref, order_id), do: MemoryStore.get_execution_status(ref, order_id)

    def update_inflight_hash(ref, order_id, tx_hash),
      do: MemoryStore.update_inflight_hash(ref, order_id, tx_hash)

    def resolve_inflight(ref, order_id, result, at),
      do: MemoryStore.resolve_inflight(ref, order_id, result, at)

    def list_inflight(ref), do: MemoryStore.list_inflight(ref)
    def gas_spent_since(ref, since), do: MemoryStore.gas_spent_since(ref, since)

    def record_gas_spend(_ref, _wei, _at, _prune_before) do
      raise "accounting store unavailable"
    end
  end

  # A pre-0.9 consumer store: it implements the execution contract but neither
  # optional gas-accounting callback. The keeper must warn and continue.
  defmodule LegacyStore do
    alias DelegatedSpend.Keeper.MemoryStore

    def put_order(ref, order), do: MemoryStore.put_order(ref, order)
    def get_order(ref, order_id), do: MemoryStore.get_order(ref, order_id)

    def get_order_by_ref(ref, order_ref, user_ref),
      do: MemoryStore.get_order_by_ref(ref, order_ref, user_ref)

    def consume_order(ref, order_id, user_ref),
      do: MemoryStore.consume_order(ref, order_id, user_ref)

    def begin_execution(ref, order_id, user_ref, action_key),
      do: MemoryStore.begin_execution(ref, order_id, user_ref, action_key)

    def get_execution_status(ref, order_id), do: MemoryStore.get_execution_status(ref, order_id)

    def update_inflight_hash(ref, order_id, tx_hash),
      do: MemoryStore.update_inflight_hash(ref, order_id, tx_hash)

    def resolve_inflight(ref, order_id, result, at),
      do: MemoryStore.resolve_inflight(ref, order_id, result, at)

    def list_inflight(ref), do: MemoryStore.list_inflight(ref)
  end

  defp permit(value) do
    %{
      owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      value: value,
      deadline: 4_000_000_000,
      v: 27,
      r: <<1::256>>,
      s: <<2::256>>
    }
  end

  defp start_stack(overrides \\ %{}) do
    fake = FakeRpc.start(Map.merge(%{chain_id: 84_532, nonce: 0, simulate: :ok}, overrides))

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        bump_after_ms: Map.get(overrides, :bump_after_ms, 30_000)
      )

    store = MemoryStore.start()
    {:ok, keeper} = start_keeper(fake, signer, store, overrides)

    %{fake: fake, signer: signer, store: store, keeper: keeper}
  end

  defp start_keeper(fake, signer, store, overrides \\ %{}) do
    parent = self()

    Keeper.start_link(
      signer: signer,
      chain_id: 84_532,
      store: {MemoryStore, store},
      router: @router,
      action: @action,
      source_allowlist: ["market_phase"],
      order_ttl_s: Map.get(overrides, :ttl, 600),
      result_fn: Map.get(overrides, :result_fn, fn r -> send(parent, {:result, r}) end),
      rpc_mod: FakeRpc,
      rpc: fake,
      sweep_ms: 3_600_000
    )
  end

  defp order_req,
    do: %{user_ref: "u-a", amount: 25_000_000, action_args: [<<7::256>>, 25_000_000, <<9::256>>]}

  # ── authorization-lane helpers ────────────────────────────────────────────
  # Extends the existing "fake store + fake signer" stack (start_stack/1
  # above) rather than duplicating it: same MemoryStore, same real Signer
  # wired to FakeRpc, only the keeper gets the new :treasury_address /
  # :token_address / :rpc config the authorization lane needs. FakeRpc's
  # DOMAIN_SEPARATOR/name()/version() defaults are self-consistent (computed
  # from the SAME "USDC"/"2" defaults over @token and chain_id 84_532), so
  # boot's domain cross-check passes with no extra wiring.
  defp start_keeper_with_authorization_config(overrides \\ %{}) do
    overrides = Map.new(overrides)
    treasury = Map.get(overrides, :treasury, @treasury)
    token = Map.get(overrides, :token, @token)

    fake =
      FakeRpc.start(
        Map.merge(
          %{chain_id: 84_532, nonce: 0, simulate: :ok},
          Map.take(overrides, [:simulate, :block_timestamp, :gas_price])
        )
      )

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    keeper_opts =
      [
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, store},
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        treasury_address: treasury,
        token_address: token,
        rpc_mod: FakeRpc,
        rpc: fake,
        sweep_ms: 3_600_000
      ] ++
        (overrides
         |> Map.take([
           :require_owner_binding,
           :max_consecutive_reverts,
           :max_gas_wei,
           :daily_gas_budget_wei,
           :min_order_units
         ])
         |> Map.to_list())

    {:ok, keeper} = Keeper.start_link(keeper_opts)

    {keeper, store, fake}
  end

  # Server-authoritative order, planted directly in the store — the
  # authorization lane's tests exercise `execute_with_authorization/4`
  # against an order that already exists, the same way the real order would
  # have arrived via an earlier registration step; only the fields each test
  # cares about need overriding.
  defp put_order(store, attrs) do
    order =
      %{
        order_id: "0x" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        action_args: [],
        expires_at: System.os_time(:second) + 3600
      }
      |> Map.merge(Map.new(attrs))

    :ok = MemoryStore.put_order(store, order)
    order
  end

  defp valid_auth do
    %{
      from: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      value: 1_000_000,
      valid_after: 0,
      valid_before: 4_000_000_000,
      signature: :binary.copy(<<0x11>>, 65)
    }
  end

  defp signed_self_auth(order_ref, overrides \\ %{}, private_key \\ @anvil0) do
    auth =
      valid_auth()
      |> Map.put(:from, Address.from_private_key(@anvil0))
      |> Map.merge(Map.new(overrides))

    domain = Eip3009.domain_separator("USDC", "2", 84_532, @token)

    digest =
      Eip3009.authorization_digest(
        domain,
        auth.from,
        @treasury,
        auth.value,
        auth.valid_after,
        auth.valid_before,
        DelegatedSpend.Orders.authorization_nonce(order_ref)
      )

    {r, s, recid} = Secp256k1.sign(digest, private_key)
    %{auth | signature: r <> s <> <<recid + 27>>}
  end

  # The last `{to, data}` pair the keeper handed the Signer for simulation —
  # this IS the transaction the keeper built, before any signing, so it's the
  # cheapest place to assert on the calldata's fixed destination.
  defp last_submitted_tx(fake), do: fake |> FakeRpc.calls() |> List.last()

  defp submitted_tx_count(fake), do: length(FakeRpc.sent(fake))

  # The `i`-th 32-byte ABI word of a `"0x"<selector><words…>` calldata string,
  # as 64 lowercase hex chars — so a destination assertion can pin the SLOT,
  # not merely the presence of some bytes anywhere in the payload.
  defp abi_word(calldata, i) do
    calldata
    |> String.replace_prefix("0x", "")
    |> binary_part(8 + i * 64, 64)
    |> String.downcase()
  end

  defp padded_address(addr),
    do: String.duplicate("0", 24) <> String.replace_prefix(String.downcase(addr), "0x", "")

  defp calldata_signature("0x" <> hex) do
    <<_selector::binary-size(4), args::binary>> = Base.decode16!(hex, case: :mixed)
    <<_head::binary-size(6 * 32), offset::256, _::binary>> = args
    <<_::binary-size(offset), length::256, tail::binary>> = args
    binary_part(tail, 0, length)
  end

  # Boot a keeper with an ARBITRARY authorization-config subset (the caller
  # passes only the keys under test; `signer: :real` wires the real Signer).
  # Traps exits so an init/1 raise comes back as {:error, {exception, _}}
  # instead of taking the test process down.
  defp start_keeper_with(opts) do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    base = %{
      chain_id: 84_532,
      store: {MemoryStore, MemoryStore.start()},
      source_allowlist: ["market_phase"],
      order_ttl_s: 600,
      rpc_mod: FakeRpc,
      rpc: fake,
      sweep_ms: 3_600_000
    }

    opts =
      Enum.reduce(opts, base, fn
        {:signer, :real}, acc -> Map.put(acc, :signer, signer)
        {k, v}, acc -> Map.put(acc, k, v)
      end)

    Process.flag(:trap_exit, true)
    Keeper.start_link(opts)
  end

  test "register: only allowlisted envelope sources; payload-claimed source is inert" do
    %{keeper: keeper} = start_stack()

    assert {:error, {:unknown_source, "evil"}} =
             Keeper.register_order(keeper, "evil", order_req())

    # a 'source' field smuggled inside the request changes nothing — authority
    # is the source PARAMETER (the runtime envelope sender), never payload data
    req = Map.put(order_req(), :source, "market_phase")
    assert {:error, {:unknown_source, "evil"}} = Keeper.register_order(keeper, "evil", req)
    assert {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert is_binary(ref) and byte_size(ref) == 64
  end

  test "register: amount must be an integer uint256 before the order is persisted" do
    %{keeper: keeper} = start_stack()
    minted = String.duplicate("bc", 32)
    base = Map.put(order_req(), :order_ref, minted)

    for bad <- [1.0, -1, @uint256_max + 1] do
      assert {:error, :bad_amount} =
               Keeper.register_order(
                 keeper,
                 "market_phase",
                 Map.put(base, :amount, bad)
               )
    end

    assert {:ok, %{order_ref: ^minted, amount: 0}} =
             Keeper.register_order(keeper, "market_phase", Map.put(base, :amount, 0))
  end

  test "register: caller-minted order_ref — accepted verbatim, format-checked, never shadows" do
    %{keeper: keeper} = start_stack()
    minted = String.duplicate("cd", 32)

    # a well-formed caller-minted ref is used verbatim (the async object door
    # has no sync return channel, so the caller must know the ref up front)
    req = Map.put(order_req(), :order_ref, minted)
    assert {:ok, %{order_ref: ^minted}} = Keeper.register_order(keeper, "market_phase", req)
    assert {:ok, %{amount: 25_000_000}} = Keeper.fetch_order(keeper, minted, "u-a")

    # re-registering the same ref for the same user is refused — put_order
    # would remap the by-ref lookup and strand the original order's URL
    assert {:error, :duplicate_order_ref} =
             Keeper.register_order(keeper, "market_phase", req)

    # anything that doesn't look exactly like a server-minted ref is refused
    for bad <- [String.upcase(minted), "0x" <> minted, String.slice(minted, 0, 62), 42] do
      assert {:error, :bad_order_ref} =
               Keeper.register_order(
                 keeper,
                 "market_phase",
                 Map.put(order_req(), :order_ref, bad)
               ),
             "accepted bad ref #{inspect(bad)}"
    end

    # omitting the ref still server-mints (the sync call door is unchanged)
    assert {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert ref != minted and byte_size(ref) == 64
  end

  test "supervision options: :name registration + reconcile_on_init self-heal" do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        name: :spend_signer_named_test
      )

    # named signer reachable by name (what an app ctx would hold)
    assert Process.whereis(:spend_signer_named_test) == signer
    assert "0x" <> _ = Signer.address(:spend_signer_named_test)

    # a mined-while-down inflight row: reconcile_on_init settles it without
    # anyone calling reconcile_boot (the supervised-restart path)
    store = MemoryStore.start()

    order = %{
      order_id: "0xdead",
      order_ref: String.duplicate("aa", 32),
      user_ref: "u-a",
      amount: 5,
      action_args: [],
      expires_at: 4_000_000_000
    }

    :ok = MemoryStore.put_order(store, order)
    assert {:ok, _} = MemoryStore.begin_execution(store, "0xdead", "u-a", "0xdead")
    :ok = MemoryStore.update_inflight_hash(store, "0xdead", "0xhash")
    FakeRpc.put(fake, :receipts, %{"0xhash" => %{"status" => "0x1"}})
    parent = self()

    {:ok, keeper} =
      Keeper.start_link(
        signer: :spend_signer_named_test,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        result_fn: fn r -> send(parent, {:result, r}) end,
        rpc_mod: FakeRpc,
        rpc: fake,
        sweep_ms: 3_600_000,
        name: :spend_keeper_named_test,
        reconcile_on_init: true
      )

    assert Process.whereis(:spend_keeper_named_test) == keeper
    assert_receive {:result, %{order_id: "0xdead", result: {:mined, "0xhash"}}}, 1_000
    # and the keeper answers by name
    assert {:ok, _} = Keeper.register_order(:spend_keeper_named_test, "market_phase", order_req())
  end

  test "fetch: cross-user is not-found; sanitized shape" do
    %{keeper: keeper} = start_stack()
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:error, :not_found} = Keeper.fetch_order(keeper, ref, "u-EVIL")
    assert {:ok, view} = Keeper.fetch_order(keeper, ref, "u-a")

    # :chain_id (the keeper's RUNTIME chain, from init) is on EVERY view —
    # the dapp fails closed when its static config.json disagrees.
    assert Map.keys(view) |> Enum.sort() ==
             [:amount, :chain_id, :display, :expires_at, :kind, :order_ref]

    assert view.kind == "permit"
    assert view.chain_id == 84_532

    # owner-bound orders add exactly one field: the wallet they must be paid
    # from (payer-facing contract, not a secret — the dapp refuses a
    # mismatched connected account with it)
    bound = "0x000000000000000000000000000000000000dEaD"

    {:ok, %{order_ref: bref}} =
      Keeper.register_order(keeper, "market_phase", Map.put(order_req(), :expected_owner, bound))

    assert {:ok, bview} = Keeper.fetch_order(keeper, bref, "u-a")

    assert Map.keys(bview) |> Enum.sort() ==
             [:amount, :chain_id, :display, :expected_owner, :expires_at, :kind, :order_ref]

    assert bview.expected_owner == bound
  end

  test "happy path: submit → sweep → mined result + spend recorded" do
    %{keeper: keeper, fake: fake, store: store, signer: signer} = start_stack()

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert_receive {:result, %{order_id: ^oid, result: {:mined, ^hash}}}
    assert Keeper.order_status(keeper, oid) == {:mined, hash}
    assert MemoryStore.spent_since(store, "u-a", 0) == 25_000_000
    Keeper.sweep_now(keeper)
    refute_receive {:result, %{order_id: ^oid}}, 50
  end

  # The whole point of the callback is that the producer can tell WHICH of its
  # orders finished. `order_id` is minted here from random bytes and nothing on
  # the producer's side is keyed by it; `order_ref` is the identifier the
  # producer minted and stored. A real consumer wired this up to notify the
  # paying user and notified nobody, because every lookup by order_id missed.
  test "a terminal result carries the CALLER's order_ref, not only our internal id" do
    %{keeper: keeper, fake: fake, signer: signer} = start_stack()

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)

    assert_receive {:result, notification}
    assert notification.order_ref == ref, "the ref register_order handed back"
    assert notification.order_id == oid
    assert notification.user_ref == "u-a"
    assert notification.kind == "permit"
    assert notification.result == {:mined, hash}
    refute notification.order_ref == notification.order_id
  end

  test "expired order: typed failure, nothing consumed, nothing broadcast" do
    %{keeper: keeper, fake: fake} = start_stack(%{ttl: 0})
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    Process.sleep(1100)

    assert {:failed, :expired} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    assert FakeRpc.sent(fake) == []
  end

  test "permit value must equal the order amount exactly" do
    %{keeper: keeper, fake: fake} = start_stack()
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())

    assert {:failed, :no_grant} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(24_000_000))

    assert {:failed, :no_grant} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(26_000_000))

    assert FakeRpc.sent(fake) == []
  end

  test "expected_owner binds the order to one wallet: mismatch typed-fails, zero broadcast" do
    %{keeper: keeper, fake: fake} = start_stack()

    req = Map.put(order_req(), :expected_owner, "0xF39FD6E51AAD88F6F4CE6AB8827279CFFFB92266")
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", req)

    # matching owner (case-insensitive) passes
    assert {:submitted, _} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    # a different signer wallet is rejected before any chain work
    {:ok, %{order_ref: ref2}} =
      Keeper.register_order(
        keeper,
        "market_phase",
        Map.put(order_req(), :expected_owner, "0x000000000000000000000000000000000000dEaD")
      )

    sent_before = length(FakeRpc.sent(fake))

    assert {:failed, :no_grant} =
             Keeper.execute_with_permit(keeper, ref2, "u-a", permit(25_000_000))

    assert length(FakeRpc.sent(fake)) == sent_before
  end

  test "client retry after submit: idempotent, single broadcast" do
    %{keeper: keeper, fake: fake} = start_stack()
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    assert {:submitted, ^hash} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    assert length(FakeRpc.sent(fake)) == 1
  end

  test "simulation revert: typed refusal, zero broadcast, result recorded" do
    %{keeper: keeper, fake: fake} = start_stack(%{simulate: {:revert, %{"message" => "no"}}})

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:refused, "no"} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    assert FakeRpc.sent(fake) == []
    assert_receive {:result, %{order_id: ^oid, result: {:refused, "no"}}}
  end

  # ── refused (pre-broadcast) vs reverted (on-chain): two truths, two words ──
  #
  # The 2026-07-27 live run: /topup 100 against a wallet holding 19.5 USDC.
  # The simulation refused it — zero gas, nonce untouched, exactly as designed
  # — and the user was told it "didn't go through on the chain". False (it
  # never reached the chain) and useless (no hint that the amount was the
  # problem). The node's revert reason was in hand the whole time and was
  # dropped on one line. These tests pin the split: a submit-time simulation
  # refusal is `{:refused, reason}` carrying the decoded reason; only a
  # broadcast that the chain itself reverted may say `{:failed, :reverted}`.

  test "submit-time simulation refusal is {:refused, reason} with the decoded Error(string)" do
    reason = "FiatToken: transfer amount exceeds balance"

    revert_data =
      "0x08c379a0" <>
        Base.encode16(DelegatedSpend.Evm.Abi.encode_constructor([:string], [reason]),
          case: :lower
        )

    %{keeper: keeper, fake: fake} =
      start_stack(%{
        simulate: {:revert, %{"message" => "execution reverted", "data" => revert_data}}
      })

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:refused, ^reason} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    # nothing broadcast, and the terminal result survives a re-ask
    # (idempotent, from the store). The refusal-counts-toward-backoff
    # property is pinned by the §5.2.1 authorization-lane tests below,
    # where the backoff is actually configured.
    assert FakeRpc.sent(fake) == []
    assert_receive {:result, %{order_id: ^oid, result: {:refused, ^reason}}}

    assert {:refused, ^reason} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
  end

  test "a node that only gives a message still yields a usable refusal reason" do
    %{keeper: keeper} =
      start_stack(%{simulate: {:revert, %{"message" => "execution reverted: nope"}}})

    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())

    assert {:refused, "nope"} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
  end

  test "an undecodable refusal is {:refused, nil} — never disguised as an on-chain revert" do
    %{keeper: keeper} = start_stack(%{simulate: {:revert, %{"weird" => true}}})
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())

    assert {:refused, nil} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
  end

  test "boot reconciliation persists mined before delivering the late result" do
    %{keeper: keeper, fake: fake, signer: signer, store: store} = start_stack()

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    GenServer.stop(keeper)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    parent = self()

    {:ok, restarted} =
      start_keeper(fake, signer, store, %{
        result_fn: fn %{order_id: order_id, result: result} = notification ->
          send(
            parent,
            {:result, notification, MemoryStore.get_execution_status(store, order_id), result}
          )
        end
      })

    :ok = Keeper.reconcile_boot(restarted)
    assert_receive {:result, notification, {:mined, ^hash}, {:mined, ^hash}}
    assert %{order_id: ^oid, order_ref: ^ref, result: {:mined, ^hash}} = notification
    assert {:mined, ^hash} = Keeper.order_status(restarted, oid)
  end

  test "fee-bumped replacement remains reconcilable after signer and keeper restart" do
    %{keeper: keeper, fake: fake, signer: signer, store: store} =
      start_stack(%{bump_after_ms: 0})

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, original_hash} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    Process.sleep(5)
    :ok = Signer.sweep_now(signer)
    assert {:pending, replacement_hash} = Signer.status(signer, oid)
    refute replacement_hash == original_hash

    GenServer.stop(keeper)
    GenServer.stop(signer)
    FakeRpc.put(fake, :receipts, %{replacement_hash => %{"status" => "0x1"}})

    {:ok, restarted_signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    {:ok, restarted} =
      Keeper.start_link(
        signer: restarted_signer,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        sweep_ms: 3_600_000
      )

    :ok = Keeper.sweep_now(restarted)

    assert {:mined, ^replacement_hash} = Keeper.order_status(restarted, oid)
  end

  test "raising, exiting, and throwing result callbacks are logged and never crash the keeper" do
    Process.flag(:trap_exit, true)

    callbacks = [
      raise: fn _ -> raise "offline" end,
      exit: fn _ -> exit(:offline) end,
      throw: fn _ -> throw(:offline) end
    ]

    for {_kind, callback} <- callbacks do
      %{keeper: keeper} =
        start_stack(%{simulate: {:revert, %{"message" => "no"}}, result_fn: callback})

      {:ok, %{order_ref: ref, order_id: oid}} =
        Keeper.register_order(keeper, "market_phase", order_req())

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:refused, "no"} =
                   Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

          assert Process.alive?(keeper)
        end)

      assert log =~ oid
      assert log =~ "failed"
    end
  end

  test "boot reconciliation: inflight with no hash stays PENDING (never falsely failed)" do
    %{keeper: keeper, store: store} = start_stack()

    {:ok, %{order_id: oid}} = Keeper.register_order(keeper, "market_phase", order_req())
    # crash after begin_execution but before broadcast: no tx hash yet.
    assert {:ok, _} = MemoryStore.begin_execution(store, oid, "u-a", oid)
    :ok = Keeper.reconcile_boot(keeper)
    # NO result is delivered — marking it failed here could double-pay via the
    # fallback lane while the tx is still mineable. The row stays inflight.
    refute_receive {:result, {^oid, _}}, 100
    assert [%{order_id: ^oid}] = MemoryStore.list_inflight(store)
  end

  test "require_owner_binding: an order that lost its expected_owner fails CLOSED" do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        require_owner_binding: true,
        sweep_ms: 3_600_000
      )

    # order registered WITHOUT expected_owner (simulates a dropped binding)
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())

    assert {:failed, :no_grant} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    assert FakeRpc.sent(fake) == []
  end

  test "min_deadline_slack: a near-deadline permit is rejected before broadcast" do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        min_deadline_slack_s: 300,
        sweep_ms: 3_600_000
      )

    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    near = %{permit(25_000_000) | deadline: System.os_time(:second) + 10}
    assert {:failed, :expired} = Keeper.execute_with_permit(keeper, ref, "u-a", near)
    assert FakeRpc.sent(fake) == []

    # a comfortably-future deadline passes
    far = %{permit(25_000_000) | deadline: System.os_time(:second) + 3600}
    assert {:submitted, _} = Keeper.execute_with_permit(keeper, ref, "u-a", far)
  end

  test "deadline slack uses CHAIN time, not wall clock, when an RPC is wired" do
    # block_timestamp far ahead of wall clock: a permit whose deadline is only
    # comfortably future by WALL CLOCK is still rejected, proving chain time is
    # authoritative (a lagging permit vs a fast chain clock is the grief case).
    fake =
      FakeRpc.start(%{
        chain_id: 84_532,
        nonce: 0,
        simulate: :ok,
        block_timestamp: System.os_time(:second) + 100_000
      })

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 3_600_000,
        min_deadline_slack_s: 300,
        rpc_mod: FakeRpc,
        rpc: fake,
        sweep_ms: 3_600_000
      )

    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    wall_future = %{permit(25_000_000) | deadline: System.os_time(:second) + 3600}
    assert {:failed, :expired} = Keeper.execute_with_permit(keeper, ref, "u-a", wall_future)
    assert FakeRpc.sent(fake) == []
  end

  test "keeper sweep on a 0x0 receipt delivers {:failed, :reverted}, spend NOT recorded" do
    %{keeper: keeper, fake: fake, store: store, signer: signer} = start_stack()

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x0"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert_receive {:result, %{order_id: ^oid, result: {:failed, :reverted}}}
    assert MemoryStore.spent_since(store, "u-a", 0) == 0
  end

  test "a definitive node rejection is a terminal the user hears about (dry relayer)" do
    # The 2026-07-27 live test: relayer drained below one authorization's
    # gas, node answered `insufficient funds`, user read "submitted ✓" and
    # would have waited forever. A parsed JSON-RPC error is the node saying
    # no: terminal {:failed, :submit_rejected}, result_fn fires, durably
    # re-queryable, nothing broadcast.
    %{keeper: keeper, fake: fake} =
      start_stack(%{
        send_raw_fail:
          {:rpc_error, "eth_sendRawTransaction",
           %{"code" => -32003, "message" => "insufficient funds for gas * price + value"}}
      })

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:failed, :submit_rejected} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    assert FakeRpc.sent(fake) == []
    assert_receive {:result, %{order_id: ^oid, result: {:failed, :submit_rejected}}}
    assert {:failed, :submit_rejected} = Keeper.order_status(keeper, oid)
  end

  test "broadcast error remains submitted because node acceptance is unknowable" do
    %{keeper: keeper, fake: fake, store: store} = start_stack(%{send_raw_fail: :nonce_race})

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    assert FakeRpc.sent(fake) == []
    assert {:submitted, ^hash} = Keeper.order_status(keeper, oid)
    assert [%{order_id: ^oid, tx_hashes: [^hash]}] = MemoryStore.list_inflight(store)
    refute_receive {:result, {^oid, {:failed, :rpc_timeout}}}
  end

  test "accepted transaction remains submitted when the RPC response is lost" do
    %{keeper: keeper, fake: fake, signer: signer, store: store} =
      start_stack(%{send_raw_fail: {:accepted, :rpc_timeout}})

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, hash} =
             Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

    assert length(FakeRpc.sent(fake)) == 1
    refute_receive {:result, {^oid, {:failed, :rpc_timeout}}}

    GenServer.stop(keeper)
    GenServer.stop(signer)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})

    {:ok, restarted} = start_keeper(fake, nil, store)
    :ok = Keeper.sweep_now(restarted)

    assert {:mined, ^hash} = Keeper.order_status(restarted, oid)
  end

  test "reconcile_boot: a 0x0 receipt settles failed; a no-receipt hash stays pending" do
    %{keeper: keeper, fake: fake, store: store} = start_stack()

    # order A: submitted, then a 0x0 receipt appears while the keeper was 'down'
    {:ok, %{order_ref: refA, order_id: oidA}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    {:submitted, hashA} = Keeper.execute_with_permit(keeper, refA, "u-a", permit(25_000_000))

    # order B: submitted, but NO receipt yet (still mineable)
    reqB = %{order_req() | user_ref: "u-b", action_args: [<<1::256>>, 25_000_000, <<2::256>>]}

    {:ok, %{order_ref: refB, order_id: oidB}} =
      Keeper.register_order(keeper, "market_phase", reqB)

    {:submitted, _hashB} = Keeper.execute_with_permit(keeper, refB, "u-b", permit(25_000_000))

    FakeRpc.put(fake, :receipts, %{hashA => %{"status" => "0x0"}})
    :ok = Keeper.reconcile_boot(keeper)

    assert_receive {:result, %{order_id: ^oidA, result: {:failed, :reverted}}}
    # B has no receipt → must NOT be settled; it stays inflight
    refute_receive {:result, {^oidB, _}}, 100
    assert Enum.any?(MemoryStore.list_inflight(store), &(&1.order_id == oidB))
  end

  test "durable reconciliation prefers direct RPC when the signer is unavailable" do
    Process.flag(:trap_exit, true)
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})
    store = MemoryStore.start()

    order = %{
      order_id: "direct-rpc-order",
      order_ref: String.duplicate("ab", 32),
      user_ref: "u-a",
      amount: 5,
      action_args: [],
      expires_at: 4_000_000_000
    }

    :ok = MemoryStore.put_order(store, order)
    assert {:ok, _} = MemoryStore.begin_execution(store, order.order_id, "u-a", order.order_id)
    :ok = MemoryStore.update_inflight_hash(store, order.order_id, "0xdirect")
    FakeRpc.put(fake, :receipts, %{"0xdirect" => %{"status" => "0x1"}})

    {:ok, keeper} =
      Keeper.start_link(
        signer: :unavailable_signer_with_direct_rpc,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        rpc_mod: FakeRpc,
        rpc: fake,
        sweep_ms: 3_600_000
      )

    assert :ok = Keeper.sweep_now(keeper)
    assert {:mined, "0xdirect"} = Keeper.order_status(keeper, order.order_id)
  end

  test "durable reconciliation shields an unavailable signer fallback" do
    Process.flag(:trap_exit, true)
    store = MemoryStore.start()

    order = %{
      order_id: "signer-fallback-order",
      order_ref: String.duplicate("ac", 32),
      user_ref: "u-a",
      amount: 5,
      action_args: [],
      expires_at: 4_000_000_000
    }

    :ok = MemoryStore.put_order(store, order)
    assert {:ok, _} = MemoryStore.begin_execution(store, order.order_id, "u-a", order.order_id)
    :ok = MemoryStore.update_inflight_hash(store, order.order_id, "0xfallback")

    {:ok, keeper} =
      Keeper.start_link(
        signer: :unavailable_signer_fallback,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        sweep_ms: 3_600_000
      )

    assert :ok = Keeper.reconcile_boot(keeper)
    assert {:submitted, "0xfallback"} = Keeper.order_status(keeper, order.order_id)
  end

  defp start_backoff_stack(max) do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: {:revert, %{"m" => "x"}}})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        max_consecutive_reverts: max,
        sweep_ms: 3_600_000
      )

    %{fake: fake, signer: signer, store: store, keeper: keeper}
  end

  test "revert backoff (§5.2.1): N consecutive reverts suspend the grant until reset" do
    %{fake: fake, keeper: keeper} = start_backoff_stack(2)

    # two simulation-refusals accumulate the streak (zero gas each — sim gate)
    for _ <- 1..2 do
      {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())

      assert {:refused, nil} =
               Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    end

    assert Keeper.backoff_count(keeper, "u-a") == 2

    # the third attempt is SUSPENDED before any simulate/broadcast
    {:ok, %{order_ref: ref3}} = Keeper.register_order(keeper, "market_phase", order_req())

    assert {:failed, :suspended} =
             Keeper.execute_with_permit(keeper, ref3, "u-a", permit(25_000_000))

    assert FakeRpc.sent(fake) == []

    # a different user is unaffected (per-user_ref streaks)
    reqb = %{order_req() | user_ref: "u-b"}
    {:ok, %{order_ref: refb}} = Keeper.register_order(keeper, "market_phase", reqb)

    assert {:refused, nil} =
             Keeper.execute_with_permit(keeper, refb, "u-b", permit(25_000_000))

    # reset re-enables u-a; a now-OK simulation submits
    :ok = Keeper.reset_backoff(keeper, "u-a")
    assert Keeper.backoff_count(keeper, "u-a") == 0
    FakeRpc.put(fake, :simulate, :ok)
    {:ok, %{order_ref: ref4}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:submitted, _} = Keeper.execute_with_permit(keeper, ref4, "u-a", permit(25_000_000))
  end

  test "revert backoff: a mined spend resets the streak" do
    %{fake: fake, signer: signer, keeper: keeper} = start_backoff_stack(2)

    {:ok, %{order_ref: r1}} = Keeper.register_order(keeper, "market_phase", order_req())

    assert {:refused, nil} =
             Keeper.execute_with_permit(keeper, r1, "u-a", permit(25_000_000))

    assert Keeper.backoff_count(keeper, "u-a") == 1

    # a successful, mined spend resets the counter to 0
    FakeRpc.put(fake, :simulate, :ok)
    {:ok, %{order_ref: r2}} = Keeper.register_order(keeper, "market_phase", order_req())
    {:submitted, hash} = Keeper.execute_with_permit(keeper, r2, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert Keeper.backoff_count(keeper, "u-a") == 0
  end

  test "keeper restart preserves pending, submitted, mined, and refused without rebroadcast" do
    %{keeper: keeper, fake: fake, store: store, signer: signer} = start_stack()

    {:ok, %{order_ref: pending_ref, order_id: pending_id}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:ok, _} = MemoryStore.begin_execution(store, pending_id, "u-a", pending_id)

    {:ok, %{order_ref: submitted_ref, order_id: submitted_id}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, submitted_hash} =
             Keeper.execute_with_permit(keeper, submitted_ref, "u-a", permit(25_000_000))

    {:ok, %{order_ref: mined_ref, order_id: mined_id}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, mined_hash} =
             Keeper.execute_with_permit(keeper, mined_ref, "u-a", permit(25_000_000))

    FakeRpc.put(fake, :receipts, %{mined_hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert_receive {:result, %{order_id: ^mined_id, result: {:mined, ^mined_hash}}}

    FakeRpc.put(fake, :simulate, {:revert, %{"message" => "no"}})

    {:ok, %{order_ref: failed_ref, order_id: failed_id}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:refused, "no"} =
             Keeper.execute_with_permit(keeper, failed_ref, "u-a", permit(25_000_000))

    assert_receive {:result, %{order_id: ^failed_id, result: {:refused, "no"}}}

    sent_before_restart = length(FakeRpc.sent(fake))
    GenServer.stop(keeper)
    {:ok, restarted} = start_keeper(fake, nil, store)

    assert :pending = Keeper.order_status(restarted, pending_id)
    assert {:submitted, ^submitted_hash} = Keeper.order_status(restarted, submitted_id)
    assert {:mined, ^mined_hash} = Keeper.order_status(restarted, mined_id)
    assert {:refused, "no"} = Keeper.order_status(restarted, failed_id)

    assert :pending =
             Keeper.execute_with_permit(restarted, pending_ref, "u-a", permit(25_000_000))

    assert {:submitted, ^submitted_hash} =
             Keeper.execute_with_permit(restarted, submitted_ref, "u-a", permit(25_000_000))

    assert {:mined, ^mined_hash} =
             Keeper.execute_with_permit(restarted, mined_ref, "u-a", permit(25_000_000))

    assert {:refused, "no"} =
             Keeper.execute_with_permit(restarted, failed_ref, "u-a", permit(25_000_000))

    assert length(FakeRpc.sent(fake)) == sent_before_restart
  end

  test "post-terminal retry returns the durable mined result without rebroadcast" do
    %{keeper: keeper, fake: fake, signer: signer} = start_stack()

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert_receive {:result, %{order_id: ^oid, result: {:mined, ^hash}}}
    assert {:mined, ^hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    assert length(FakeRpc.sent(fake)) == 1
  end

  describe "order kinds" do
    test "user_tx order registers, fetches with tx+display, and never executes" do
      %{keeper: keeper, fake: fake} = start_stack()

      req = %{
        user_ref: "u-a",
        amount: 0,
        action_args: [],
        kind: "user_tx",
        tx: %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef", value: 0},
        display: %{summary_lines: ["Sell YES", "min out 9.90 USDC"]}
      }

      assert {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", req)
      assert {:ok, view} = Keeper.fetch_order(keeper, ref, "u-a")
      assert view.kind == "user_tx"
      assert view.tx.data == "0xdeadbeef"
      assert view.display.summary_lines == ["Sell YES", "min out 9.90 USDC"]

      assert {:failed, :wrong_kind} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(0))
      assert {:ok, _} = Keeper.fetch_order(keeper, ref, "u-a")
      assert FakeRpc.sent(fake) == []
    end

    test "user_tx registration without tx map is refused" do
      %{keeper: keeper} = start_stack()
      req = %{user_ref: "u-a", amount: 0, action_args: [], kind: "user_tx"}
      assert {:error, :bad_tx} = Keeper.register_order(keeper, "market_phase", req)
    end

    test "user_tx registration without non-negative integer value is refused" do
      %{keeper: keeper} = start_stack()

      for tx <- [
            %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef"},
            %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef", value: "0x0"},
            %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef", value: -1},
            %{
              to: "0x" <> String.duplicate("11", 20),
              data: "0xdeadbeef",
              value: 9_007_199_254_740_992
            }
          ] do
        req = %{user_ref: "u-a", amount: 0, action_args: [], kind: "user_tx", tx: tx}
        assert {:error, :bad_tx} = Keeper.register_order(keeper, "market_phase", req)
      end
    end

    test "bind order registers and fetches; permit orders default kind" do
      %{keeper: keeper, fake: fake} = start_stack()

      assert {:ok, %{order_ref: bref}} =
               Keeper.register_order(keeper, "market_phase", %{
                 user_ref: "u-a",
                 amount: 0,
                 action_args: [],
                 kind: "bind"
               })

      assert {:ok, %{kind: "bind"}} = Keeper.fetch_order(keeper, bref, "u-a")

      # a permit-lane grant against a bind ref is refused WITHOUT consuming it
      assert {:failed, :wrong_kind} = Keeper.execute_with_permit(keeper, bref, "u-a", permit(0))
      assert {:ok, %{kind: "bind"}} = Keeper.fetch_order(keeper, bref, "u-a")
      assert FakeRpc.sent(fake) == []

      assert {:ok, %{order_ref: pref}} =
               Keeper.register_order(keeper, "market_phase", order_req())

      assert {:ok, %{kind: "permit"}} = Keeper.fetch_order(keeper, pref, "u-a")
    end

    test "per-order ttl_s overrides the keeper default" do
      %{keeper: keeper} = start_stack()

      assert {:ok, %{order_ref: ref, expires_at: exp}} =
               Keeper.register_order(keeper, "market_phase", %{
                 user_ref: "u-a",
                 amount: 0,
                 action_args: [],
                 kind: "bind",
                 ttl_s: 60
               })

      assert_in_delta exp, System.os_time(:second) + 60, 5
      assert {:ok, _} = Keeper.fetch_order(keeper, ref, "u-a")
    end
  end

  describe "registry-only boot (no permit lane)" do
    test "keeper refuses to boot without :chain_id — views must always carry the runtime chain" do
      store = MemoryStore.start()

      assert_raise KeyError, fn ->
        Keeper.start_link(%{
          store: {MemoryStore, store},
          source_allowlist: ["app"],
          order_ttl_s: 900
        })
      end
    end

    test "keeper boots without signer/router/action; permit execute fails typed" do
      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(%{
          store: {MemoryStore, store},
          source_allowlist: ["app"],
          order_ttl_s: 900,
          chain_id: 84_532
        })

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(keeper, "app", %{
          user_ref: "u-a",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0}
        })

      # even the signerless registry keeper stamps the runtime chain on views
      assert {:ok, %{kind: "user_tx", chain_id: 84_532}} = Keeper.fetch_order(keeper, ref, "u-a")

      {:ok, %{order_ref: pref}} =
        Keeper.register_order(keeper, "app", %{user_ref: "u-a", amount: 5, action_args: []})

      assert {:failed, :permit_lane_disabled} =
               Keeper.execute_with_permit(keeper, pref, "u-a", permit(5))

      assert {:ok, _} = Keeper.fetch_order(keeper, pref, "u-a")
    end

    test "order_status is safe without a signer" do
      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(%{
          store: {MemoryStore, store},
          source_allowlist: ["app"],
          order_ttl_s: 900,
          chain_id: 84_532
        })

      assert :unknown = Keeper.order_status(keeper, "missing")
    end
  end

  describe "sweep timer and status-door edges" do
    test "timer-driven sweep (handle_info :sweep) settles and re-arms — the production path" do
      %{keeper: keeper, fake: fake, signer: signer} = start_stack()

      {:ok, %{order_ref: ref, order_id: oid}} =
        Keeper.register_order(keeper, "market_phase", order_req())

      {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
      FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
      Signer.sweep_now(signer)
      # the timer tick itself, not the sweep_now call door — in production this
      # is the ONLY thing that settles orders nobody polls
      send(keeper, :sweep)
      assert_receive {:result, %{order_id: ^oid, result: {:mined, ^hash}}}
      # stray mail is ignored and the keeper keeps serving
      send(keeper, :bogus)
      assert {:ok, _} = Keeper.register_order(keeper, "market_phase", order_req())
    end

    test "sweep skips a still-pending tx: no result delivered, row stays inflight" do
      %{keeper: keeper, store: store, signer: signer} = start_stack()

      {:ok, %{order_ref: ref, order_id: oid}} =
        Keeper.register_order(keeper, "market_phase", order_req())

      {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
      # no receipt in the fake → the tx is still mineable; a sweep must not settle it
      Signer.sweep_now(signer)
      Keeper.sweep_now(keeper)
      refute_receive {:result, _}, 100
      assert Enum.any?(MemoryStore.list_inflight(store), &(&1.order_id == oid))
      assert {:submitted, ^hash} = Keeper.order_status(keeper, oid)
    end

    test "order_status remains store-authoritative until the keeper persists signer status" do
      %{keeper: keeper, fake: fake, signer: signer} = start_stack()

      {:ok, %{order_ref: ref, order_id: oid}} =
        Keeper.register_order(keeper, "market_phase", order_req())

      {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
      FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x0"}})
      Signer.sweep_now(signer)
      assert Keeper.order_status(keeper, oid) == {:submitted, hash}
      Keeper.sweep_now(keeper)
      assert Keeper.order_status(keeper, oid) == {:failed, :reverted}
    end

    test "rpc_timeout neither punishes nor clears the revert streak (§5.2.1 comment pin)" do
      %{fake: fake, keeper: keeper} = start_backoff_stack(2)

      {:ok, %{order_ref: r1}} = Keeper.register_order(keeper, "market_phase", order_req())

      assert {:refused, nil} =
               Keeper.execute_with_permit(keeper, r1, "u-a", permit(25_000_000))

      assert Keeper.backoff_count(keeper, "u-a") == 1

      # a pre-broadcast fee lookup failure → terminal rpc_timeout; the streak stays at 1
      FakeRpc.put(fake, :simulate, :ok)
      FakeRpc.put(fake, :fees_raise, true)
      {:ok, %{order_ref: r2}} = Keeper.register_order(keeper, "market_phase", order_req())

      assert {:failed, :rpc_timeout} =
               Keeper.execute_with_permit(keeper, r2, "u-a", permit(25_000_000))

      assert Keeper.backoff_count(keeper, "u-a") == 1
    end
  end

  describe "execute_with_authorization/4" do
    test "WB5: rejects authorization_self even with a signer configured" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization_self",
          amount: 1_000_000
        })

      assert {:failed, :wrong_kind} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    test "rejects an amount that doesn't match the order" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:failed, :no_grant} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", %{
                 valid_auth()
                 | value: 999_999
               })
    end

    test "rejects an expired order" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000,
        expires_at: 0
      })

      assert {:failed, :expired} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())
    end

    test "rejects an authorization window that has already closed" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:failed, :expired} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", %{
                 valid_auth()
                 | valid_before: 1
               })
    end

    # THE guard for this task (the global "fixed destination" constraint): the
    # server sets the destination, and the emitted calldata must carry it. If
    # anyone adds a client-supplied `to`, this test goes red.
    test "the emitted calldata ALWAYS goes to the configured treasury wallet" do
      {keeper, store, fake} = start_keeper_with_authorization_config(%{treasury: @treasury})

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      tx = last_submitted_tx(fake)
      assert tx.to == @token

      # POSITIONAL, not "contains": the destination is the SECOND ABI word of
      # `transferWithAuthorization(from, to, …)`. A substring match would also
      # pass if the treasury bytes merely appeared somewhere else in the
      # calldata (e.g. as `from`), so it pins the slot the token contract
      # actually credits.
      assert abi_word(tx.data, 1) == padded_address(@treasury)
      assert abi_word(tx.data, 0) == padded_address(valid_auth().from)
    end

    test "a retry doesn't broadcast twice" do
      {keeper, store, fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      first = Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())
      second = Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert first == second
      assert submitted_tx_count(fake) == 1
    end

    # ── owner binding (the permit lane's control, on this lane too) ─────────

    test "an owner-bound order executes when auth.from is the bound wallet" do
      {keeper, store, fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000,
        # same wallet as valid_auth().from, differently cased — the binding is
        # an address comparison, not a string comparison
        expected_owner: String.downcase(valid_auth().from)
      })

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 1
    end

    test "an owner-bound order refuses a different auth.from, consuming nothing" do
      {keeper, store, fake} = start_keeper_with_authorization_config()

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000,
          expected_owner: "0x" <> String.duplicate("aa", 20)
        })

      assert {:failed, :no_grant} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    test "require_owner_binding fails CLOSED on an order with no expected_owner" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{require_owner_binding: true})

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:failed, :no_grant} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 0
    end

    test "an unbound order on a keeper that doesn't require binding is unaffected" do
      {keeper, store, fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 1
    end

    # ── field validation: typed failures, never a crash ─────────────────────

    test "authorization amount comparison is strict even for a malformed stored float" do
      {keeper, store, fake} = start_keeper_with_authorization_config()

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1.0
        })

      assert {:failed, :no_grant} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", %{valid_auth() | value: 1})

      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    test "a non-integer valid_before is a typed failure, not a submitted tx" do
      {keeper, store, fake} = start_keeper_with_authorization_config()

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000
        })

      # Elixir's total term ordering makes ANY binary greater than ANY integer,
      # so an unguarded `valid_before > now` comparison would sail through.
      assert {:failed, :no_grant} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", %{
                 valid_auth()
                 | valid_before: "9999999999"
               })

      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown

      # …and the order is still executable, i.e. the refusal consumed nothing
      assert {:submitted, _} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())
    end

    test "non-integer valid_after / value and a zero-length signature are typed failures" do
      {keeper, store, fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      for bad <- [
            %{valid_auth() | valid_after: "0"},
            %{valid_auth() | value: "1000000"},
            %{valid_auth() | value: 0},
            %{valid_auth() | signature: ""},
            %{valid_auth() | signature: :not_a_signature},
            Map.delete(valid_auth(), :valid_before)
          ] do
        assert {:failed, :no_grant} =
                 Keeper.execute_with_authorization(keeper, "r1", "u1", bad)
      end

      assert submitted_tx_count(fake) == 0
      assert Process.alive?(keeper)
    end

    test "a malformed auth.from is a typed failure that leaves the keeper alive" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{
          max_consecutive_reverts: 3,
          simulate: {:revert, %{"m" => "x"}}
        })

      # first accumulate real anti-grief state, so the assertion below that it
      # SURVIVED is load-bearing rather than vacuously zero
      put_order(store, %{
        order_ref: "r0",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:refused, nil} =
               Keeper.execute_with_authorization(keeper, "r0", "u1", valid_auth())

      assert Keeper.backoff_count(keeper, "u1") == 1

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000
        })

      for junk <- ["0xnothex", "0x1234", "not-an-address", nil, "0x" <> String.duplicate("0", 40)] do
        assert {:failed, :no_grant} =
                 Keeper.execute_with_authorization(keeper, "r1", "u1", %{
                   valid_auth()
                   | from: junk
                 })
      end

      # the §5.2.1 anti-grief state lives ONLY in the keeper's memory: a crash
      # here restarts the keeper with `reverts: %{}`, handing a griefer a free
      # suspension reset
      assert Process.alive?(keeper)
      assert Keeper.backoff_count(keeper, "u1") == 1
      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    # ── the remaining typed atoms ──────────────────────────────────────────

    test "a suspended user_ref is refused before anything is consumed" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{
          max_consecutive_reverts: 1,
          simulate: {:revert, %{"m" => "x"}}
        })

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:refused, nil} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert Keeper.backoff_count(keeper, "u1") == 1

      order2 =
        put_order(store, %{
          order_ref: "r2",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000
        })

      assert {:failed, :suspended} =
               Keeper.execute_with_authorization(keeper, "r2", "u1", valid_auth())

      assert MemoryStore.get_execution_status(store, order2.order_id) == :unknown
      assert submitted_tx_count(fake) == 0
    end

    test "an authorization not yet valid is refused, and validAfter == chain time is NOT valid" do
      now = 1_800_000_000

      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{block_timestamp: now})

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:failed, :not_yet_valid} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", %{
                 valid_auth()
                 | valid_after: now + 10
               })

      # EIP-3009 requires block.timestamp > validAfter STRICTLY: an
      # authorization whose validAfter equals the current block time still
      # reverts on-chain, so accepting it would only burn sponsor gas and
      # advance the user's revert backoff.
      assert {:failed, :not_yet_valid} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", %{
                 valid_auth()
                 | valid_after: now
               })

      assert submitted_tx_count(fake) == 0

      assert {:submitted, _} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", %{
                 valid_auth()
                 | valid_after: now - 1
               })
    end

    test "a keeper with no authorization config reports the lane disabled" do
      # start_stack/1 is the permit-only deployment: signer, router, action —
      # no :token_address, no :treasury_address.
      %{keeper: keeper, store: store, fake: fake} = start_stack()

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000
        })

      assert {:failed, :authorization_lane_disabled} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    # I4: the lane must be reachable through the REAL door, not only by
    # planting an order in the store.
    test "an authorization order registered through register_order/3 executes end to end" do
      {keeper, _store, fake} = start_keeper_with_authorization_config()

      assert {:ok, %{order_ref: ref}} =
               Keeper.register_order(keeper, "market_phase", %{
                 user_ref: "u1",
                 amount: 1_000_000,
                 action_args: [],
                 kind: "authorization"
               })

      assert {:ok, %{kind: "authorization"}} = Keeper.fetch_order(keeper, ref, "u1")

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, ref, "u1", valid_auth())

      assert abi_word(last_submitted_tx(fake).data, 1) == padded_address(@treasury)
    end
  end

  describe "build_self_authorization/4" do
    test "WB1: returns the frozen transferWithAuthorization calldata vector" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()

      put_order(store, %{
        order_ref: @golden_order_ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 1_000_000
      })

      auth = %{
        from: Address.from_private_key(@anvil0),
        value: 1_000_000,
        valid_after: 0,
        valid_before: 4_000_000_000,
        signature: @golden_signature
      }

      assert {:ok,
              %{
                to: @token,
                data: @golden_calldata,
                chain_id: 84_532,
                valid_before: 4_000_000_000
              }} = Keeper.build_self_authorization(keeper, @golden_order_ref, "u1", auth)
    end

    test "accepts both wallet v encodings, 27/28 and 0/1" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()
      ref = String.duplicate("cd", 32)

      put_order(store, %{
        order_ref: ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 1_000_000
      })

      auth_legacy = signed_self_auth(ref)
      <<rs::binary-size(64), v>> = auth_legacy.signature
      auth_parity = %{auth_legacy | signature: rs <> <<v - 27>>}

      assert {:ok, %{data: legacy_data}} =
               Keeper.build_self_authorization(keeper, ref, "u1", auth_legacy)

      assert {:ok, %{data: parity_data}} =
               Keeper.build_self_authorization(keeper, ref, "u1", auth_parity)

      assert parity_data == legacy_data

      for data <- [legacy_data, parity_data] do
        <<_r::binary-size(32), s::binary-size(32), emitted_v>> = calldata_signature(data)
        assert :binary.decode_unsigned(s) <= @secp256k1_half_order
        assert emitted_v in [27, 28]
      end
    end

    test "refuses a malleated high-s signature instead of returning doomed calldata" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()
      ref = String.duplicate("ce", 32)

      put_order(store, %{
        order_ref: ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 1_000_000
      })

      auth = signed_self_auth(ref)
      <<r::binary-size(32), low_s::binary-size(32), v>> = auth.signature
      high_s_int = @secp256k1_order - :binary.decode_unsigned(low_s)
      encoded_high_s = :binary.encode_unsigned(high_s_int)
      high_s = :binary.copy(<<0>>, 32 - byte_size(encoded_high_s)) <> encoded_high_s
      flipped_v = if v == 27, do: 28, else: 27

      assert high_s_int > @secp256k1_half_order

      assert {:error, :invalid_signature} =
               Keeper.build_self_authorization(
                 keeper,
                 ref,
                 "u1",
                 %{auth | signature: r <> high_s <> <<flipped_v>>}
               )
    end

    test "WB2: refuses a structurally valid signature from the wrong key without calldata" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()
      ref = String.duplicate("de", 32)

      order =
        put_order(store, %{
          order_ref: ref,
          user_ref: "u1",
          kind: "authorization_self",
          amount: 1_000_000
        })

      wrong_signer = signed_self_auth(ref, %{}, @anvil1)
      <<r::binary-size(32), s::binary-size(32), v>> = wrong_signer.signature
      assert :binary.decode_unsigned(r) in 1..(@secp256k1_order - 1)
      assert :binary.decode_unsigned(s) in 1..@secp256k1_half_order
      assert v in [27, 28]

      result = Keeper.build_self_authorization(keeper, ref, "u1", wrong_signer)
      assert result == {:error, :invalid_signature}
      refute match?({:ok, %{data: _}}, result)

      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    test "WB3: ignores envelope to and refuses a value different from the order" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()
      ref = String.duplicate("ef", 32)

      put_order(store, %{
        order_ref: ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 1_000_000
      })

      attacker = "0x" <> String.duplicate("aa", 20)
      auth = signed_self_auth(ref) |> Map.put(:to, attacker)

      assert {:ok, %{to: @token, data: data}} =
               Keeper.build_self_authorization(keeper, ref, "u1", auth)

      assert abi_word(data, 1) == padded_address(@treasury)
      refute abi_word(data, 1) == padded_address(attacker)

      assert {:error, :no_grant} =
               Keeper.build_self_authorization(
                 keeper,
                 ref,
                 "u1",
                 signed_self_auth(ref, %{value: 999_999})
               )
    end

    test "self-submit amount comparison is strict for a malformed stored float" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()
      ref = String.duplicate("f0", 32)

      put_order(store, %{
        order_ref: ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 1.0
      })

      assert {:error, :no_grant} =
               Keeper.build_self_authorization(
                 keeper,
                 ref,
                 "u1",
                 signed_self_auth(ref, %{value: 1})
               )
    end

    test "WB4: refuses value above uint256 instead of wrapping or raising" do
      {keeper, store, _fake} = start_keeper_with_authorization_config()
      ref = String.duplicate("12", 32)

      put_order(store, %{
        order_ref: ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: Integer.pow(2, 256)
      })

      auth = %{
        from: Address.from_private_key(@anvil0),
        value: Integer.pow(2, 256),
        valid_after: 0,
        valid_before: 4_000_000_000,
        signature: @golden_signature
      }

      assert {:error, :no_grant} =
               Keeper.build_self_authorization(keeper, ref, "u1", auth)

      assert Process.alive?(keeper)
    end

    test "keeps min_order_units but ignores sponsor gas-price and budget brakes" do
      {keeper, store, _fake} =
        start_keeper_with_authorization_config(%{
          min_order_units: 1_000_000,
          max_gas_wei: 1,
          daily_gas_budget_wei: 0,
          gas_price: 999_999_999
        })

      ref = String.duplicate("34", 32)

      put_order(store, %{
        order_ref: ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 1_000_000
      })

      assert {:ok, _tx} =
               Keeper.build_self_authorization(keeper, ref, "u1", signed_self_auth(ref))

      below_ref = String.duplicate("56", 32)

      put_order(store, %{
        order_ref: below_ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 999_999
      })

      assert {:error, :below_minimum} =
               Keeper.build_self_authorization(
                 keeper,
                 below_ref,
                 "u1",
                 signed_self_auth(below_ref, %{value: 999_999})
               )
    end

    test "does not inherit the sponsor's anti-grief backoff" do
      {keeper, store, _fake} =
        start_keeper_with_authorization_config(%{
          max_consecutive_reverts: 1,
          simulate: {:revert, %{"message" => "no"}}
        })

      sponsored_ref = String.duplicate("78", 32)

      put_order(store, %{
        order_ref: sponsored_ref,
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:refused, "no"} =
               Keeper.execute_with_authorization(
                 keeper,
                 sponsored_ref,
                 "u1",
                 valid_auth()
               )

      assert Keeper.backoff_count(keeper, "u1") == 1

      self_ref = String.duplicate("9a", 32)

      put_order(store, %{
        order_ref: self_ref,
        user_ref: "u1",
        kind: "authorization_self",
        amount: 1_000_000
      })

      assert {:ok, _tx} =
               Keeper.build_self_authorization(
                 keeper,
                 self_ref,
                 "u1",
                 signed_self_auth(self_ref)
               )
    end
  end

  # Task 3b (spec §5): the three economic brakes, consulted BEFORE the
  # Signer, on the authorization lane only. Each rejection is a typed
  # `{:failed, _}` that consumes nothing (money never left, nothing was
  # broadcast) — mirrors every other typed-failure test above.
  describe "execute_with_authorization/4: economic brakes (Task 3b)" do
    test "min-only sponsored config preserves the original gas RPC failure" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{
          min_order_units: 1,
          gas_price: {:error, :rpc_timeout}
        })

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000
        })

      assert {:failed, :rpc_timeout} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    test "gas price ceiling: above :max_gas_wei is refused, nothing consumed or broadcast" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{max_gas_wei: 10, gas_price: 50})

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000
        })

      assert {:failed, :gas_too_expensive} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown

      # the refusal consumed nothing — a cheaper gas price still executes
      FakeRpc.put(fake, :gas_price, 5)

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())
    end

    test "daily gas budget: at or over :daily_gas_budget_wei is refused" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{daily_gas_budget_wei: 1_000})

      # pre-existing gas spend today, seeded directly at the store — the
      # keeper reads this back via `gas_spent_since/2` before ever calling
      # the Signer.
      :ok = MemoryStore.record_gas_spend(store, 1_000, System.os_time(:second), 0)

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:failed, :budget_exhausted} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 0
    end

    test "daily gas budget ignores spend older than the rolling 24h window" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{daily_gas_budget_wei: 1_000})

      # this spend is more than a day old — it must NOT count toward today's
      # accumulated total
      :ok = MemoryStore.record_gas_spend(store, 1_000, System.os_time(:second) - 90_000, 0)

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 1
    end

    test "minimum order size: below :min_order_units is refused" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{min_order_units: 2_000_000})

      order =
        put_order(store, %{
          order_ref: "r1",
          user_ref: "u1",
          kind: "authorization",
          amount: 1_000_000
        })

      assert {:failed, :below_minimum} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 0
      assert MemoryStore.get_execution_status(store, order.order_id) == :unknown
    end

    test "no brakes configured: extreme gas price and prior spend never block (empty config admits all)" do
      {keeper, store, fake} =
        start_keeper_with_authorization_config(%{gas_price: 999_999_999_999})

      :ok = MemoryStore.record_gas_spend(store, 999_999_999_999, System.os_time(:second), 0)

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert submitted_tx_count(fake) == 1
    end

    test "a successful submit records the estimated gas cost in the store" do
      {keeper, store, _fake} =
        start_keeper_with_authorization_config(%{daily_gas_budget_wei: 999_999_999_999_999})

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert MemoryStore.gas_spent_since(store, 0) == 0

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      # gas(100_000, headroomed 1.3x) * max_fee(base 10e9 *2 + prio 1e9) —
      # FakeRpc's defaults, the SAME numbers the Signer itself computed at
      # submit time (an ESTIMATE, not the mined cost: see Signer moduledoc).
      assert MemoryStore.gas_spent_since(store, 0) == div(100_000 * 13, 10) * 21_000_000_000
    end

    # Fix wave, Minor #3: the WRITE side (record_gas_spend + the store round
    # trip it costs) is gated on :daily_gas_budget_wei specifically — a
    # keeper with a DIFFERENT brake configured (:max_gas_wei here, which
    # already exercises the admit check's RPC/read path) still records no
    # history at all, because nothing ever reads it back.
    test "Minor #3: no :daily_gas_budget_wei configured records nothing, even on a successful submit" do
      {keeper, store, _fake} =
        start_keeper_with_authorization_config(%{max_gas_wei: 999_999_999_999_999})

      put_order(store, %{
        order_ref: "r1",
        user_ref: "u1",
        kind: "authorization",
        amount: 1_000_000
      })

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, "r1", "u1", valid_auth())

      assert MemoryStore.gas_spent_since(store, 0) == 0
    end

    # Fix wave, Important #1+#2: the structural fix. Gas-spend recording now
    # happens at the SAME durable pre-broadcast moment as the tx-hash write
    # (the Signer's persist_hash_fn, invoked before every initial AND
    # fee-bumped broadcast) — never re-derived from a post-submit read. A
    # stuck tx that gets fee-bumped must have its recorded total track the
    # FINAL (bumped) estimate, not freeze at the original — the exact
    # under-counting bug this fix wave closes.
    test "a fee-bumped rebroadcast records only the delta: the total tracks the final estimate, not the original" do
      fake =
        FakeRpc.start(%{
          chain_id: 84_532,
          nonce: 0,
          simulate: :ok
        })

      {:ok, signer} =
        Signer.start_link(
          rpc_url: fake,
          chain_id: 84_532,
          priv: @anvil0,
          rpc_mod: FakeRpc,
          sweep_ms: 3_600_000,
          bump_after_ms: 0
        )

      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(
          signer: signer,
          chain_id: 84_532,
          store: {MemoryStore, store},
          source_allowlist: ["market_phase"],
          order_ttl_s: 600,
          treasury_address: @treasury,
          token_address: @token,
          rpc_mod: FakeRpc,
          rpc: fake,
          sweep_ms: 3_600_000,
          daily_gas_budget_wei: 999_999_999_999_999
        )

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "u-a",
          amount: 1_000_000,
          action_args: [],
          kind: "authorization"
        })

      assert {:submitted, _hash} =
               Keeper.execute_with_authorization(keeper, ref, "u-a", valid_auth())

      # gas(100_000, headroomed 1.3x) * max_fee(base 10e9*2 + prio 1e9) — the
      # SAME FakeRpc defaults as the sibling test above.
      original_estimate = div(100_000 * 13, 10) * 21_000_000_000
      assert MemoryStore.gas_spent_since(store, 0) == original_estimate

      # a stuck tx (bump_after_ms: 0 → any still-pending entry bumps on the
      # next sweep tick): the same nonce rebroadcasts at 1.25x the fees.
      Process.sleep(5)
      :ok = Signer.sweep_now(signer)

      bumped_max_fee = div(21_000_000_000 * 5, 4) + 1
      final_estimate = div(100_000 * 13, 10) * bumped_max_fee

      # the recorded total equals the FINAL estimate exactly — not the
      # original frozen in place (the bug), and not original + a full
      # re-estimate double-counted (only the delta is added).
      assert MemoryStore.gas_spent_since(store, 0) == final_estimate
      refute MemoryStore.gas_spent_since(store, 0) == original_estimate
    end

    # A single keeper can serve BOTH lanes at once (the authorization lane
    # doesn't disable the permit lane). Gas-spend recording must stay scoped
    # to the authorization lane's orders only — a permit-kind execution on
    # the SAME keeper, with the SAME :daily_gas_budget_wei configured, must
    # record nothing (permit lane untouched), while a sibling authorization
    # order on that keeper still gets tracked normally.
    test "gas spend recording stays scoped to the authorization lane even when a permit order runs on the same keeper" do
      fake =
        FakeRpc.start(%{
          chain_id: 84_532,
          nonce: 0,
          simulate: :ok
        })

      {:ok, signer} =
        Signer.start_link(
          rpc_url: fake,
          chain_id: 84_532,
          priv: @anvil0,
          rpc_mod: FakeRpc,
          sweep_ms: 3_600_000
        )

      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(
          signer: signer,
          chain_id: 84_532,
          store: {MemoryStore, store},
          router: @router,
          action: @action,
          source_allowlist: ["market_phase"],
          order_ttl_s: 600,
          treasury_address: @treasury,
          token_address: @token,
          rpc_mod: FakeRpc,
          rpc: fake,
          sweep_ms: 3_600_000,
          daily_gas_budget_wei: 999_999_999_999_999
        )

      {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())

      assert {:submitted, _hash} =
               Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))

      assert MemoryStore.gas_spent_since(store, 0) == 0

      {:ok, %{order_ref: aref}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "u-a",
          amount: 1_000_000,
          action_args: [],
          kind: "authorization"
        })

      assert {:submitted, _hash2} =
               Keeper.execute_with_authorization(keeper, aref, "u-a", valid_auth())

      assert MemoryStore.gas_spent_since(store, 0) > 0
    end

    test "a legacy store without optional gas callbacks warns and still submits" do
      fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

      {:ok, signer} =
        Signer.start_link(
          rpc_url: fake,
          chain_id: 84_532,
          priv: @anvil0,
          rpc_mod: FakeRpc,
          sweep_ms: 3_600_000
        )

      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(
          signer: signer,
          chain_id: 84_532,
          store: {LegacyStore, store},
          source_allowlist: ["market_phase"],
          order_ttl_s: 600,
          treasury_address: @treasury,
          token_address: @token,
          rpc_mod: FakeRpc,
          rpc: fake,
          sweep_ms: 3_600_000,
          daily_gas_budget_wei: 999_999_999_999_999
        )

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "u-a",
          amount: 1_000_000,
          action_args: [],
          kind: "authorization"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:submitted, _hash} =
                   Keeper.execute_with_authorization(keeper, ref, "u-a", valid_auth())
        end)

      assert submitted_tx_count(fake) == 1
      assert log =~ "does not implement optional gas_spent_since/2"
    end

    # Fix wave re-review (Important): the accounting write and the hash write
    # share one closure (`persist_hash_fn`) — a raise in cost-recording must
    # never be mistaken for a hash-persistence failure. Before the fix, an
    # accounting raise propagated out of the closure, so signer.ex's
    # `persist_hash/3` reported it as a persist_hash error, and keeper.ex's
    # generic `{:error, _} -> settle(..., {:failed, :rpc_timeout})` clause
    # then durably overwrote the order's status from the just-written
    # `{:submitted, hash}` to a terminal failure — killing a legitimate,
    # already-broadcast order over a lost accounting row.
    test "a raise in gas-spend accounting is isolated: the order still submits, the hash stays durable, only a warning is logged" do
      fake =
        FakeRpc.start(%{
          chain_id: 84_532,
          nonce: 0,
          simulate: :ok
        })

      {:ok, signer} =
        Signer.start_link(
          rpc_url: fake,
          chain_id: 84_532,
          priv: @anvil0,
          rpc_mod: FakeRpc,
          sweep_ms: 3_600_000
        )

      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(
          signer: signer,
          chain_id: 84_532,
          store: {RaisingGasSpendStore, store},
          source_allowlist: ["market_phase"],
          order_ttl_s: 600,
          treasury_address: @treasury,
          token_address: @token,
          rpc_mod: FakeRpc,
          rpc: fake,
          sweep_ms: 3_600_000,
          daily_gas_budget_wei: 999_999_999_999_999
        )

      {:ok, %{order_ref: ref, order_id: oid}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "u-a",
          amount: 1_000_000,
          action_args: [],
          kind: "authorization"
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:submitted, _hash} =
                   Keeper.execute_with_authorization(keeper, ref, "u-a", valid_auth())
        end)

      # one broadcast happened — a lost accounting write must never suppress
      # or duplicate it.
      assert submitted_tx_count(fake) == 1

      # the hash write is durable and the order is NOT terminally failed,
      # even though the accounting half of the same closure raised.
      assert {:submitted, _hash} = MemoryStore.get_execution_status(store, oid)
      refute match?({:failed, _}, MemoryStore.get_execution_status(store, oid))

      assert log =~ oid
      assert log =~ "gas spend not recorded"
    end
  end

  describe "authorization lane boot: DOMAIN_SEPARATOR" do
    test "keeper refuses to boot when DOMAIN_SEPARATOR can't be read from the token" do
      fake =
        FakeRpc.start(%{
          chain_id: 84_532,
          nonce: 0,
          simulate: :ok,
          # too short to be a 32-byte separator — the malformed-read case
          eth_call_result: "0xbad"
        })

      store = MemoryStore.start()

      {:ok, signer} =
        Signer.start_link(
          rpc_url: fake,
          chain_id: 84_532,
          priv: @anvil0,
          rpc_mod: FakeRpc,
          sweep_ms: 3_600_000
        )

      # A raise inside init/1 crashes the (linked) spawned process before the
      # start_link handshake acks — trapping exits here is what turns that
      # into a clean {:error, {exception, _stack}} return instead of taking
      # the test process down with it (same need as the other init-crash
      # tests in this file, e.g. "durable reconciliation shields an
      # unavailable signer fallback").
      Process.flag(:trap_exit, true)

      assert {:error, {%RuntimeError{message: message}, _stacktrace}} =
               Keeper.start_link(%{
                 signer: signer,
                 chain_id: 84_532,
                 store: {MemoryStore, store},
                 source_allowlist: ["market_phase"],
                 order_ttl_s: 600,
                 token_address: @token,
                 treasury_address: @treasury,
                 rpc_mod: FakeRpc,
                 rpc: fake
               })

      assert message =~ "DOMAIN_SEPARATOR"
      assert message =~ String.downcase(@token)
    end
  end

  describe "authorization lane boot: EIP-712 domain (name/version) verification" do
    test "boots fine and exposes the boot-verified domain when name()/version() hash to DOMAIN_SEPARATOR" do
      {keeper, _store, _fake} = start_keeper_with_authorization_config()

      assert {:ok,
              %{
                treasury_address: @treasury,
                token_address: @token,
                chain_id: 84_532,
                name: "USDC",
                version: "2"
              }} = Keeper.authorization_domain(keeper)
    end

    test ":disabled when the authorization lane isn't configured (permit-only keeper)" do
      %{keeper: keeper} = start_stack()
      assert Keeper.authorization_domain(keeper) == :disabled
    end

    # The whole point of reading name()/version() instead of hardcoding them:
    # if what the token actually reports does NOT hash to the on-chain
    # DOMAIN_SEPARATOR, boot must fail closed rather than serve an unverified
    # (and therefore possibly wrong-network / wrong-token) domain to the dapp.
    test "keeper refuses to boot when name()/version() do NOT hash to the read DOMAIN_SEPARATOR" do
      # DOMAIN_SEPARATOR is PINNED to the "USDC"/"2" formula (via
      # eth_call_result, which short-circuits FakeRpc's self-consistent
      # default), while the token's version() call (falsely) answers "3" —
      # the two now disagree.
      pinned_separator =
        DelegatedSpend.Keeper.Eip3009.domain_separator("USDC", "2", 84_532, @token)

      fake =
        FakeRpc.start(%{
          chain_id: 84_532,
          nonce: 0,
          simulate: :ok,
          eth_call_result: "0x" <> Base.encode16(pinned_separator, case: :lower),
          token_version: "3"
        })

      store = MemoryStore.start()

      {:ok, signer} =
        Signer.start_link(
          rpc_url: fake,
          chain_id: 84_532,
          priv: @anvil0,
          rpc_mod: FakeRpc,
          sweep_ms: 3_600_000
        )

      Process.flag(:trap_exit, true)

      assert {:error, {%RuntimeError{message: message}, _stacktrace}} =
               Keeper.start_link(%{
                 signer: signer,
                 chain_id: 84_532,
                 store: {MemoryStore, store},
                 source_allowlist: ["market_phase"],
                 order_ttl_s: 600,
                 token_address: @token,
                 treasury_address: @treasury,
                 rpc_mod: FakeRpc,
                 rpc: fake
               })

      assert message =~ "name()/version()"
      assert message =~ String.downcase(@token)
    end
  end

  # C2: a money lane that is only PARTLY configured must not boot. The runtime
  # `cond` alone is not enough — a keeper that reports the lane enabled and
  # then crashes mid-execution can strand a consumed order in durable
  # `:pending` with no tx hash, which adoption.md forbids ever resubmitting.
  describe "authorization lane boot: configuration coherence" do
    test "WB6 cell 3a: signer + token without treasury still refuses boot" do
      assert {:error, {%ArgumentError{message: message}, _}} =
               start_keeper_with(%{signer: :real, token_address: @token})

      assert message =~ ":treasury_address"
      assert message =~ "authorization"
    end

    test "a treasury address without a token address refuses to boot, naming the missing key" do
      assert {:error, {%ArgumentError{message: message}, _}} =
               start_keeper_with(%{signer: :real, treasury_address: @treasury})

      assert message =~ ":token_address"
    end

    test "WB6 cell 1: token + treasury without signer boots self-submit only" do
      assert {:ok, keeper} =
               start_keeper_with(%{token_address: @token, treasury_address: @treasury})

      assert {:ok, %{order_ref: ref}} =
               Keeper.register_order(
                 keeper,
                 "market_phase",
                 Map.put(order_req(), :kind, "authorization_self")
               )

      assert {:ok, _tx} =
               Keeper.build_self_authorization(
                 keeper,
                 ref,
                 "u-a",
                 signed_self_auth(ref, %{value: 25_000_000})
               )

      assert {:error, :authorization_lane_disabled} =
               Keeper.register_order(
                 keeper,
                 "market_phase",
                 Map.put(order_req(), :kind, "authorization")
               )

      assert {:ok, _domain} = Keeper.authorization_domain(keeper)
    end

    test "WB6 cell 4: no token or treasury boots permit-only and refuses self kind" do
      assert {:ok, keeper} = start_keeper_with(%{signer: :real})
      assert Process.alive?(keeper)

      assert {:error, :authorization_lane_disabled} =
               Keeper.register_order(
                 keeper,
                 "market_phase",
                 Map.put(order_req(), :kind, "authorization_self")
               )
    end

    test "WB6 cell 2: token + treasury + signer serves both authorization kinds" do
      assert {:ok, keeper} =
               start_keeper_with(%{
                 signer: :real,
                 token_address: @token,
                 treasury_address: @treasury
               })

      assert Process.alive?(keeper)

      for kind <- ["authorization_self", "authorization"] do
        assert {:ok, _} =
                 Keeper.register_order(
                   keeper,
                   "market_phase",
                   Map.put(order_req(), :kind, kind)
                 )
      end
    end

    # R1 (re-review): presence alone is not enough. A truncated paste like
    # "0xdead" is PRESENT, so the checks above wave it through — and
    # `Address.to_bytes/1` has a raw-20-byte pass-through clause, so a
    # string that merely happens to be 20 characters long gets used as-is,
    # ASCII and all, as the destination. That must fail at boot, not at the
    # first paying user.
    test "a malformed treasury address refuses to boot, naming :treasury_address" do
      assert {:error, {%ArgumentError{message: message}, _}} =
               start_keeper_with(%{
                 signer: :real,
                 token_address: @token,
                 treasury_address: "0xdeadbeefdeadbeef12"
               })

      assert message =~ ":treasury_address"
    end

    test "a malformed token address refuses to boot, naming :token_address" do
      assert {:error, {%ArgumentError{message: message}, _}} =
               start_keeper_with(%{
                 signer: :real,
                 token_address: "0xdeadbeefdeadbeef12",
                 treasury_address: @treasury
               })

      assert message =~ ":token_address"
    end

    test "a well-formed EIP-55 mixed-case address boots fine (must not over-tighten)" do
      assert {:ok, keeper} =
               start_keeper_with(%{
                 signer: :real,
                 token_address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                 treasury_address: @treasury
               })

      assert Process.alive?(keeper)
    end
  end
end
