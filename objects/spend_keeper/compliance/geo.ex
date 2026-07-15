defmodule DelegatedSpend.Compliance.Geo do
  @moduledoc "Country allowlist checks for server-owned request metadata."

  alias DelegatedSpend.Compliance.Store

  @spec allowed?(term(), term()) :: boolean()
  def allowed?(allow, country) when is_list(allow) do
    allow = Enum.map(allow, &Store.normalize_meta(%{country: &1}).country)
    country = Store.normalize_meta(%{country: country}).country

    country != nil and allow != [] and nil not in allow and country in allow
  end

  def allowed?(_allow, _country), do: false
end
