defmodule DelegatedSpend.Orders do
  @moduledoc """
  Consumer-side order-building helpers (spec §0.3 wallet-order transport) —
  the generic glue every adopting host was reinventing: token-amount parsing,
  ERC-20 `transfer` calldata, the caller-minted order ref for the async
  object door, and the salted one-way `user_ref`.

  Everything here is deterministic, integer-only, and pure. Nothing here has
  crediting authority: these helpers only build a transaction the user's own
  wallet verifies, signs and submits.

  ## Why `user_ref/2` REQUIRES a salt

  `user_ref` is one-way by contract (`docs/adoption.md` §0.3), but an
  UNSALTED hash of an enumerable platform id space (Telegram user ids are
  small integers) is offline-reversible: anyone holding a ref can hash the
  whole id space in seconds and recover the platform id. The salt is a
  required argument with no default so a consumer cannot accidentally ship
  the enumerable-weak derivation; keep it secret and stable per deployment —
  changing it changes every ref.
  """

  alias DelegatedSpend.Evm.Address
  alias DelegatedSpend.Keccak

  # ERC-20 transfer(address,uint256)
  @transfer_selector "a9059cbb"
  @uint256_max Integer.pow(2, 256) - 1

  @authorization_domain "genswarms/topup-authorization/v1:"
  @sweep_domain "genswarms/deposit-sweep/v1:"

  @doc """
  The exact `tx` map the keeper's `register order` validates for kind
  `"user_tx"`: `%{to: token_address, data: transfer_calldata, value: 0}`.

  `token_address` and `recipient_address` must be `0x` + 40 hex chars;
  anything else raises — calldata to a garbled destination must never be
  built. `units` is a positive integer in the token's smallest denomination.
  The token address is passed through unmodified (a checksummed input stays
  checksummed); the recipient is lowercased inside the calldata.
  """
  @spec erc20_transfer_order(String.t(), String.t(), pos_integer) :: %{
          to: String.t(),
          data: String.t(),
          value: 0
        }
  def erc20_transfer_order(token_address, recipient_address, units) do
    validate_address!(token_address, "token_address")

    %{to: token_address, data: transfer_calldata(recipient_address, units), value: 0}
  end

  @doc """
  ABI-encode `transfer(recipient, units)`: `0x#{@transfer_selector}` ++
  32-byte left-padded address ++ 32-byte uint256 amount. Raises on a
  malformed address or a non-positive / non-uint256 amount.
  """
  @spec transfer_calldata(String.t(), pos_integer) :: String.t()
  def transfer_calldata(recipient_address, units) do
    addr = validate_address!(recipient_address, "recipient_address")

    unless is_integer(units) and units > 0 and units <= @uint256_max do
      raise ArgumentError, "transfer_calldata: units must be a positive uint256 integer"
    end

    amount_hex =
      units
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(64, "0")

    "0x" <> @transfer_selector <> String.duplicate("0", 24) <> addr <> amount_hex
  end

  @doc """
  Parse a decimal token amount ("5", "2.5", "0.10") into integer units at
  `decimals`. Integer math only — no floats ever touch a money amount.

  Accepts only canonical `digits` or `digits.digits` with at most `decimals`
  fractional digits; the result must be `> 0`. Rejections (`:error`): empty,
  surrounding whitespace, redundant leading zeros, non-numeric, exponent
  forms, signs, a bare or trailing dot, a leading dot (".5"), more fractional
  digits than `decimals`, zero, and anything above the cap.

  The cap is the `:max_units` option (integer, in UNITS — compose it with
  `decimals` yourself, e.g. 100 whole 6-decimal tokens = `100_000_000`).
  There is deliberately NO default cap: the bound is business policy, so the
  consumer must state it as a positive integer. A missing or invalid cap raises
  `ArgumentError` because that is a caller configuration bug.
  """
  @spec parse_token_amount(String.t(), non_neg_integer, keyword) ::
          {:ok, pos_integer} | :error
  def parse_token_amount(text, decimals, opts \\ [])

  def parse_token_amount(text, decimals, opts)
      when is_binary(text) and is_integer(decimals) and decimals >= 0 do
    max_units = Keyword.get(opts, :max_units)

    unless is_integer(max_units) and max_units > 0 do
      raise ArgumentError, "parse_token_amount: max_units must be a positive integer"
    end

    # \z, not $: PCRE's `$` matches before a FINAL NEWLINE, so `"5\n"` would
    # parse as 5 despite the contract above promising :error for surrounding
    # whitespace. A host that forwards a chat line verbatim would then have a
    # trailing newline silently accepted on a money amount.
    case Regex.run(~r/^(0|[1-9]\d*)(?:\.(\d+))?\z/, text) do
      [_, whole] -> to_units(whole, "", decimals, max_units)
      [_, whole, frac] -> to_units(whole, frac, decimals, max_units)
      _ -> :error
    end
  end

  def parse_token_amount(_text, _decimals, _opts), do: :error

  defp to_units(_whole, frac, decimals, _max) when byte_size(frac) > decimals, do: :error

  defp to_units(whole, frac, decimals, max_units) do
    frac_units =
      case String.pad_trailing(frac, decimals, "0") do
        "" -> 0
        padded -> String.to_integer(padded)
      end

    units = String.to_integer(whole) * Integer.pow(10, decimals) + frac_units

    cond do
      units <= 0 -> :error
      units > max_units -> :error
      true -> {:ok, units}
    end
  end

  @doc ~S"""
  Format integer units back to a human decimal string at `decimals`:
  `format_units(2_500_000, 6)` → `"2.5"`.
  """
  @spec format_units(non_neg_integer, non_neg_integer) :: String.t()
  def format_units(units, decimals)
      when is_integer(units) and units >= 0 and is_integer(decimals) and decimals >= 0 do
    factor = Integer.pow(10, decimals)
    whole = div(units, factor)
    frac = rem(units, factor)

    if frac == 0 do
      Integer.to_string(whole)
    else
      frac_s =
        frac
        |> Integer.to_string()
        |> String.pad_leading(decimals, "0")
        |> String.trim_trailing("0")

      "#{whole}.#{frac_s}"
    end
  end

  @doc """
  Caller-minted order ref for the keeper's async object door: 64 lowercase
  hex chars (32 random bytes) — exactly the server-minted shape the keeper
  enforces (format + per-user_ref uniqueness; `DelegatedSpend.Keeper`).
  """
  @spec mint_order_ref() :: String.t()
  def mint_order_ref do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  @doc """
  Opaque one-way `user_ref` for a platform id: lowercase hex
  SHA-256 over a domain-separated `salt` + `platform_id`. Deterministic —
  the same `{platform_id, salt}` always yields the same ref, so it is a
  stable storage key.

  The salt is REQUIRED and must be non-empty (see the moduledoc: unsalted
  refs over enumerable id spaces are offline-reversible). It is a
  deployment secret: keep it out of the repo, and never rotate it casually —
  every stored ref changes with it.
  """
  @spec user_ref(String.t(), String.t()) :: String.t()
  def user_ref(platform_id, salt)
      when is_binary(platform_id) and is_binary(salt) and salt != "" do
    # Length-prefixing the salt makes the (salt, platform_id) framing
    # unambiguous for ANY byte content — no delimiter to collide across.
    :crypto.hash(:sha256, ["delegated-spend-user", <<byte_size(salt)::32>>, salt, platform_id])
    |> Base.encode16(case: :lower)
  end

  def user_ref(platform_id, salt) when is_binary(platform_id) and salt == "" do
    raise ArgumentError,
          "user_ref: salt is required and must be non-empty — an unsalted ref over an " <>
            "enumerable platform-id space is offline-reversible (see DelegatedSpend.Orders docs)"
  end

  def user_ref(_platform_id, _salt) do
    raise ArgumentError, "user_ref: platform_id and salt must be binaries"
  end

  @doc """
  `nonce` EIP-3009 de una recarga, derivado de la referencia del pedido.

  Determinista a propósito: el vigilante reconoce el ingreso buscando este mismo
  valor, sin necesidad de guardar una correspondencia aparte.

  El prefijo de dominio NO es decorativo. Los `nonce` de recogida
  (`sweep_nonce/2`) viven en otro dominio precisamente para que un barrido no
  pueda parecerse jamás a una recarga; si coincidieran, un barrido se acreditaría
  como pago de usuario y regalaríamos el dinero dos veces (spec §4.4).
  """
  @spec authorization_nonce(String.t()) :: <<_::256>>
  def authorization_nonce(order_ref) when is_binary(order_ref) do
    Keccak.hash_256(@authorization_domain <> order_ref)
  end

  @doc """
  `nonce` EIP-3009 de una recogida de dirección de depósito (plan 3).

  Existe ya para que la prueba de no-colisión con `authorization_nonce/1` esté
  escrita desde el primer día.
  """
  @spec sweep_nonce(String.t(), non_neg_integer) :: <<_::256>>
  def sweep_nonce(address, epoch) when is_binary(address) and is_integer(epoch) do
    Keccak.hash_256(@sweep_domain <> address <> ":" <> Integer.to_string(epoch))
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Returns the LOWERCASED 40-hex body; rejects zero and invalid mixed-case
  # EIP-55 checksums. Per EIP-55, uniformly lower/uppercase bodies are exempt.
  defp validate_address!("0x" <> hex, label) when byte_size(hex) == 40 do
    body = String.downcase(hex)

    cond do
      not Regex.match?(~r/^[0-9a-f]{40}$/, body) ->
        raise ArgumentError, "#{label}: not a hex address"

      body == String.duplicate("0", 40) ->
        raise ArgumentError, "#{label}: zero address is not allowed"

      hex == body or hex == String.upcase(hex) ->
        body

      Address.checksum(body) == "0x" <> hex ->
        body

      true ->
        raise ArgumentError, "#{label}: invalid EIP-55 checksum"
    end
  end

  defp validate_address!(other, label) do
    raise ArgumentError, "#{label}: not a 0x 20-byte address: #{inspect(other)}"
  end
end
