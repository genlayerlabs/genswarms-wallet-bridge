defmodule DelegatedSpend.Tx1559Test do
  use ExUnit.Case, async: true
  alias DelegatedSpend.Evm.{Address, Secp256k1, Tx1559}
  alias DelegatedSpend.Keccak

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")

  @params %{
    nonce: 7,
    max_priority_fee: 1_000_000_000,
    max_fee: 30_000_000_000,
    gas: 100_000,
    to: "0x000000000000000000000000000000000000dEaD",
    value: 0,
    data: <<0xA9, 0x05, 0x9C, 0xBB>>,
    chain_id: 84_532
  }

  test "envelope: type byte, field order, recoverable signer" do
    {raw_hex, tx_hash} = Tx1559.sign(@params, @anvil0)
    raw = Base.decode16!(String.trim_leading(raw_hex, "0x"), case: :lower)
    assert <<2, rlp::binary>> = raw
    assert tx_hash == "0x" <> Base.encode16(Keccak.hash_256(raw), case: :lower)

    [cid, nonce, prio, max_fee, gas, to, value, data, access, y, r, s] = ExRLP.decode(rlp)
    assert :binary.decode_unsigned(cid) == 84_532
    assert :binary.decode_unsigned(nonce) == 7
    assert :binary.decode_unsigned(prio) == 1_000_000_000
    assert :binary.decode_unsigned(max_fee) == 30_000_000_000
    assert :binary.decode_unsigned(gas) == 100_000
    assert byte_size(to) == 20
    assert value == ""
    assert data == <<0xA9, 0x05, 0x9C, 0xBB>>
    assert access == []

    digest =
      Keccak.hash_256(
        <<2>> <> ExRLP.encode([cid, nonce, prio, max_fee, gas, to, value, data, []])
      )

    <<4, pub::binary>> = Secp256k1.recover(digest, r, s, :binary.decode_unsigned(y))
    addr = "0x" <> (pub |> Keccak.hash_256() |> binary_part(12, 20) |> Base.encode16(case: :lower))
    assert String.downcase(Address.from_private_key(@anvil0)) == addr
  end

  test "deterministic (RFC-6979): identical params, identical raw" do
    assert Tx1559.sign(@params, @anvil0) == Tx1559.sign(@params, @anvil0)
  end

  test "create: empty to field" do
    {raw_hex, _} = Tx1559.sign(%{@params | to: :create, data: <<1, 2, 3>>}, @anvil0)
    raw = Base.decode16!(String.trim_leading(raw_hex, "0x"), case: :lower)
    <<2, rlp::binary>> = raw
    [_, _, _, _, _, to, _, _, _, _, _, _] = ExRLP.decode(rlp)
    assert to == ""
  end

  test "to may be supplied as raw address bytes" do
    to = <<0x11::160>>
    {raw_hex, _} = Tx1559.sign(%{@params | to: to}, @anvil0)
    raw = Base.decode16!(String.trim_leading(raw_hex, "0x"), case: :lower)
    <<2, rlp::binary>> = raw
    [_, _, _, _, _, decoded_to, _, _, _, _, _, _] = ExRLP.decode(rlp)
    assert decoded_to == to
  end

  test "address helpers cover create, binary pass-through, and 0X equality" do
    sender = "0x000000000000000000000000000000000000dEaD"
    expected =
      [Address.to_bytes(sender), 7]
      |> ExRLP.encode()
      |> Keccak.hash_256()
      |> binary_part(12, 20)
      |> Address.checksum()

    assert Address.create_address(sender, 7) == expected
    assert Address.to_bytes(<<1::160>>) == <<1::160>>
    assert Address.eq?("0x000000000000000000000000000000000000dead", "0X000000000000000000000000000000000000DEAD")
  end
end
