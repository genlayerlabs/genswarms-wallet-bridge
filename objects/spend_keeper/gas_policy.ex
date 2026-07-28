defmodule DelegatedSpend.Keeper.GasPolicy do
  @moduledoc """
  Los tres frenos económicos de la vía patrocinada, en funciones puras.

  Pura a propósito: son las reglas que deciden cuándo NO gastamos dinero, y
  quiero poder probarlas sin red, sin reloj y sin estado.

  El importe mínimo es común a las vías patrocinada y self-submit. Los límites
  de precio y presupuesto sólo protegen al sponsor, así que se exponen aparte
  para que self-submit no necesite leer gas ni contabilidad del relayer.

  Un límite ausente no limita. La configuración vacía admite todo — es lo
  correcto para un despliegue que aún no ha decidido sus números, y por eso los
  valores reales se fijan MIDIENDO (Task 7), no intuyendo.
  """

  @spec minimum(non_neg_integer, map) :: :ok | {:reject, :below_minimum}
  def minimum(units, config) do
    if over?(units, Map.get(config, :min_order_units)) == :below,
      do: {:reject, :below_minimum},
      else: :ok
  end

  @spec sponsor_admit(map, map) ::
          :ok | {:reject, :gas_too_expensive | :budget_exhausted}
  def sponsor_admit(%{gas_price_wei: price, spent_today_wei: spent}, config) do
    cond do
      exceeds?(price, Map.get(config, :max_gas_wei)) -> {:reject, :gas_too_expensive}
      at_or_over?(spent, Map.get(config, :daily_gas_budget_wei)) -> {:reject, :budget_exhausted}
      true -> :ok
    end
  end

  @spec admit(map, map) ::
          :ok | {:reject, :gas_too_expensive | :budget_exhausted | :below_minimum}
  def admit(%{order_units: units} = readings, config) do
    with :ok <- minimum(units, config) do
      sponsor_admit(readings, config)
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
