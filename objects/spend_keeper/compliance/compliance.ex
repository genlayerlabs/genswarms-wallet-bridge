defmodule DelegatedSpend.Compliance do
  @moduledoc """
  Boot-time validation of `ctx.compliance` — the `Keeper.BootCheck` idiom
  applied to the compliance config. Every misconfiguration below fails closed
  at request time (deny-all 451s or blanket 503s), which is correct but slow
  to diagnose; `check!/1` turns each into a loud failed deploy instead. Call
  it from app boot, after the intake ctx is built.
  """

  alias DelegatedSpend.Compliance.Store

  @store_callbacks [record_acceptance: 2, get_acceptance: 3, record_event: 2, events_for: 2]

  @doc "Validates `ctx.compliance` (no-op when absent). Raises on misconfiguration."
  def check!(%{compliance: compliance}) when is_map(compliance) do
    check_geo_allow!(Map.get(compliance, :geo_allow))
    check_terms!(Map.get(compliance, :terms), Map.get(compliance, :store))
    check_store!(Map.get(compliance, :store))
    :ok
  end

  def check!(%{compliance: other}) do
    raise ArgumentError, "ctx.compliance must be a map, got: #{inspect(other)}"
  end

  def check!(ctx) when is_map(ctx), do: :ok

  defp check_geo_allow!(allow) when is_list(allow) and allow != [] do
    for entry <- allow, Store.normalize_meta(%{country: entry}).country == nil do
      raise ArgumentError,
            "ctx.compliance.geo_allow entry #{inspect(entry)} is not an " <>
              "ISO 3166-1 alpha-2 code — the geofence would deny every request"
    end

    :ok
  end

  defp check_geo_allow!(allow) do
    raise ArgumentError,
          "ctx.compliance.geo_allow must be a non-empty country allowlist " <>
            "(got: #{inspect(allow)}) — the geofence denies every request without one"
  end

  defp check_terms!(nil, _store), do: :ok

  defp check_terms!(%{hash: "0x" <> hex, url: url}, store)
       when byte_size(hex) == 64 and is_binary(url) and url != "" do
    case Base.decode16(hex, case: :mixed) do
      {:ok, _} when store != nil ->
        :ok

      {:ok, _} ->
        raise ArgumentError,
              "ctx.compliance.terms is configured without ctx.compliance.store — " <>
                "the terms gate would answer 503 to every request"

      :error ->
        raise ArgumentError, "ctx.compliance.terms.hash is not 0x-prefixed 32-byte hex"
    end
  end

  defp check_terms!(terms, _store) do
    raise ArgumentError,
          "ctx.compliance.terms must be %{hash: \"0x\" <> 64 hex, url: binary}, " <>
            "got: #{inspect(terms)}"
  end

  defp check_store!(nil), do: :ok

  defp check_store!({module, _ref}) when is_atom(module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError, "ctx.compliance.store module #{inspect(module)} cannot be loaded"
    end

    for {fun, arity} <- @store_callbacks,
        not function_exported?(module, fun, arity) do
      raise ArgumentError,
            "ctx.compliance.store module #{inspect(module)} does not export " <>
              "#{fun}/#{arity} (see DelegatedSpend.Compliance.Store)"
    end

    :ok
  end

  defp check_store!(store) do
    raise ArgumentError,
          "ctx.compliance.store must be a {module, ref} adapter, got: #{inspect(store)}"
  end
end
