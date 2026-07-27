defmodule DelegatedSpend.GasPolicyTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Keeper.GasPolicy

  @config %{
    max_gas_wei: 100,
    daily_gas_budget_wei: 1_000,
    min_order_units: 1_000_000
  }

  test "admite lo que está dentro de los tres límites" do
    assert :ok =
             GasPolicy.admit(
               %{gas_price_wei: 50, spent_today_wei: 0, order_units: 1_000_000},
               @config
             )
  end

  test "rechaza por encima del techo de precio" do
    assert {:reject, :gas_too_expensive} =
             GasPolicy.admit(
               %{gas_price_wei: 101, spent_today_wei: 0, order_units: 1_000_000},
               @config
             )
  end

  test "rechaza con el presupuesto diario agotado" do
    assert {:reject, :budget_exhausted} =
             GasPolicy.admit(
               %{gas_price_wei: 50, spent_today_wei: 1_000, order_units: 1_000_000},
               @config
             )
  end

  test "rechaza por debajo del importe mínimo" do
    assert {:reject, :below_minimum} =
             GasPolicy.admit(
               %{gas_price_wei: 50, spent_today_wei: 0, order_units: 999_999},
               @config
             )
  end

  test "sin límites configurados no bloquea nada" do
    assert :ok =
             GasPolicy.admit(
               %{gas_price_wei: 10_000, spent_today_wei: 10_000, order_units: 1},
               %{}
             )
  end
end
