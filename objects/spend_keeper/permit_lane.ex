defmodule DelegatedSpend.Keeper.PermitLane do
  @moduledoc """
  Permit-lane calldata: compose the concrete router's `<action>WithPermit`
  call from (a) the app's pinned action config, (b) the server-authoritative
  order's args, and (c) the user's permit envelope. The keeper never invents
  arguments — args come from the stored order, the permit from the user.

  The tail `[owner, deadline, v, r, s]` is the SpendRouter convention; the
  permit shape is byte-matched with the wallet dapp per spec §3.1.
  """

  alias DelegatedSpend.Evm.{Abi, Address}
  alias DelegatedSpend.Keccak

  @permit_typehash Keccak.hash_256(
                     "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                   )

  @tail_types [:address, {:uint, 256}, {:uint, 8}, {:bytes, 32}, {:bytes, 32}]

  def build_call(%{with_permit_name: name, arg_types: types}, action_args, permit)
      when length(action_args) == length(types) do
    %{owner: owner, deadline: deadline, v: v, r: r, s: s} = permit
    <<_::binary-size(32)>> = r
    <<_::binary-size(32)>> = s

    Abi.encode_call(
      name,
      types ++ @tail_types,
      action_args ++ [Address.to_bytes(owner), deadline, v, r, s]
    )
  end

  @doc "EIP-2612 digest for USDC-shaped tokens (typehash includes nonce)."
  def permit_digest(
        <<_::binary-size(32)>> = domain_separator,
        owner,
        spender,
        value,
        nonce,
        deadline
      ) do
    struct_hash =
      Keccak.hash_256(
        @permit_typehash <>
          pad_address(owner) <>
          pad_address(spender) <>
          <<value::256>> <> <<nonce::256>> <> <<deadline::256>>
      )

    Keccak.hash_256(<<0x19, 0x01>> <> domain_separator <> struct_hash)
  end

  defp pad_address(addr), do: <<0::96>> <> Address.to_bytes(addr)
end
