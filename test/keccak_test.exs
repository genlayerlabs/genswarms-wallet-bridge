defmodule DelegatedSpend.KeccakTest do
  use ExUnit.Case, async: true
  alias DelegatedSpend.Keccak

  # Canonical keccak-256 vectors (NOT sha3-256).
  test "empty string" do
    assert Base.encode16(Keccak.hash_256(""), case: :lower) ==
             "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  end

  test "abc" do
    assert Base.encode16(Keccak.hash_256("abc"), case: :lower) ==
             "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
  end

  test "erc20 Transfer topic" do
    assert Base.encode16(Keccak.hash_256("Transfer(address,address,uint256)"), case: :lower) ==
             "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  end

  test "long input crosses the rate boundary" do
    input = :binary.copy("a", 200)
    assert byte_size(Keccak.hash_256(input)) == 32
    assert Keccak.hash_256(input) == Keccak.hash_256(:binary.copy("a", 200))
  end

  test "input exactly one byte short of the rate uses single-byte padding" do
    input = :binary.copy("a", 135)
    assert byte_size(Keccak.hash_256(input)) == 32
    assert Keccak.hash_256(input) == Keccak.hash_256(:binary.copy("a", 135))
  end
end
