defmodule DelegatedSpend.ComplianceTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Compliance
  alias DelegatedSpend.Compliance.MemoryStore

  defmodule PartialStore do
    def record_acceptance(_ref, _acceptance), do: :ok
    def get_acceptance(_ref, _user_ref, _v_hash), do: nil
  end

  @terms %{hash: "0x" <> String.duplicate("11", 32), url: "https://example.test/terms"}

  defp ctx(compliance), do: %{keeper: :whatever, compliance: compliance}

  test "no compliance key is a no-op" do
    assert Compliance.check!(%{keeper: :whatever}) == :ok
  end

  test "full and geofence-only configs pass" do
    assert Compliance.check!(
             ctx(%{geo_allow: ["US", "gb"], terms: @terms, store: {MemoryStore, self()}})
           ) == :ok

    assert Compliance.check!(ctx(%{geo_allow: ["US"]})) == :ok
  end

  test "missing, empty, non-list, and malformed allowlists raise" do
    for allow <- [nil, [], "US", ["USA"], ["US", ""]] do
      assert_raise ArgumentError, ~r/geo_allow/, fn ->
        Compliance.check!(ctx(%{geo_allow: allow}))
      end
    end
  end

  test "terms misconfigurations raise with the failing part named" do
    assert_raise ArgumentError, ~r/without ctx\.compliance\.store/, fn ->
      Compliance.check!(ctx(%{geo_allow: ["US"], terms: @terms}))
    end

    assert_raise ArgumentError, ~r/terms/, fn ->
      Compliance.check!(
        ctx(%{geo_allow: ["US"], terms: %{@terms | hash: "0xzz"}, store: {MemoryStore, self()}})
      )
    end

    assert_raise ArgumentError, ~r/not 0x-prefixed 32-byte hex/, fn ->
      Compliance.check!(
        ctx(%{
          geo_allow: ["US"],
          terms: %{@terms | hash: "0x" <> String.duplicate("zz", 32)},
          store: {MemoryStore, self()}
        })
      )
    end

    assert_raise ArgumentError, ~r/terms/, fn ->
      Compliance.check!(
        ctx(%{geo_allow: ["US"], terms: %{@terms | url: ""}, store: {MemoryStore, self()}})
      )
    end
  end

  test "store misconfigurations raise with the missing callback named" do
    assert_raise ArgumentError, ~r/must be a \{module, ref\}/, fn ->
      Compliance.check!(ctx(%{geo_allow: ["US"], store: MemoryStore}))
    end

    assert_raise ArgumentError, ~r/record_event\/2/, fn ->
      Compliance.check!(ctx(%{geo_allow: ["US"], store: {PartialStore, nil}}))
    end

    assert_raise ArgumentError, ~r/cannot be loaded/, fn ->
      Compliance.check!(ctx(%{geo_allow: ["US"], store: {Missing.Module, nil}}))
    end
  end

  test "a non-map compliance value raises" do
    assert_raise ArgumentError, ~r/must be a map/, fn ->
      Compliance.check!(ctx([]))
    end
  end
end
