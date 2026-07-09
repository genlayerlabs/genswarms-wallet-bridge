defmodule DelegatedSpend.StoreTest do
  use ExUnit.Case
  alias DelegatedSpend.Keeper.MemoryStore

  @order %{
    order_id: "oid-1",
    order_ref: "oref-1",
    user_ref: "u-a",
    amount: 25_000_000,
    action_args: [1, 2, 3],
    expires_at: 9_999_999_999
  }

  test "order lifecycle: put, fetch by (ref, user), consume once" do
    store = MemoryStore.start()
    :ok = MemoryStore.put_order(store, @order)
    assert %{order_id: "oid-1"} = MemoryStore.get_order_by_ref(store, "oref-1", "u-a")
    assert {:ok, %{order_id: "oid-1"}} = MemoryStore.consume_order(store, "oid-1", "u-a")
    assert :already_consumed = MemoryStore.consume_order(store, "oid-1", "u-a")
  end

  test "cross-user isolation: wrong user_ref is indistinguishable from not-found" do
    store = MemoryStore.start()
    :ok = MemoryStore.put_order(store, @order)
    assert MemoryStore.get_order_by_ref(store, "oref-1", "u-EVIL") == nil
    assert :not_found = MemoryStore.consume_order(store, "oid-1", "u-EVIL")
    # and the real user can still consume — the probe changed nothing
    assert {:ok, _} = MemoryStore.consume_order(store, "oid-1", "u-a")
  end

  test "atomic single consumption under 20 concurrent callers" do
    store = MemoryStore.start()
    :ok = MemoryStore.put_order(store, @order)

    results =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> MemoryStore.consume_order(store, "oid-1", "u-a") end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == :already_consumed)) == 19
  end

  test "grant lifecycle: put, get, revoke; scoped by user_ref" do
    store = MemoryStore.start()
    assert :ok = MemoryStore.revoke_grant(store, "missing", "u-a")
    :ok = MemoryStore.put_grant(store, "g-1", "u-a", %{kind: :permit_profile})
    assert %{revoked: false} = MemoryStore.get_grant(store, "g-1", "u-a")
    assert MemoryStore.get_grant(store, "g-1", "u-EVIL") == nil
    assert [%{revoked: false}] = MemoryStore.grants_for(store, "u-a")
    :ok = MemoryStore.revoke_grant(store, "g-1", "u-a")
    assert %{revoked: true} = MemoryStore.get_grant(store, "g-1", "u-a")
  end

  test "spend accounting mirror" do
    store = MemoryStore.start()
    :ok = MemoryStore.record_spend(store, "u-a", 10, 100)
    :ok = MemoryStore.record_spend(store, "u-a", 20, 200)
    :ok = MemoryStore.record_spend(store, "u-b", 99, 200)
    assert MemoryStore.spent_since(store, "u-a", 150) == 20
    assert MemoryStore.spent_since(store, "u-a", 0) == 30
  end

  test "inflight bookkeeping for boot reconciliation" do
    store = MemoryStore.start()
    assert :ok = MemoryStore.update_inflight_hash(store, "missing", "0xabc")
    :ok = MemoryStore.put_inflight(store, "oid-1", "ak-1")
    assert [%{order_id: "oid-1", action_key: "ak-1"}] = MemoryStore.list_inflight(store)
    :ok = MemoryStore.resolve_inflight(store, "oid-1", {:credited, "0xabc"})
    assert MemoryStore.list_inflight(store) == []
  end

  test "stale ref index returns nil if the order row is gone" do
    store = MemoryStore.start()
    Agent.update(store, &put_in(&1, [:by_ref, {"oref-missing", "u-a"}], "missing-order-id"))
    assert MemoryStore.get_order_by_ref(store, "oref-missing", "u-a") == nil
  end
end
