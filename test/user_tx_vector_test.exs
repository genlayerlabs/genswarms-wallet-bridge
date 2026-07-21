defmodule DelegatedSpend.UserTxVectorTest do
  use ExUnit.Case, async: true

  test "intake serves the user_tx golden vector byte-for-byte" do
    fixture = "vectors/user_tx/order-1.json" |> File.read!() |> Jason.decode!()

    store = DelegatedSpend.Keeper.MemoryStore.start()

    {:ok, keeper} =
      DelegatedSpend.Keeper.start_link(%{
        store: {DelegatedSpend.Keeper.MemoryStore, store},
        source_allowlist: ["vector"],
        order_ttl_s: 900,
        chain_id: 84_532
      })

    user_ref = "0x" <> String.duplicate("aa", 32)

    {:ok, _} =
      DelegatedSpend.Keeper.register_order(keeper, "vector", %{
        user_ref: user_ref,
        amount: fixture["amount"],
        action_args: [],
        kind: "user_tx",
        order_ref: fixture["order_ref"],
        tx: %{to: fixture["tx"]["to"], data: fixture["tx"]["data"], value: fixture["tx"]["value"]},
        display: %{summary_lines: fixture["display"]["summary_lines"]}
      })

    token = DelegatedSpend.Intake.Token.mint("s", fixture["order_ref"], user_ref, 2_000_000_000)

    ctx = %{
      keeper: keeper,
      token_secret: "s",
      bot_token: "unused",
      max_age_s: 60,
      user_ref_fn: & &1
    }

    assert {200, body} =
             DelegatedSpend.Intake.handle_order(
               %{"order_ref" => fixture["order_ref"], "token" => token},
               ctx
             )

    for key <- ["order_ref", "kind", "amount", "display", "tx"] do
      assert body[key] == fixture[key], "field #{key} diverged from the golden vector"
    end

    # not part of the golden fixture (it's runtime state, not order bytes),
    # but every served view must carry the keeper's chain id
    assert body["chain_id"] == 84_532
  end
end
