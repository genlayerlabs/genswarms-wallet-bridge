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

  test "broadcast failure: nonce NOT consumed, nothing pending, retryable at same nonce" do
    {fake, signer} = start_signer(%{send_raw_fail: :nonce_race})
    assert {:error, {:broadcast, :nonce_race}} = Signer.submit(signer, "k1", @tx)
    assert FakeRpc.sent(fake) == []
    assert Signer.status(signer, "k1") == :unknown
    # clear the failure and retry the SAME key — must broadcast at the ORIGINAL nonce
    FakeRpc.put(fake, :send_raw_fail, nil)
    assert {:ok, _} = Signer.submit(signer, "k1", @tx)
    assert [raw] = FakeRpc.sent(fake)
    assert nonce_of(raw) == 5
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
    assert {:ok, _} = Signer.submit(signer, "raw-address", %{to: <<0x11::160>>, data: <<4>>, value: 0})
    assert [_raw_create, raw_address] = FakeRpc.sent(fake)
    assert raw_create != raw_address
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
        rpc_url: fake, chain_id: 84_532, priv: @anvil0, rpc_mod: FakeRpc,
        sweep_ms: 3_600_000, bump_after_ms: 0
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

  defp decoded(raw_hex) do
    <<2, rlp::binary>> = Base.decode16!(String.trim_leading(raw_hex, "0x"), case: :lower)
    ExRLP.decode(rlp)
  end

  defp nonce_of(raw), do: decoded(raw) |> Enum.at(1) |> int()
  defp max_fee_of(raw), do: decoded(raw) |> Enum.at(3) |> int()
  defp int(""), do: 0
  defp int(bin), do: :binary.decode_unsigned(bin)
end
