defmodule DelegatedSpend.BootCheckTest do
  use ExUnit.Case
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Keccak
  alias DelegatedSpend.Keeper.BootCheck

  @addr "0x000000000000000000000000000000000000dEaD"
  @code <<0x60, 0x0A, 0x60, 0x0C>>
  @codehash "0x" <> Base.encode16(Keccak.hash_256(@code), case: :lower)

  test "ok when chain id and codehashes match" do
    fake =
      FakeRpc.start(%{
        chain_id: 84_532,
        codes: %{@addr => "0x" <> Base.encode16(@code, case: :lower)}
      })

    assert :ok =
             BootCheck.verify(FakeRpc, fake, %{
               chain_id: 84_532,
               codehashes: %{@addr => @codehash}
             })
  end

  test "wrong chain id fails closed" do
    fake = FakeRpc.start(%{chain_id: 1, codes: %{}})

    assert {:error, {:chain_id_mismatch, _}} =
             BootCheck.verify(FakeRpc, fake, %{chain_id: 84_532, codehashes: %{}})
  end

  test "codehash mismatch fails closed" do
    fake = FakeRpc.start(%{chain_id: 84_532, codes: %{@addr => "0xdeadbeef"}})

    assert {:error, {:codehash_mismatch, @addr, _}} =
             BootCheck.verify(FakeRpc, fake, %{
               chain_id: 84_532,
               codehashes: %{@addr => @codehash}
             })
  end
end
