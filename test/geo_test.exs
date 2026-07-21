defmodule DelegatedSpend.Compliance.GeoTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Compliance.Geo

  test "matches blocked two-letter ASCII country codes case-insensitively" do
    refute Geo.allowed?(["cu", "Kp"], "CU")
    refute Geo.allowed?(["CU", "KP"], "kp")
    assert Geo.allowed?(["CU"], "GB")
  end

  test "rejects malformed or missing countries even when not blocked" do
    for country <- [nil, :us, "", "U", "USA", "U1", "U_", "ÜS"] do
      refute Geo.allowed?(["CU"], country)
    end
  end

  test "a malformed entry denies everyone — the blocklist cannot be trusted" do
    for invalid <- [nil, :cu, "", "C", "CUB", "C1", "C_", "ÇU"] do
      refute Geo.allowed?(["cu", invalid], "US")
    end
  end

  test "an empty or malformed blocklist denies everyone" do
    for block <- [[], nil, "CU", %{}, :none] do
      refute Geo.allowed?(block, "US")
    end
  end
end
