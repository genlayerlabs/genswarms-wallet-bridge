defmodule DelegatedSpend.AbiTest do
  use ExUnit.Case, async: true
  alias DelegatedSpend.Evm.Abi

  test "selector: transfer(address,uint256) is the canonical a9059cbb" do
    <<sel::binary-size(4), _::binary>> =
      Abi.encode_call("transfer", [:address, {:uint, 256}], [<<0::160>>, 0])

    assert Base.encode16(sel, case: :lower) == "a9059cbb"
  end

  test "encode/decode roundtrip" do
    types = [{:bytes, 32}, {:uint, 256}]
    args = [<<7::256>>, 42]
    encoded = Abi.encode_call("f", types, args)
    <<_sel::binary-size(4), body::binary>> = encoded
    assert Abi.decode_result(types, body) == args
  end

  test "constructor encoding is ABI args without a selector" do
    assert Abi.encode_constructor([:address, {:uint, 256}], [<<1::160>>, 7]) ==
             ABI.TypeEncoder.encode([<<1::160>>, 7], %ABI.FunctionSelector{
               function: nil,
               types: [:address, {:uint, 256}]
             })
  end

  test "event topic0" do
    assert Base.encode16(Abi.event_topic0("Transfer(address,address,uint256)"), case: :lower) ==
             "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  end
end
