defmodule DelegatedSpend.Eip3009Test do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Keeper.Eip3009

  @domain <<1::256>>
  @from "0x1111111111111111111111111111111111111111"
  @to "0x2222222222222222222222222222222222222222"
  @nonce <<3::256>>

  test "el dígito es de 32 bytes y cambia con cada campo" do
    base = Eip3009.authorization_digest(@domain, @from, @to, 1_000_000, 0, 99, @nonce)
    assert byte_size(base) == 32

    # Cada campo debe entrar en el dígito. Si alguno no entra, la firma del
    # usuario cubriría menos de lo que cree estar firmando.
    refute base == Eip3009.authorization_digest(<<9::256>>, @from, @to, 1_000_000, 0, 99, @nonce)
    refute base == Eip3009.authorization_digest(@domain, @to, @to, 1_000_000, 0, 99, @nonce)
    refute base == Eip3009.authorization_digest(@domain, @from, @from, 1_000_000, 0, 99, @nonce)
    refute base == Eip3009.authorization_digest(@domain, @from, @to, 1_000_001, 0, 99, @nonce)
    refute base == Eip3009.authorization_digest(@domain, @from, @to, 1_000_000, 1, 99, @nonce)
    refute base == Eip3009.authorization_digest(@domain, @from, @to, 1_000_000, 0, 100, @nonce)
    refute base == Eip3009.authorization_digest(@domain, @from, @to, 1_000_000, 0, 99, <<4::256>>)
  end

  test "la calldata usa la sobrecarga de firma en bytes y codifica los dinámicos" do
    sig = :binary.copy(<<0xAB>>, 65)
    data = Eip3009.transfer_with_authorization_calldata(@from, @to, 1_000_000, 0, 99, @nonce, sig)

    assert String.starts_with?(data, "0xcf092995")

    body = data |> String.replace_prefix("0x", "") |> Base.decode16!(case: :lower)
    <<_selector::binary-4, rest::binary>> = body

    # 6 palabras de cabecera, luego el desplazamiento (0xe0 = 7*32) y la longitud.
    <<_from::binary-32, _to::binary-32, value::256, valid_after::256, valid_before::256,
      nonce::binary-32, offset::256, len::256, tail::binary>> = rest

    assert value == 1_000_000
    assert valid_after == 0
    assert valid_before == 99
    assert nonce == @nonce
    assert offset == 0xE0
    assert len == 65
    # 65 bytes se rellenan a 96 (3 palabras); el relleno debe ser ceros.
    assert byte_size(tail) == 96
    assert :binary.part(tail, 0, 65) == sig
    assert :binary.part(tail, 65, 31) == <<0::248>>
  end

  test "rechaza una firma de longitud imposible" do
    assert_raise ArgumentError, fn ->
      Eip3009.transfer_with_authorization_calldata(@from, @to, 1, 0, 99, @nonce, <<>>)
    end
  end
end
