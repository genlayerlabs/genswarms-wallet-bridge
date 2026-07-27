defmodule DelegatedSpend.Eip3009VectorsTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Keeper.Eip3009

  # Leído de la cadena el 2026-07-26: DOMAIN_SEPARATOR() (0x3644e515) del USDC
  # 0x036CbD53842c5426634e7929541eC2318f3dCF7e en Base Sepolia (name() = "USDC").
  # Si este valor cambia, el contrato se ha migrado: PARAR y reverificar, nunca
  # actualizar el vector a ciegas para poner el test en verde.
  @domain_separator Base.decode16!(
                      "71f17a3b2ff373b803d70a5a07c046c1a2bc8e89c09ef722fcb047abe94c9818",
                      case: :lower
                    )

  test "el typehash es el de EIP-3009" do
    # Valor público y conocido del estándar: si esta constante se calcula mal,
    # todas las firmas fallan en cadena sin diagnóstico útil.
    assert Base.encode16(Eip3009.typehash(), case: :lower) ==
             "7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267"
  end

  test "dígito congelado para una autorización conocida" do
    digest =
      Eip3009.authorization_digest(
        @domain_separator,
        "0x1111111111111111111111111111111111111111",
        "0x2222222222222222222222222222222222222222",
        1_000_000,
        0,
        2_000_000_000,
        <<0::248, 7>>
      )

    assert Base.encode16(digest, case: :lower) ==
             "e0333a66b53a762c640c56d0ba835585871c4f4d7c747a874ea65d32e26fca5c"
  end
end
