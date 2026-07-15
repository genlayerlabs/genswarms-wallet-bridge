defmodule DelegatedSpend.Compliance.GeoTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Compliance.Geo

  test "matches two-letter ASCII country codes case-insensitively" do
    assert Geo.allowed?(["us", "Gb"], "US")
    assert Geo.allowed?(["US", "GB"], "gb")
    refute Geo.allowed?(["US"], "GB")
  end

  test "rejects malformed countries" do
    for country <- [nil, :us, "", "U", "USA", "U1", "U_", "ÜS"] do
      refute Geo.allowed?(["US"], country)
    end
  end

  test "a malformed entry denies the entire allowlist" do
    for invalid <- [nil, :us, "", "U", "USA", "U1", "U_", "ÜS"] do
      refute Geo.allowed?(["us", invalid], "US")
    end
  end

  test "an empty or malformed allowlist denies everyone" do
    for allow <- [[], nil, "US", %{}, :all] do
      refute Geo.allowed?(allow, "US")
    end
  end
end
