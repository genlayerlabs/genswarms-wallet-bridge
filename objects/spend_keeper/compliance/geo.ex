defmodule DelegatedSpend.Compliance.Geo do
  @moduledoc """
  Country blocklist checks for server-owned request metadata.

  A request passes only with valid country evidence, a well-formed non-empty
  blocklist, and the country not on it. Everything else — missing or
  malformed country, malformed blocklist entry, empty or non-list blocklist —
  fails closed: without trustworthy evidence and a trustworthy list, "not in
  a restricted region" cannot be shown.
  """

  alias DelegatedSpend.Compliance.Store

  @spec allowed?(term(), term()) :: boolean()
  def allowed?(block, country) when is_list(block) do
    block = Enum.map(block, &Store.normalize_meta(%{country: &1}).country)
    country = Store.normalize_meta(%{country: country}).country

    country != nil and block != [] and nil not in block and country not in block
  end

  def allowed?(_block, _country), do: false
end
