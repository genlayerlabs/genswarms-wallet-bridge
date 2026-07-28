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
  @self_from "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  @self_to "0x" <> String.duplicate("99", 20)
  @self_nonce Base.decode16!(
                "8817131248d609f6b5fbd43abf3b986ecd7c4d646cd2cb5d2a189f53ebcb8ae0",
                case: :lower
              )
  @self_signature Base.decode16!(
                    "fc34e4400f892e892fd64241dbee86cc4176bc638d347ea397c9bedd221f6e6a" <>
                      "5710b62f7006a38bebb549e25f03337be8ff23776a67994762bdb6ea8dc2ee2e1b",
                    case: :lower
                  )
  @self_calldata "0xcf092995000000000000000000000000f39fd6e51aad88f6f4ce6a" <>
                   "b8827279cfffb922660000000000000000000000009999999999999999999999999999" <>
                   "99999999999900000000000000000000000000000000000000000000000000000000" <>
                   "000f4240000000000000000000000000000000000000000000000000000000000000" <>
                   "000000000000000000000000000000000000000000000000000000000000ee6b2800" <>
                   "8817131248d609f6b5fbd43abf3b986ecd7c4d646cd2cb5d2a189f53ebcb8ae00000" <>
                   "0000000000000000000000000000000000000000000000000000000000e000000000" <>
                   "00000000000000000000000000000000000000000000000000000041fc34e4400f89" <>
                   "2e892fd64241dbee86cc4176bc638d347ea397c9bedd221f6e6a5710b62f7006a38b" <>
                   "ebb549e25f03337be8ff23776a67994762bdb6ea8dc2ee2e1b000000000000000000" <>
                   "00000000000000000000000000000000000000000000"

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

  test "WB1: calldata self-submit congelada usa transfer_with_authorization_calldata/7" do
    assert Eip3009.transfer_with_authorization_calldata(
             @self_from,
             @self_to,
             1_000_000,
             0,
             4_000_000_000,
             @self_nonce,
             @self_signature
           ) == @self_calldata
  end
end
