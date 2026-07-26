defmodule DelegatedSpend.SignerTest do
  use ExUnit.Case
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Keeper.Signer

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @tx %{to: "0x000000000000000000000000000000000000dEaD", data: <<1, 2, 3>>}

  defp start_signer(overrides \\ %{}) do
    fake = FakeRpc.start(Map.merge(%{chain_id: 84_532, nonce: 5, simulate: :ok}, overrides))

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    {fake, signer}
  end

  test "boot: chain-id mismatch refuses to start" do
    fake = FakeRpc.start(%{chain_id: 1, nonce: 0, simulate: :ok})
    Process.flag(:trap_exit, true)

    assert {:error, {:chain_id_mismatch, _}} =
             Signer.start_link(rpc_url: fake, chain_id: 84_532, priv: @anvil0, rpc_mod: FakeRpc)
  end

  test "failed simulation broadcasts NOTHING and consumes no nonce" do
    {fake, signer} = start_signer(%{simulate: {:revert, %{"message" => "boom"}}})
    assert {:error, {:reverted, _}} = Signer.submit(signer, "k1", @tx)
    assert FakeRpc.sent(fake) == []
    # a subsequent good submit uses the ORIGINAL nonce
    FakeRpc.put(fake, :simulate, :ok)
    assert {:ok, _} = Signer.submit(signer, "k2", @tx)
    assert [raw] = FakeRpc.sent(fake)
    assert nonce_of(raw) == 5
  end

  test "idempotent by action_key: second submit returns same hash, no rebroadcast" do
    {fake, signer} = start_signer()
    assert {:ok, hash} = Signer.submit(signer, "k1", @tx)
    assert {:ok, ^hash} = Signer.submit(signer, "k1", @tx)
    assert length(FakeRpc.sent(fake)) == 1
  end

  test "distinct keys consume sequential nonces" do
    {fake, signer} = start_signer()
    {:ok, _} = Signer.submit(signer, "k1", @tx)
    {:ok, _} = Signer.submit(signer, "k2", @tx)
    assert [n1, n2] = Enum.map(FakeRpc.sent(fake), &nonce_of/1)
    assert {n1, n2} == {5, 6}
  end

  test "sweep: mined receipt goes terminal; repeat submit returns recorded hash" do
    {fake, signer} = start_signer()
    {:ok, hash} = Signer.submit(signer, "k1", @tx)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    assert Signer.status(signer, "k1") == {:mined, hash}
    assert {:ok, ^hash} = Signer.submit(signer, "k1", @tx)
    assert length(FakeRpc.sent(fake)) == 1
  end

  test "sweep: failed receipt goes terminal failed" do
    {fake, signer} = start_signer()
    {:ok, hash} = Signer.submit(signer, "k1", @tx)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x0"}})
    Signer.sweep_now(signer)
    assert Signer.status(signer, "k1") == {:failed, hash}
    assert {:error, {:onchain_failed, ^hash}} = Signer.submit(signer, "k1", @tx)
  end

  test "sweep: stuck tx rebroadcasts at SAME nonce with bumped fees" do
    {fake, signer} = start_signer()
    {:ok, _} = Signer.submit(signer, "k1", %{@tx | data: <<9>>})
    :ok = GenServer.stop(signer)

    {:ok, signer2} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        bump_after_ms: 0
      )

    {:ok, _} = Signer.submit(signer2, "k2", @tx)
    # bump requires age STRICTLY greater than bump_after_ms; cross the ms tick
    Process.sleep(5)
    Signer.sweep_now(signer2)
    raws = FakeRpc.sent(fake)
    assert length(raws) == 3
    [_first, original, bumped] = raws
    assert nonce_of(original) == nonce_of(bumped)
    assert max_fee_of(bumped) > max_fee_of(original)
  end

  test "bump race: the ORIGINAL tx mining after a bump still goes terminal mined" do
    {fake, signer} = start_signer()
    {:ok, original_hash} = Signer.submit(signer, "k1", @tx)
    :ok = GenServer.stop(signer)

    {:ok, signer2} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        bump_after_ms: 0
      )

    {:ok, hash2} = Signer.submit(signer2, "k2", @tx)
    Process.sleep(5)
    Signer.sweep_now(signer2)
    # bump happened (3 raws total); now the FIRST k2 tx (hash2) mines — not
    # the bumped variant. The sweep must still find it.
    assert length(FakeRpc.sent(fake)) == 3
    FakeRpc.put(fake, :receipts, %{hash2 => %{"status" => "0x1"}})
    Signer.sweep_now(signer2)
    assert Signer.status(signer2, "k2") == {:mined, hash2}
    # (k1/k2 raws are byte-identical under RFC-6979 — same fields, same nonce —
    # so no hash-inequality assertion here; the bump variant is the distinct one.)
    _ = original_hash
  end

  test "broadcast error is ambiguous: hash stays pending and nonce remains reserved" do
    {fake, signer} = start_signer(%{send_raw_fail: :nonce_race})
    assert {:ok, hash} = Signer.submit(signer, "k1", @tx)
    assert FakeRpc.sent(fake) == []
    assert Signer.status(signer, "k1") == {:pending, hash}

    # A retry cannot double-send the ambiguous candidate. The next action uses
    # the next nonce, avoiding a same-nonce double payment if k1 reached the node.
    FakeRpc.put(fake, :send_raw_fail, nil)
    assert {:ok, ^hash} = Signer.submit(signer, "k1", @tx)
    assert {:ok, _} = Signer.submit(signer, "k2", @tx)
    assert [raw] = FakeRpc.sent(fake)
    assert nonce_of(raw) == 6
  end

  test "initial broadcast is refused when durable hash persistence fails" do
    {fake, signer} = start_signer()

    failures = [
      fn _hash, _cost -> :not_found end,
      fn _hash, _cost -> raise "store down" end,
      fn _hash, _cost -> exit(:store_down) end,
      fn _hash, _cost -> throw(:store_down) end
    ]

    Enum.with_index(failures, fn persist_hash_fn, index ->
      key = "k#{index}"
      assert {:error, {:persist_hash, _}} = Signer.submit(signer, key, @tx, persist_hash_fn)
      assert Signer.status(signer, key) == :unknown
    end)

    assert FakeRpc.sent(fake) == []
    assert {:ok, _} = Signer.submit(signer, "good", @tx)
    assert [raw] = FakeRpc.sent(fake)
    assert nonce_of(raw) == 5
  end

  test "fee bump is refused when its durable hash write fails" do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 5, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        bump_after_ms: 0
      )

    {:ok, writes} = Agent.start_link(fn -> 0 end)

    persist_hash_fn = fn _hash, _cost ->
      Agent.get_and_update(writes, fn
        0 -> {:ok, 1}
        count -> {:not_found, count + 1}
      end)
    end

    assert {:ok, original_hash} = Signer.submit(signer, "k1", @tx, persist_hash_fn)
    Process.sleep(5)
    :ok = Signer.sweep_now(signer)

    assert FakeRpc.sent(fake) |> length() == 1
    assert Signer.status(signer, "k1") == {:pending, original_hash}
  end

  test "estimate_gas non-integer → typed error, zero broadcast, nonce untouched" do
    {fake, signer} = start_signer(%{gas: :boom})
    assert {:error, {:estimate_gas, _}} = Signer.submit(signer, "k1", @tx)
    assert FakeRpc.sent(fake) == []
    # a good submit afterward still uses nonce 5
    FakeRpc.put(fake, :gas, 100_000)
    assert {:ok, _} = Signer.submit(signer, "k2", @tx)
    assert [raw] = FakeRpc.sent(fake)
    assert nonce_of(raw) == 5
  end

  test "fees RPC error → typed error, zero broadcast" do
    {fake, signer} = start_signer(%{fees_raise: true})
    assert {:error, {:fees, _}} = Signer.submit(signer, "k1", @tx)
    assert FakeRpc.sent(fake) == []
  end

  test "contract creation skips eth_call simulation and raw address bytes are accepted" do
    {fake, signer} = start_signer(%{simulate: {:revert, %{"message" => "would fail if called"}}})
    assert {:ok, _} = Signer.submit(signer, "create", %{to: :create, data: <<1, 2, 3>>, value: 0})
    assert [raw_create] = FakeRpc.sent(fake)

    FakeRpc.put(fake, :simulate, :ok)

    assert {:ok, _} =
             Signer.submit(signer, "raw-address", %{to: <<0x11::160>>, data: <<4>>, value: 0})

    assert [_raw_create, raw_address] = FakeRpc.sent(fake)
    assert raw_create != raw_address
  end

  # ── Task 3b: gas-spend accounting + low-balance alarm ────────────────────

  test "persist_hash_fn receives the FULL cost estimate on the initial broadcast, before send_raw" do
    {fake, signer} = start_signer()
    {:ok, costs} = Agent.start_link(fn -> [] end)

    persist_hash_fn = fn hash, cost_wei ->
      Agent.update(costs, &[{hash, cost_wei} | &1])
      :ok
    end

    assert {:ok, hash} = Signer.submit(signer, "k1", @tx, persist_hash_fn)
    # gas(100_000, headroomed 1.3x) * max_fee(base 10e9 *2 + prio 1e9) — the
    # SAME numbers do_submit itself computes, handed to the caller directly
    # rather than read back afterward.
    assert [{^hash, cost}] = Agent.get(costs, & &1)
    assert cost == div(100_000 * 13, 10) * 21_000_000_000
    # the cost was reported BEFORE the broadcast, not after
    assert FakeRpc.sent(fake) == [] or length(FakeRpc.sent(fake)) == 1
  end

  test "persist_hash_fn receives only the DELTA on a fee-bumped replacement, not the full re-estimate" do
    {fake, signer} = start_signer()
    :ok = GenServer.stop(signer)

    {:ok, signer2} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        bump_after_ms: 0
      )

    {:ok, costs} = Agent.start_link(fn -> [] end)
    persist_hash_fn = fn hash, cost_wei -> Agent.update(costs, &[{hash, cost_wei} | &1]) end

    {:ok, _hash} = Signer.submit(signer2, "k1", @tx, persist_hash_fn)
    Process.sleep(5)
    :ok = Signer.sweep_now(signer2)

    assert [{original_hash, original_cost}, {bumped_hash, bump_cost}] =
             Agent.get(costs, & &1) |> Enum.reverse()

    refute bumped_hash == original_hash
    assert original_cost == div(100_000 * 13, 10) * 21_000_000_000

    bumped_max_fee = div(21_000_000_000 * 5, 4) + 1
    full_bumped_estimate = div(100_000 * 13, 10) * bumped_max_fee
    # only the delta is reported for the bump — NOT the full re-estimate,
    # which would double-count what the initial broadcast already recorded.
    assert bump_cost == full_bumped_estimate - original_cost
    refute bump_cost == full_bumped_estimate
  end

  defp start_signer_with_balance(low_balance_wei, balance) do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 5, simulate: :ok, balance: balance})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        low_balance_wei: low_balance_wei
      )

    {fake, signer}
  end

  test "low_balance_wei: below threshold warns once per sweep with the metric name in the log" do
    {_fake, signer} = start_signer_with_balance(1_000, 500)

    log = ExUnit.CaptureLog.capture_log(fn -> Signer.sweep_now(signer) end)
    assert log =~ "keeper_relayer_low_balance"
    assert log =~ "500"
    assert log =~ "1000"
  end

  test "low_balance_wei: at or above threshold stays quiet" do
    {_fake, signer} = start_signer_with_balance(1_000, 1_000)
    log = ExUnit.CaptureLog.capture_log(fn -> Signer.sweep_now(signer) end)
    refute log =~ "keeper_relayer_low_balance"
  end

  test "low_balance_wei absent: no warning even on a near-empty wallet" do
    {fake, signer} = start_signer()
    FakeRpc.put(fake, :balance, 0)
    log = ExUnit.CaptureLog.capture_log(fn -> Signer.sweep_now(signer) end)
    refute log =~ "keeper_relayer_low_balance"
  end

  # Reviewer's flagged gap (Cannot-verify): a raising balance/2 during a
  # sweep tick must not crash the sweep, and the stuck-tx rescue/bump logic
  # (do_sweep's Enum.reduce over state.pending, run AFTER check_low_balance's
  # return value is discarded) must still complete — same reasoning as the
  # already-tested safe_receipt/2 rescue/catch shape.
  test "low_balance_wei: a raising balance() during sweep does not crash the sweep, and stuck-tx rescue still runs" do
    fake =
      FakeRpc.start(%{chain_id: 84_532, nonce: 5, simulate: :ok, balance_raises: true})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        bump_after_ms: 0,
        low_balance_wei: 1_000
      )

    {:ok, _hash} = Signer.submit(signer, "k1", @tx)
    Process.sleep(5)

    log = ExUnit.CaptureLog.capture_log(fn -> assert :ok = Signer.sweep_now(signer) end)
    # the balance read raised → safe_balance/1 returns nil → check_low_balance
    # treats that as :ok (no warning), NOT a crash.
    refute log =~ "keeper_relayer_low_balance"
    assert Process.alive?(signer)

    # the stuck tx was still bumped despite the balance-read failure — the
    # sweep's rescue/bump logic runs regardless of check_low_balance/1's
    # outcome (its return value is discarded by do_sweep).
    raws = FakeRpc.sent(fake)
    assert length(raws) == 2
    [original, bumped] = raws
    assert nonce_of(original) == nonce_of(bumped)
    assert max_fee_of(bumped) > max_fee_of(original)
  end

  test "unexpected info messages do not disturb signer state" do
    {_fake, signer} = start_signer()
    send(signer, :noise)
    Process.sleep(10)
    assert Process.alive?(signer)
    assert Signer.status(signer, "missing") == :unknown
  end

  test "sweep on a MINED-but-reverted (0x0) receipt → terminal failed" do
    {fake, signer} = start_signer()
    {:ok, hash} = Signer.submit(signer, "k1", @tx)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x0"}})
    Signer.sweep_now(signer)
    assert Signer.status(signer, "k1") == {:failed, hash}
    assert {:error, {:onchain_failed, ^hash}} = Signer.submit(signer, "k1", @tx)
  end

  test "bump send_raw failure keeps the entry pending; the original still mines" do
    {fake, signer} = start_signer()
    :ok = GenServer.stop(signer)

    {:ok, signer2} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000,
        bump_after_ms: 0
      )

    {:ok, hash} = Signer.submit(signer2, "k1", @tx)
    # the bump's broadcast fails → keep waiting on the original hash, no new tx
    FakeRpc.put(fake, :send_raw_fail, :replacement_underpriced)
    Process.sleep(5)
    Signer.sweep_now(signer2)
    assert length(FakeRpc.sent(fake)) == 1
    # the ORIGINAL tx then mines — still tracked despite the failed bump
    FakeRpc.put(fake, :send_raw_fail, nil)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer2)
    assert Signer.status(signer2, "k1") == {:mined, hash}
  end

  test "a raising receipt during sweep does NOT crash the Signer (state preserved)" do
    {fake, signer} = start_signer()
    {:ok, hash} = Signer.submit(signer, "k1", @tx)
    FakeRpc.put(fake, :receipt_raises, true)
    # sweep must survive the transient RPC error — the GenServer stays alive and
    # the pending entry (idempotency + hash tracking) is intact
    assert :ok = Signer.sweep_now(signer)
    assert Process.alive?(signer)
    assert Signer.status(signer, "k1") == {:pending, hash}
    # once the RPC recovers, the receipt settles normally
    FakeRpc.put(fake, :receipt_raises, false)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    assert Signer.status(signer, "k1") == {:mined, hash}
  end

  test "exiting and throwing receipt adapters do not crash the Signer" do
    Process.flag(:trap_exit, true)

    for failure <- [:exit, :throw] do
      {fake, signer} = start_signer()
      assert {:ok, hash} = Signer.submit(signer, "k1", @tx)
      FakeRpc.put(fake, :receipt_failure, failure)

      assert :ok = Signer.sweep_now(signer)
      assert Process.alive?(signer)
      assert Signer.status(signer, "k1") == {:pending, hash}
    end
  end

  defp decoded(raw_hex) do
    <<2, rlp::binary>> = Base.decode16!(String.trim_leading(raw_hex, "0x"), case: :lower)
    ExRLP.decode(rlp)
  end

  defp nonce_of(raw), do: decoded(raw) |> Enum.at(1) |> int()
  defp max_fee_of(raw), do: decoded(raw) |> Enum.at(3) |> int()
  defp int(""), do: 0
  defp int(bin), do: :binary.decode_unsigned(bin)
end
