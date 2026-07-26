defmodule DelegatedSpend.Keeper.GasPolicy do
  @moduledoc """
  Los tres frenos económicos de la vía patrocinada, en una función pura.

  Pura a propósito: son las reglas que deciden cuándo NO gastamos dinero, y
  quiero poder probarlas sin red, sin reloj y sin estado.

  Un límite ausente no limita. La configuración vacía admite todo — es lo
  correcto para un despliegue que aún no ha decidido sus números, y por eso los
  valores reales se fijan MIDIENDO (Task 7), no intuyendo.
  """

  @spec admit(map, map) ::
          :ok | {:reject, :gas_too_expensive | :budget_exhausted | :below_minimum}
  def admit(%{gas_price_wei: price, spent_today_wei: spent, order_units: units}, config) do
    cond do
      over?(units, Map.get(config, :min_order_units)) == :below -> {:reject, :below_minimum}
      exceeds?(price, Map.get(config, :max_gas_wei)) -> {:reject, :gas_too_expensive}
      at_or_over?(spent, Map.get(config, :daily_gas_budget_wei)) -> {:reject, :budget_exhausted}
      true -> :ok
    end
  end

  defp over?(_units, nil), do: :ok
  defp over?(units, minimum) when units < minimum, do: :below
  defp over?(_units, _minimum), do: :ok

  defp exceeds?(_value, nil), do: false
  defp exceeds?(value, limit), do: value > limit

  defp at_or_over?(_value, nil), do: false
  defp at_or_over?(value, limit), do: value >= limit
end
