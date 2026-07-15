defmodule DelegatedSpend.Compliance.StoreTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Compliance.{MemoryStore, Store}
  alias DelegatedSpend.Intake

  @empty_meta %{ip: nil, country: nil, user_agent: nil, session_id: nil}

  test "exposes exactly the compliance adapter callbacks" do
    assert Store.behaviour_info(:callbacks) |> Enum.sort() ==
             [events_for: 2, get_acceptance: 3, record_acceptance: 2, record_event: 2]
  end

  test "acceptance evidence is first-write-wins and keyed by user and version hash" do
    store = MemoryStore.start()

    acceptance = %{
      user_ref: "opaque-user-a",
      v_hash: "terms-v1",
      account: "0xabc",
      sig: %{v: 27, r: "0x11", s: "0x22"},
      issued_at: 100,
      accepted_at: 101,
      meta: %{ip: "203.0.113.4", country: "uS", user_agent: "wallet/1.0", ignored: "drop"}
    }

    assert :ok = MemoryStore.record_acceptance(store, acceptance)

    assert :ok =
             MemoryStore.record_acceptance(store, %{
               acceptance
               | account: "0xreplay",
                 accepted_at: 999
             })

    assert MemoryStore.get_acceptance(store, "opaque-user-a", "terms-v1") == %{
             acceptance
             | meta: %{
                 ip: "203.0.113.4",
                 country: "US",
                 user_agent: "wallet/1.0",
                 session_id: nil
               }
           }

    assert MemoryStore.get_acceptance(store, "opaque-user-b", "terms-v1") == nil
    assert MemoryStore.get_acceptance(store, "opaque-user-a", "terms-v2") == nil
  end

  test "events append in write order and legal-export reads are scoped without mutation" do
    store = MemoryStore.start()

    first = %{
      user_ref: "opaque-user-a",
      kind: "wallet_bound",
      at: 100,
      meta: %{country: "gb", session_id: "session-1", raw: "drop"},
      wallet: "0xabc",
      order_ref: "bind-1"
    }

    second = %{first | kind: "grant_submitted", at: 101, order_ref: "order-1"}
    other = %{first | user_ref: "opaque-user-b", at: 102}

    assert :ok = MemoryStore.record_event(store, first)
    assert :ok = MemoryStore.record_event(store, other)
    assert :ok = MemoryStore.record_event(store, second)

    expected = [
      %{first | meta: %{ip: nil, country: "GB", user_agent: nil, session_id: "session-1"}},
      %{second | meta: %{ip: nil, country: "GB", user_agent: nil, session_id: "session-1"}}
    ]

    assert MemoryStore.events_for(store, "opaque-user-a") == expected
    assert MemoryStore.events_for(store, "opaque-user-a") == expected
    assert [%{user_ref: "opaque-user-b"}] = MemoryStore.events_for(store, "opaque-user-b")
    assert MemoryStore.events_for(store, "missing") == []
  end

  test "two-arity intake handlers delegate with empty request metadata" do
    ctx = %{bot_token: "test-token", max_age_s: 900}

    for handler <- [:handle_order, :handle_grant, :handle_wallet, :handle_submitted] do
      assert apply(Intake, handler, [%{}, ctx]) == apply(Intake, handler, [%{}, %{}, ctx])
    end
  end

  test "normalizes the four allowed fields and drops unknown keys" do
    assert Store.normalize_meta(%{
             ip: "203.0.113.4",
             country: "uS",
             user_agent: "wallet/1.0",
             session_id: "session-1",
             ignored: "client data"
           }) == %{
             ip: "203.0.113.4",
             country: "US",
             user_agent: "wallet/1.0",
             session_id: "session-1"
           }
  end

  test "accepts only two ASCII letters as a country" do
    for country <- [nil, :us, "", "U", "USA", "U1", "U_", "Ü", "ß"] do
      assert %{country: nil} = Store.normalize_meta(%{country: country})
    end

    assert %{country: "GB"} = Store.normalize_meta(%{country: "Gb"})
  end

  test "bounds user agents by bytes without splitting valid UTF-8" do
    utf8 = String.duplicate("a", 255) <> "é"
    normalized = Store.normalize_meta(%{user_agent: utf8}).user_agent

    assert normalized == String.duplicate("a", 255)
    assert byte_size(normalized) <= 256
    assert String.valid?(normalized)

    binary = :binary.copy(<<255>>, 300)
    assert Store.normalize_meta(%{user_agent: binary}).user_agent == binary_part(binary, 0, 256)
  end

  test "returns the empty shape for nil and non-map input" do
    assert Store.normalize_meta(nil) == @empty_meta
    assert Store.normalize_meta("not a map") == @empty_meta
    assert Store.normalize_meta(%{user_agent: 42, unknown: true}) == @empty_meta
  end
end
