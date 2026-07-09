defmodule DelegatedSpend.KeeperTest do
  use ExUnit.Case
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.{MemoryStore, Signer}

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @router "0x00000000000000000000000000000000000000e1"
  @action %{with_permit_name: "payWithPermit", arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]}

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
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()
    parent = self()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        store: {MemoryStore, store},
        router: @router,
        action: @action,
        source_allowlist: ["market_phase"],
        order_ttl_s: Map.get(overrides, :ttl, 600),
        result_fn: fn r -> send(parent, {:result, r}) end,
        rpc_mod: FakeRpc,
        rpc: fake,
        sweep_ms: 3_600_000
      )

    %{fake: fake, signer: signer, store: store, keeper: keeper}
  end

  defp order_req, do: %{user_ref: "u-a", amount: 25_000_000, action_args: [<<7::256>>, 25_000_000, <<9::256>>]}

  test "register: only allowlisted envelope sources; payload-claimed source is inert" do
    %{keeper: keeper} = start_stack()
    assert {:error, {:unknown_source, "evil"}} = Keeper.register_order(keeper, "evil", order_req())
    # a 'source' field smuggled inside the request changes nothing — authority
    # is the source PARAMETER (the runtime envelope sender), never payload data
    req = Map.put(order_req(), :source, "market_phase")
    assert {:error, {:unknown_source, "evil"}} = Keeper.register_order(keeper, "evil", req)
    assert {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert is_binary(ref) and byte_size(ref) == 64
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
               Keeper.register_order(keeper, "market_phase", Map.put(order_req(), :order_ref, bad)),
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
    order = %{order_id: "0xdead", order_ref: String.duplicate("aa", 32), user_ref: "u-a", amount: 5, action_args: [], expires_at: 4_000_000_000}
    :ok = MemoryStore.put_order(store, order)
    :ok = MemoryStore.put_inflight(store, "0xdead", "0xdead")
    :ok = MemoryStore.update_inflight_hash(store, "0xdead", "0xhash")
    FakeRpc.put(fake, :receipts, %{"0xhash" => %{"status" => "0x1"}})
    parent = self()

    {:ok, keeper} =
      Keeper.start_link(
        signer: :spend_signer_named_test,
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
    assert_receive {:result, {"0xdead", {:credited, "0xhash"}}}, 1_000
    # and the keeper answers by name
    assert {:ok, _} = Keeper.register_order(:spend_keeper_named_test, "market_phase", order_req())
  end

  test "fetch: cross-user is not-found; sanitized shape" do
    %{keeper: keeper} = start_stack()
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:error, :not_found} = Keeper.fetch_order(keeper, ref, "u-EVIL")
    assert {:ok, view} = Keeper.fetch_order(keeper, ref, "u-a")
    assert Map.keys(view) |> Enum.sort() == [:amount, :display, :expires_at, :kind, :order_ref]
    assert view.kind == "permit"
  end

  test "happy path: submit → sweep(mined) → credited result + spend recorded" do
    %{keeper: keeper, fake: fake, store: store, signer: signer} = start_stack()

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    assert {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert_receive {:result, {^oid, {:credited, ^hash}}}
    assert Keeper.order_status(keeper, oid) == {:credited, hash}
    assert MemoryStore.spent_since(store, "u-a", 0) == 25_000_000
  end

  test "expired order: typed failure, nothing consumed, nothing broadcast" do
    %{keeper: keeper, fake: fake} = start_stack(%{ttl: 0})
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    Process.sleep(1100)
    assert {:failed, :expired} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    assert FakeRpc.sent(fake) == []
  end

  test "permit value must equal the order amount exactly" do
    %{keeper: keeper, fake: fake} = start_stack()
    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:failed, :no_grant} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(24_000_000))
    assert {:failed, :no_grant} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(26_000_000))
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
    assert {:submitted, ^hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    assert length(FakeRpc.sent(fake)) == 1
  end

  test "simulation revert: typed failure, zero broadcast, result recorded" do
    %{keeper: keeper, fake: fake} = start_stack(%{simulate: {:revert, %{"message" => "no"}}})
    {:ok, %{order_ref: ref, order_id: oid}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:failed, :reverted} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    assert FakeRpc.sent(fake) == []
    assert_receive {:result, {^oid, {:failed, :reverted}}}
  end

  test "boot reconciliation: mined-while-down delivers a late credited result" do
    %{keeper: keeper, fake: fake} = start_stack()

    {:ok, %{order_ref: ref, order_id: oid}} =
      Keeper.register_order(keeper, "market_phase", order_req())

    {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    # "keeper was down while it mined": receipt exists, the run-time sweep
    # never fired; reconcile queries receipts for every inflight tx hash.
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    :ok = Keeper.reconcile_boot(keeper)
    assert_receive {:result, {^oid, {:credited, ^hash}}}
  end

  test "boot reconciliation: inflight with no hash stays PENDING (never falsely failed)" do
    %{keeper: keeper, store: store} = start_stack()

    {:ok, %{order_id: oid}} = Keeper.register_order(keeper, "market_phase", order_req())
    # crash after consume+put_inflight but before broadcast: no tx hash yet.
    :ok = MemoryStore.put_inflight(store, oid, oid)
    :ok = Keeper.reconcile_boot(keeper)
    # NO result is delivered — marking it failed here could double-pay via the
    # fallback lane while the tx is still mineable. The row stays inflight.
    refute_receive {:result, {^oid, _}}, 100
    assert [%{order_id: ^oid}] = MemoryStore.list_inflight(store)
  end

  test "require_owner_binding: an order that lost its expected_owner fails CLOSED" do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(rpc_url: fake, chain_id: 84_532, priv: @anvil0, rpc_mod: FakeRpc, sweep_ms: 3_600_000)

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
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
    assert {:failed, :no_grant} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    assert FakeRpc.sent(fake) == []
  end

  test "min_deadline_slack: a near-deadline permit is rejected before broadcast" do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(rpc_url: fake, chain_id: 84_532, priv: @anvil0, rpc_mod: FakeRpc, sweep_ms: 3_600_000)

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
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
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok, block_timestamp: System.os_time(:second) + 100_000})

    {:ok, signer} =
      Signer.start_link(rpc_url: fake, chain_id: 84_532, priv: @anvil0, rpc_mod: FakeRpc, sweep_ms: 3_600_000)

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer, store: {MemoryStore, store}, router: @router, action: @action,
        source_allowlist: ["market_phase"], order_ttl_s: 3_600_000,
        min_deadline_slack_s: 300, rpc_mod: FakeRpc, rpc: fake, sweep_ms: 3_600_000
      )

    {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
    wall_future = %{permit(25_000_000) | deadline: System.os_time(:second) + 3600}
    assert {:failed, :expired} = Keeper.execute_with_permit(keeper, ref, "u-a", wall_future)
    assert FakeRpc.sent(fake) == []
  end

  test "keeper sweep on a 0x0 receipt delivers {:failed, :reverted}, spend NOT recorded" do
    %{keeper: keeper, fake: fake, store: store, signer: signer} = start_stack()
    {:ok, %{order_ref: ref, order_id: oid}} = Keeper.register_order(keeper, "market_phase", order_req())
    {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x0"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert_receive {:result, {^oid, {:failed, :reverted}}}
    assert MemoryStore.spent_since(store, "u-a", 0) == 0
  end

  test "submit error (broadcast failure) maps to a terminal {:failed, :rpc_timeout}" do
    %{keeper: keeper, fake: fake} = start_stack(%{send_raw_fail: :nonce_race})
    {:ok, %{order_ref: ref, order_id: oid}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:failed, :rpc_timeout} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    assert FakeRpc.sent(fake) == []
    assert_receive {:result, {^oid, {:failed, :rpc_timeout}}}
  end

  test "reconcile_boot: a 0x0 receipt settles failed; a no-receipt hash stays pending" do
    %{keeper: keeper, fake: fake, store: store} = start_stack()

    # order A: submitted, then a 0x0 receipt appears while the keeper was 'down'
    {:ok, %{order_ref: refA, order_id: oidA}} = Keeper.register_order(keeper, "market_phase", order_req())
    {:submitted, hashA} = Keeper.execute_with_permit(keeper, refA, "u-a", permit(25_000_000))

    # order B: submitted, but NO receipt yet (still mineable)
    reqB = %{order_req() | user_ref: "u-b", action_args: [<<1::256>>, 25_000_000, <<2::256>>]}
    {:ok, %{order_ref: refB, order_id: oidB}} = Keeper.register_order(keeper, "market_phase", reqB)
    {:submitted, _hashB} = Keeper.execute_with_permit(keeper, refB, "u-b", permit(25_000_000))

    FakeRpc.put(fake, :receipts, %{hashA => %{"status" => "0x0"}})
    :ok = Keeper.reconcile_boot(keeper)

    assert_receive {:result, {^oidA, {:failed, :reverted}}}
    # B has no receipt → must NOT be settled; it stays inflight
    refute_receive {:result, {^oidB, _}}, 100
    assert Enum.any?(MemoryStore.list_inflight(store), &(&1.order_id == oidB))
  end

  defp start_backoff_stack(max) do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: {:revert, %{"m" => "x"}}})

    {:ok, signer} =
      Signer.start_link(rpc_url: fake, chain_id: 84_532, priv: @anvil0, rpc_mod: FakeRpc, sweep_ms: 3_600_000)

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer, store: {MemoryStore, store}, router: @router, action: @action,
        source_allowlist: ["market_phase"], order_ttl_s: 600,
        max_consecutive_reverts: max, sweep_ms: 3_600_000
      )

    %{fake: fake, signer: signer, store: store, keeper: keeper}
  end

  test "revert backoff (§5.2.1): N consecutive reverts suspend the grant until reset" do
    %{fake: fake, keeper: keeper} = start_backoff_stack(2)

    # two simulation-reverts accumulate the streak (zero gas each — sim gate)
    for _ <- 1..2 do
      {:ok, %{order_ref: ref}} = Keeper.register_order(keeper, "market_phase", order_req())
      assert {:failed, :reverted} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    end

    assert Keeper.backoff_count(keeper, "u-a") == 2

    # the third attempt is SUSPENDED before any simulate/broadcast
    {:ok, %{order_ref: ref3}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:failed, :suspended} = Keeper.execute_with_permit(keeper, ref3, "u-a", permit(25_000_000))
    assert FakeRpc.sent(fake) == []

    # a different user is unaffected (per-user_ref streaks)
    reqb = %{order_req() | user_ref: "u-b"}
    {:ok, %{order_ref: refb}} = Keeper.register_order(keeper, "market_phase", reqb)
    assert {:failed, :reverted} = Keeper.execute_with_permit(keeper, refb, "u-b", permit(25_000_000))

    # reset re-enables u-a; a now-OK simulation submits
    :ok = Keeper.reset_backoff(keeper, "u-a")
    assert Keeper.backoff_count(keeper, "u-a") == 0
    FakeRpc.put(fake, :simulate, :ok)
    {:ok, %{order_ref: ref4}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:submitted, _} = Keeper.execute_with_permit(keeper, ref4, "u-a", permit(25_000_000))
  end

  test "revert backoff: a credited spend resets the streak" do
    %{fake: fake, signer: signer, keeper: keeper} = start_backoff_stack(2)

    {:ok, %{order_ref: r1}} = Keeper.register_order(keeper, "market_phase", order_req())
    assert {:failed, :reverted} = Keeper.execute_with_permit(keeper, r1, "u-a", permit(25_000_000))
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

  test "post-terminal retry: after credited, re-execute returns the recorded result, no re-broadcast" do
    %{keeper: keeper, fake: fake, store: _store, signer: signer} = start_stack()
    {:ok, %{order_ref: ref, order_id: oid}} = Keeper.register_order(keeper, "market_phase", order_req())
    {:submitted, hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)
    assert_receive {:result, {^oid, {:credited, ^hash}}}
    # retry AFTER terminal settle → recorded result from the results map, no new tx
    assert {:credited, ^hash} = Keeper.execute_with_permit(keeper, ref, "u-a", permit(25_000_000))
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

    test "bind order registers and fetches; permit orders default kind" do
      %{keeper: keeper} = start_stack()

      assert {:ok, %{order_ref: bref}} =
               Keeper.register_order(keeper, "market_phase", %{
                 user_ref: "u-a",
                 amount: 0,
                 action_args: [],
                 kind: "bind"
               })

      assert {:ok, %{kind: "bind"}} = Keeper.fetch_order(keeper, bref, "u-a")

      assert {:ok, %{order_ref: pref}} = Keeper.register_order(keeper, "market_phase", order_req())
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
    test "keeper boots without signer/router/action; permit execute fails typed" do
      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(%{
          store: {MemoryStore, store},
          source_allowlist: ["app"],
          order_ttl_s: 900
        })

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(keeper, "app", %{
          user_ref: "u-a",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0}
        })

      assert {:ok, %{kind: "user_tx"}} = Keeper.fetch_order(keeper, ref, "u-a")

      {:ok, %{order_ref: pref}} =
        Keeper.register_order(keeper, "app", %{user_ref: "u-a", amount: 5, action_args: []})

      assert {:failed, :permit_lane_disabled} = Keeper.execute_with_permit(keeper, pref, "u-a", permit(5))
      assert {:ok, _} = Keeper.fetch_order(keeper, pref, "u-a")
    end
  end
end
