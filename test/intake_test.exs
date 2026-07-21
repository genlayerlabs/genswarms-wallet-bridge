defmodule DelegatedSpend.IntakeTest do
  use ExUnit.Case

  @moduletag :capture_log

  alias DelegatedSpend.Compliance.MemoryStore, as: ComplianceStore
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Intake
  alias DelegatedSpend.Intake.Rate
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.{MemoryStore, Signer}

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @bot_token "1234567:TEST-fake-bot-token-for-vectors"
  @router "0x0000000000000000000000000000000000000BbB"
  @token "0x0000000000000000000000000000000000000AaA"
  @user_id 777_000_111

  defmodule FailingEventStore do
    def record_event(:raise, _event), do: raise("event store down")
    def record_event(:exit, _event), do: exit(:event_store_down)
    def record_event(:throw, _event), do: throw(:event_store_down)
  end

  defp init_data(user_id \\ @user_id, token \\ @bot_token) do
    fields = %{
      "auth_date" => Integer.to_string(System.os_time(:second)),
      "query_id" => "AAF03",
      "user" => ~s({"id":#{user_id},"first_name":"A"})
    }

    dcs =
      fields
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", token)
    hash = :crypto.mac(:hmac, :sha256, secret, dcs) |> Base.encode16(case: :lower)
    URI.encode_query(Map.put(fields, "hash", hash))
  end

  defp permit_env(value) do
    %{
      "v" => "0.2.0",
      "chain_id" => 84_532,
      "token" => @token,
      "spender" => @router,
      "owner" => "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "value" => value,
      "deadline" => 4_000_000_000,
      "sig" => %{
        "v" => 27,
        "r" => "0x" <> String.duplicate("11", 32),
        "s" => "0x" <> String.duplicate("22", 32)
      }
    }
  end

  defp start_stack(rate_max \\ 100, order_ttl_s \\ 600) do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, store},
        router: @router,
        action: %{
          with_permit_name: "payWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
        },
        source_allowlist: ["market_phase"],
        order_ttl_s: order_ttl_s,
        sweep_ms: 3_600_000
      )

    ctx = %{
      bot_token: @bot_token,
      max_age_s: 900,
      user_ref_fn: fn user_id -> "ref-" <> Integer.to_string(user_id) end,
      keeper: keeper,
      pinned: %{chain_id: 84_532, token: @token, router: @router, version: "0.2.0"},
      rate: {Rate.start(60), rate_max}
    }

    %{fake: fake, signer: signer, store: store, keeper: keeper, ctx: ctx}
  end

  defp register(keeper, user_id) do
    {:ok, %{order_ref: ref}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: "ref-" <> Integer.to_string(user_id),
        amount: 25_000_000,
        action_args: [<<7::256>>, 25_000_000, <<9::256>>]
      })

    ref
  end

  defp order_params(ctx, extra) do
    Map.put(extra, "v", ctx.pinned.version)
  end

  defp future, do: System.os_time(:second) + 600

  defp audit_meta do
    %{
      ip: "203.0.113.4",
      country: "uS",
      user_agent: "wallet-test/1.0",
      session_id: "session-1",
      raw: "must-not-persist"
    }
  end

  defp with_compliance(ctx) do
    store = ComplianceStore.start()

    {Map.put(ctx, :compliance, %{geo_block: ["CU"], store: {ComplianceStore, store}}), store}
  end

  describe "compliance geofencing" do
    test "blocks every handler before version pinning or authentication" do
      ctx = %{compliance: %{geo_block: ["CU"]}}

      for handler <- [:handle_order, :handle_grant, :handle_wallet, :handle_submitted] do
        assert {451, %{"error" => "geo_blocked"}} =
                 apply(Intake, handler, [%{"country" => "US"}, %{country: "CU"}, ctx])
      end
    end

    test "blocked requests do not burn rate buckets or reach the keeper store" do
      ref = String.duplicate("ab", 32)
      user_ref = "ref-#{@user_id}"
      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, user_ref, future())

      requests = [
        {:handle_order, %{"order_ref" => ref, "token" => token, "v" => "0.2.0"}},
        {:handle_grant,
         %{"order_ref" => ref, "token" => token, "permit" => permit_env(25_000_000)}},
        {:handle_wallet,
         %{
           "bind_ref" => ref,
           "token" => token,
           "address" => "0x8ba1f109551bd432803012645ac136ddd64dba72",
           "v" => "0.2.0"
         }},
        {:handle_submitted,
         %{
           "order_ref" => ref,
           "token" => token,
           "tx_hash" => "0x" <> String.duplicate("ef", 32),
           "v" => "0.2.0"
         }}
      ]

      for {handler, params} <- requests do
        limiter = Rate.start()

        ctx = %{
          compliance: %{geo_block: ["CU"]},
          token_secret: "tsecret",
          pinned: %{chain_id: 84_532, token: @token, router: @router, version: "0.2.0"},
          rate: {limiter, 1},
          wallet_fn: fn _user_ref, _address, _bind_ref -> :ok end
        }

        assert {451, %{"error" => "geo_blocked"}} =
                 apply(Intake, handler, [params, %{country: "CU"}, ctx])

        assert Rate.allow?(limiter, user_ref, 1)
      end
    end

    test "configured two-arity handlers deny because their metadata is empty" do
      ctx = %{compliance: %{geo_block: ["CU"]}}

      for handler <- [:handle_order, :handle_grant, :handle_wallet, :handle_submitted] do
        assert {451, %{"error" => "geo_blocked"}} = apply(Intake, handler, [%{}, ctx])
      end
    end

    test "configured compliance fails closed on missing or malformed policy metadata" do
      for {compliance, meta} <- [
            {%{}, %{country: "US"}},
            {%{geo_block: "US"}, %{country: "US"}},
            {%{geo_block: []}, %{country: "US"}},
            {%{geo_block: ["CU", "XYZ"]}, %{country: "US"}},
            {%{geo_block: ["CU"]}, %{}},
            {%{geo_block: ["CU"]}, %{country: "USA"}}
          ] do
        assert {451, %{"error" => "geo_blocked"}} =
                 Intake.handle_order(%{}, meta, %{compliance: compliance})
      end

      ctx = %{compliance: %{geo_block: ["CU"]}, bot_token: @bot_token, max_age_s: 900}

      assert {401, %{"error" => "unauthorized"}} =
               Intake.handle_order(%{"country" => "CA"}, %{country: "US"}, ctx)

      assert {451, %{"error" => "geo_blocked"}} =
               Intake.handle_order(%{"country" => "US"}, %{}, ctx)
    end

    test "denial recording never changes the 451 when the event store fails" do
      for failure <- [:raise, :exit, :throw] do
        ctx = %{compliance: %{geo_block: ["CU"], store: {FailingEventStore, failure}}}

        assert {451, %{"error" => "geo_blocked"}} =
                 Intake.handle_order(%{}, %{country: "CU"}, ctx)
      end
    end

    test "metadata has no effect when compliance is absent" do
      %{ctx: ctx, keeper: keeper} = start_stack()
      ref = register(keeper, @user_id)
      params = order_params(ctx, %{"init_data" => init_data(), "order_ref" => ref})

      assert {200, body} = Intake.handle_order(params, ctx)
      assert {200, ^body} = Intake.handle_order(params, %{country: "CA"}, ctx)
    end
  end

  test "unauthenticated requests are rejected before ANY work" do
    %{ctx: ctx, store: store, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)

    for bad <- [nil, "", "garbage", init_data(@user_id, "999:WRONG")] do
      assert {401, %{"error" => "unauthorized"}} =
               Intake.handle_order(
                 order_params(ctx, %{"init_data" => bad, "order_ref" => ref}),
                 ctx
               )

      assert {401, _} =
               Intake.handle_grant(
                 %{"init_data" => bad, "order_ref" => ref, "permit" => permit_env(25_000_000)},
                 ctx
               )
    end

    # nothing consumed, nothing inflight — zero work happened
    assert MemoryStore.list_inflight(store) == []
    assert {:ok, _} = Keeper.fetch_order(keeper, ref, "ref-#{@user_id}")
  end

  test "order fetch: verified user sees own order; another VERIFIED user gets 404" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)

    assert {200, body} =
             Intake.handle_order(
               order_params(ctx, %{"init_data" => init_data(), "order_ref" => ref}),
               ctx
             )

    assert body["amount"] == 25_000_000
    assert body["order_ref"] == ref
    # the keeper's RUNTIME chain id rides on every served view — the dapp's
    # config-drift gate (stale config.json vs a moved RPC) depends on it
    assert body["chain_id"] == 84_532

    other = init_data(666_000_000)

    assert {404, _} =
             Intake.handle_order(
               order_params(ctx, %{"init_data" => other, "order_ref" => ref}),
               ctx
             )
  end

  test "order view exposes expected_owner ONLY when the order is owner-bound" do
    %{ctx: ctx, keeper: keeper} = start_stack()

    # unbound order: no expected_owner key at all
    ref = register(keeper, @user_id)

    assert {200, body} =
             Intake.handle_order(
               order_params(ctx, %{"init_data" => init_data(), "order_ref" => ref}),
               ctx
             )

    refute Map.has_key?(body, "expected_owner")

    # owner-bound order: the wallet the user must pay from is exposed so the
    # dapp can refuse a mismatched connected account before anything is signed
    bound = "0xF39FD6e51aad88F6F4ce6aB8827279cffFb92266"

    {:ok, %{order_ref: bref}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: "ref-#{@user_id}",
        amount: 25_000_000,
        action_args: [<<7::256>>, 25_000_000, <<9::256>>],
        expected_owner: bound
      })

    assert {200, body} =
             Intake.handle_order(
               order_params(ctx, %{"init_data" => init_data(), "order_ref" => bref}),
               ctx
             )

    assert body["expected_owner"] == bound
  end

  test "client-supplied user_ref is IGNORED — identity comes from initData only" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)
    other = init_data(666_000_000)

    params = %{
      "init_data" => other,
      "order_ref" => ref,
      # attacker claims the victim's ref in the payload
      "user_ref" => "ref-#{@user_id}",
      "v" => ctx.pinned.version
    }

    assert {404, _} = Intake.handle_order(params, ctx)
  end

  test "grant: pinned mismatches reject typed; version mismatch is 409" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)
    base = %{"init_data" => init_data(), "order_ref" => ref}

    assert {409, _} =
             Intake.handle_grant(
               Map.put(base, "permit", %{permit_env(25_000_000) | "v" => "0.0.9"}),
               ctx
             )

    assert {422, %{"field" => "spender"}} =
             Intake.handle_grant(
               Map.put(base, "permit", %{
                 permit_env(25_000_000)
                 | "spender" => "0x0000000000000000000000000000000000000ccc"
               }),
               ctx
             )
  end

  test "grant: malformed permit fields are typed 422 invalid responses" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)

    assert {422, %{"error" => "invalid", "field" => "value"}} =
             Intake.handle_grant(
               %{
                 "init_data" => init_data(),
                 "order_ref" => ref,
                 "permit" => Map.delete(permit_env(25_000_000), "value")
               },
               ctx
             )
  end

  test "grant happy path: strict validation → keeper → submitted" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)

    assert {200, %{"status" => "submitted", "tx" => "0x" <> _}} =
             Intake.handle_grant(
               %{
                 "init_data" => init_data(),
                 "order_ref" => ref,
                 "permit" => permit_env(25_000_000)
               },
               ctx
             )
  end

  test "grant retry after mined settlement returns mined" do
    %{ctx: ctx, keeper: keeper, fake: fake, signer: signer} = start_stack()
    ref = register(keeper, @user_id)
    params = %{"init_data" => init_data(), "order_ref" => ref, "permit" => permit_env(25_000_000)}

    assert {200, %{"status" => "submitted", "tx" => hash}} = Intake.handle_grant(params, ctx)
    FakeRpc.put(fake, :receipts, %{hash => %{"status" => "0x1"}})
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)

    assert {200, %{"status" => "mined", "tx" => ^hash}} = Intake.handle_grant(params, ctx)
  end

  test "grant retry after execution begins without a hash returns pending" do
    %{ctx: ctx, keeper: keeper, store: store, fake: fake} = start_stack()

    {:ok, %{order_ref: ref, order_id: order_id}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: "ref-#{@user_id}",
        amount: 25_000_000,
        action_args: [<<7::256>>, 25_000_000, <<9::256>>]
      })

    assert {:ok, _} = MemoryStore.begin_execution(store, order_id, "ref-#{@user_id}", order_id)

    assert {200, %{"status" => "pending"}} =
             Intake.handle_grant(
               %{
                 "init_data" => init_data(),
                 "order_ref" => ref,
                 "permit" => permit_env(25_000_000)
               },
               ctx
             )

    assert FakeRpc.sent(fake) == []
  end

  test "grant retry after consumed order with no pending status maps unknown to 404" do
    %{ctx: ctx, keeper: keeper, store: store} = start_stack()

    {:ok, %{order_ref: ref, order_id: order_id}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: "ref-#{@user_id}",
        amount: 25_000_000,
        action_args: [<<7::256>>, 25_000_000, <<9::256>>]
      })

    assert {:ok, _order} = MemoryStore.consume_order(store, order_id, "ref-#{@user_id}")

    assert {404, %{"error" => "not found"}} =
             Intake.handle_grant(
               %{
                 "init_data" => init_data(),
                 "order_ref" => ref,
                 "permit" => permit_env(25_000_000)
               },
               ctx
             )
  end

  test "grant for someone else's order: 404, nothing broadcast" do
    %{ctx: ctx, keeper: keeper, fake: fake} = start_stack()
    ref = register(keeper, @user_id)

    assert {404, _} =
             Intake.handle_grant(
               %{
                 "init_data" => init_data(666_000_000),
                 "order_ref" => ref,
                 "permit" => permit_env(25_000_000)
               },
               ctx
             )

    assert FakeRpc.sent(fake) == []
  end

  test "rate limiting is per verified user and only counts authenticated calls" do
    %{ctx: ctx, keeper: keeper} = start_stack(2)
    ref = register(keeper, @user_id)
    params = order_params(ctx, %{"init_data" => init_data(), "order_ref" => ref})

    assert {200, _} = Intake.handle_order(params, ctx)
    assert {200, _} = Intake.handle_order(params, ctx)
    assert {429, _} = Intake.handle_order(params, ctx)

    # a DIFFERENT verified user has their own bucket
    other = order_params(ctx, %{"init_data" => init_data(666_000_000), "order_ref" => ref})
    assert {404, _} = Intake.handle_order(other, ctx)
  end

  test "unauthenticated requests do NOT consume the rate bucket" do
    # max 1/window: three 401s must leave the single slot untouched for the
    # first AUTHENTICATED call — the limiter only counts verified callers.
    %{ctx: ctx, keeper: keeper} = start_stack(1)
    ref = register(keeper, @user_id)

    for _ <- 1..3 do
      assert {401, _} =
               Intake.handle_order(
                 order_params(ctx, %{"init_data" => "garbage", "order_ref" => ref}),
                 ctx
               )
    end

    assert {200, _} =
             Intake.handle_order(
               order_params(ctx, %{"init_data" => init_data(), "order_ref" => ref}),
               ctx
             )
  end

  describe "token auth + version pin" do
    test "a valid ref-scoped token authenticates handle_order without init_data" do
      %{ctx: ctx, keeper: keeper} = start_stack()
      ref = register(keeper, @user_id)
      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())
      ctx = Map.put(ctx, :token_secret, "tsecret")

      assert {200, %{"order_ref" => ^ref}} =
               Intake.handle_order(
                 %{"order_ref" => ref, "token" => token, "v" => ctx.pinned.version},
                 ctx
               )
    end

    test "a token for ref A cannot fetch ref B; expired token is 401" do
      %{ctx: ctx, keeper: keeper} = start_stack()
      ref_a = register(keeper, @user_id)
      ref_b = register(keeper, @user_id)
      ctx = Map.put(ctx, :token_secret, "tsecret")
      token_a = DelegatedSpend.Intake.Token.mint("tsecret", ref_a, "ref-#{@user_id}", future())

      assert {401, _} =
               Intake.handle_order(
                 %{"order_ref" => ref_b, "token" => token_a, "v" => ctx.pinned.version},
                 ctx
               )

      stale = DelegatedSpend.Intake.Token.mint("tsecret", ref_a, "ref-#{@user_id}", 1)

      assert {401, _} =
               Intake.handle_order(
                 %{"order_ref" => ref_a, "token" => stale, "v" => ctx.pinned.version},
                 ctx
               )
    end

    test "token param without ctx.token_secret falls through to initData auth and 401s" do
      %{ctx: ctx, keeper: keeper} = start_stack()
      ref = register(keeper, @user_id)
      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())

      assert {401, _} =
               Intake.handle_order(
                 %{"order_ref" => ref, "token" => token, "v" => ctx.pinned.version},
                 ctx
               )
    end

    test "missing or wrong v is a 409 stale-build rejection before auth work" do
      %{ctx: ctx, keeper: keeper} = start_stack()
      ref = register(keeper, @user_id)
      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())
      ctx = Map.put(ctx, :token_secret, "tsecret")

      assert {409, %{"error" => "version mismatch"}} =
               Intake.handle_order(%{"order_ref" => ref, "token" => token}, ctx)

      assert {409, %{"error" => "version mismatch"}} =
               Intake.handle_order(%{"order_ref" => ref, "token" => token, "v" => "0.0.1"}, ctx)
    end

    test "handle_grant accepts token auth in place of init_data" do
      %{ctx: ctx, keeper: keeper} = start_stack()
      ref = register(keeper, @user_id)
      ctx = Map.put(ctx, :token_secret, "tsecret")
      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())

      assert {200, %{"status" => "submitted"}} =
               Intake.handle_grant(
                 %{"token" => token, "order_ref" => ref, "permit" => permit_env(25_000_000)},
                 ctx
               )
    end
  end

  describe "compliance audit events" do
    test "records wallet_bound only after a successful bind with normalized metadata" do
      %{ctx: ctx, keeper: keeper} = start_stack()
      me = self()

      ctx =
        ctx
        |> Map.put(:token_secret, "tsecret")
        |> Map.put(:wallet_fn, fn user_ref, address, bind_ref ->
          send(me, {:bound, user_ref, address, bind_ref})
          :ok
        end)

      {ctx, store} = with_compliance(ctx)

      {:ok, %{order_ref: bind_ref}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "bind"
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", bind_ref, "ref-#{@user_id}", future())
      before = System.os_time(:second)

      assert {200, %{"status" => "bound", "address" => wallet}} =
               Intake.handle_wallet(
                 %{
                   "bind_ref" => bind_ref,
                   "token" => token,
                   "address" => "0x8ba1f109551bd432803012645ac136ddd64dba72",
                   "v" => ctx.pinned.version
                 },
                 audit_meta(),
                 ctx
               )

      after_call = System.os_time(:second)

      assert [event] = ComplianceStore.events_for(store, "ref-#{@user_id}")
      assert event.kind == "wallet_bound"
      assert event.wallet == wallet
      assert event.order_ref == bind_ref
      assert event.user_ref == "ref-#{@user_id}"
      assert event.at in before..after_call

      assert event.meta == %{
               ip: "203.0.113.4",
               country: "US",
               user_agent: "wallet-test/1.0",
               session_id: "session-1"
             }
    end

    test "records grant_submitted with the validated permit owner" do
      %{ctx: base_ctx, keeper: keeper} = start_stack()
      {ctx, store} = with_compliance(base_ctx)
      ref = register(keeper, @user_id)
      permit = permit_env(25_000_000)

      assert {200, %{"status" => "submitted"}} =
               Intake.handle_grant(
                 %{"init_data" => init_data(), "order_ref" => ref, "permit" => permit},
                 audit_meta(),
                 ctx
               )

      assert [event] = ComplianceStore.events_for(store, "ref-#{@user_id}")

      assert %{
               kind: "grant_submitted",
               wallet: wallet,
               order_ref: ^ref,
               user_ref: "ref-777000111",
               meta: %{country: "US", ip: "203.0.113.4"}
             } = event

      assert wallet == permit["owner"]
      assert is_integer(event.at)
    end

    test "records tx_submitted with expected owner and never records order fetches" do
      %{ctx: base_ctx, keeper: keeper} = start_stack()
      base_ctx = Map.put(base_ctx, :token_secret, "tsecret")
      {ctx, store} = with_compliance(base_ctx)
      owner = "0xF39FD6e51aad88F6F4ce6aB8827279cffFb92266"

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0},
          expected_owner: owner
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())
      params = %{"order_ref" => ref, "token" => token, "v" => ctx.pinned.version}

      assert {200, _body} = Intake.handle_order(params, audit_meta(), ctx)
      assert ComplianceStore.events_for(store, "ref-#{@user_id}") == []

      assert {200, %{"status" => "noted"}} =
               Intake.handle_submitted(
                 Map.put(params, "tx_hash", "0x" <> String.duplicate("ef", 32)),
                 audit_meta(),
                 ctx
               )

      assert [%{kind: "tx_submitted", wallet: ^owner, order_ref: ^ref, meta: %{country: "US"}}] =
               ComplianceStore.events_for(store, "ref-#{@user_id}")
    end

    test "tx_submitted records nil when the order has no expected owner" do
      %{ctx: base_ctx, keeper: keeper} = start_stack()
      base_ctx = Map.put(base_ctx, :token_secret, "tsecret")
      {ctx, store} = with_compliance(base_ctx)

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0}
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())

      assert {200, %{"status" => "noted"}} =
               Intake.handle_submitted(
                 %{
                   "order_ref" => ref,
                   "token" => token,
                   "tx_hash" => "0x" <> String.duplicate("ef", 32),
                   "v" => ctx.pinned.version
                 },
                 audit_meta(),
                 ctx
               )

      assert [%{kind: "tx_submitted", wallet: nil}] =
               ComplianceStore.events_for(store, "ref-#{@user_id}")
    end

    test "failed wallet, grant, and submitted requests do not record events" do
      %{ctx: base_ctx, keeper: keeper} = start_stack()
      base_ctx = Map.put(base_ctx, :token_secret, "tsecret")
      {ctx, store} = with_compliance(base_ctx)
      ref = register(keeper, @user_id)
      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())

      assert {409, _} =
               Intake.handle_grant(
                 %{"token" => token, "order_ref" => ref, "permit" => %{}},
                 audit_meta(),
                 ctx
               )

      assert {503, _} =
               Intake.handle_wallet(
                 %{
                   "token" => token,
                   "bind_ref" => ref,
                   "address" => "bad",
                   "v" => ctx.pinned.version
                 },
                 audit_meta(),
                 ctx
               )

      assert {422, _} =
               Intake.handle_submitted(
                 %{
                   "token" => token,
                   "order_ref" => ref,
                   "tx_hash" => "bad",
                   "v" => ctx.pinned.version
                 },
                 audit_meta(),
                 ctx
               )

      assert ComplianceStore.events_for(store, "ref-#{@user_id}") == []
    end

    test "absent, missing, raising, exiting, and throwing event stores cannot change success" do
      %{ctx: base_ctx, keeper: keeper} = start_stack()
      base_ctx = Map.put(base_ctx, :token_secret, "tsecret")

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0}
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())

      params = %{
        "order_ref" => ref,
        "token" => token,
        "tx_hash" => "0x" <> String.duplicate("ef", 32),
        "v" => base_ctx.pinned.version
      }

      compliance_configs = [
        :absent,
        %{geo_block: ["CU"]},
        %{geo_block: ["CU"], store: :invalid},
        %{geo_block: ["CU"], store: {DelegatedSpend.MissingComplianceStore, :missing}},
        %{geo_block: ["CU"], store: {FailingEventStore, :raise}},
        %{geo_block: ["CU"], store: {FailingEventStore, :exit}},
        %{geo_block: ["CU"], store: {FailingEventStore, :throw}}
      ]

      for compliance <- compliance_configs do
        ctx =
          if compliance == :absent,
            do: Map.delete(base_ctx, :compliance),
            else: Map.put(base_ctx, :compliance, compliance)

        assert {200, %{"status" => "noted"}} =
                 Intake.handle_submitted(params, audit_meta(), ctx)
      end
    end
  end

  describe "wallet bind + user_tx views" do
    setup do
      %{ctx: ctx} = c = start_stack()
      me = self()

      ctx =
        ctx
        |> Map.put(:token_secret, "tsecret")
        |> Map.put(:wallet_fn, fn user_ref, addr, bind_ref ->
          send(me, {:bound, user_ref, addr, bind_ref})
          :ok
        end)
        |> Map.put(:wallet_view_fn, fn _user_ref ->
          "0xAbCd000000000000000000000000000000000001"
        end)
        |> Map.put(:submitted_fn, fn order_id, tx ->
          send(me, {:submitted, order_id, tx})
          :ok
        end)

      {:ok, Map.put(c, :ctx, ctx)}
    end

    test "bind fetch returns kind+current_wallet; POST /wallet binds via wallet_fn single-use", %{
      ctx: ctx
    } do
      {:ok, %{order_ref: bind_ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "bind"
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", bind_ref, "ref-#{@user_id}", future())
      v = ctx.pinned.version

      assert {200, body} =
               Intake.handle_order(%{"order_ref" => bind_ref, "token" => token, "v" => v}, ctx)

      assert body["kind"] == "bind"
      assert body["current_wallet"] == "0xAbCd000000000000000000000000000000000001"
      # bind views carry the runtime chain id too — bind pages consume config
      assert body["chain_id"] == 84_532

      addr = "0x8ba1f109551bd432803012645ac136ddd64dba72"

      assert {200, %{"status" => "bound", "address" => bound}} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref, "token" => token, "address" => addr, "v" => v},
                 ctx
               )

      assert String.downcase(bound) == addr
      user_ref = "ref-#{@user_id}"
      assert_received {:bound, ^user_ref, ^bound, ^bind_ref}

      assert {410, _} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref, "token" => token, "address" => addr, "v" => v},
                 ctx
               )
    end

    test "bad address is 422; wrong-kind ref is 422; missing wallet_fn is 503", %{ctx: ctx} do
      v = ctx.pinned.version

      {:ok, %{order_ref: bind_ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "bind"
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", bind_ref, "ref-#{@user_id}", future())

      assert {422, %{"field" => "address"}} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref, "token" => token, "address" => "nonsense", "v" => v},
                 ctx
               )

      assert {422, %{"field" => "address"}} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref, "token" => token, "address" => 42, "v" => v},
                 ctx
               )

      assert {422, %{"field" => "address"}} =
               Intake.handle_wallet(
                 %{
                   "bind_ref" => bind_ref,
                   "token" => token,
                   "address" => "0x0000000000000000000000000000000000000000",
                   "v" => v
                 },
                 ctx
               )

      permit_ref = register(ctx.keeper, @user_id)

      ptoken =
        DelegatedSpend.Intake.Token.mint("tsecret", permit_ref, "ref-#{@user_id}", future())

      assert {422, %{"field" => "kind"}} =
               Intake.handle_wallet(
                 %{
                   "bind_ref" => permit_ref,
                   "token" => ptoken,
                   "address" => "0x8ba1f109551bd432803012645ac136ddd64dba72",
                   "v" => v
                 },
                 ctx
               )

      assert {503, %{"error" => "unavailable"}} =
               Intake.handle_wallet(
                 %{
                   "bind_ref" => bind_ref,
                   "token" => token,
                   "address" => "0x8ba1f109551bd432803012645ac136ddd64dba72",
                   "v" => v
                 },
                 Map.delete(ctx, :wallet_fn)
               )

      assert {503, %{"error" => "unavailable"}} =
               Intake.handle_wallet(
                 %{
                   "bind_ref" => bind_ref,
                   "token" => token,
                   "address" => "0x8ba1f109551bd432803012645ac136ddd64dba72",
                   "v" => v
                 },
                 Map.put(ctx, :wallet_fn, fn _user_ref, _address -> :ok end)
               )
    end

    test "bind fetch can omit current_wallet and wallet_fn rejection is surfaced", %{ctx: ctx} do
      v = ctx.pinned.version

      {:ok, %{order_ref: bind_ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "bind"
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", bind_ref, "ref-#{@user_id}", future())
      ctx_no_view = Map.delete(ctx, :wallet_view_fn)

      assert {200, %{"current_wallet" => nil}} =
               Intake.handle_order(
                 %{"order_ref" => bind_ref, "token" => token, "v" => v},
                 ctx_no_view
               )

      reject_ctx =
        Map.put(ctx, :wallet_fn, fn _user_ref, _address, _bind_ref -> {:error, :nope} end)

      assert {422, %{"error" => "bind rejected"}} =
               Intake.handle_wallet(
                 %{
                   "bind_ref" => bind_ref,
                   "token" => token,
                   "address" => "0x8ba1f109551bd432803012645ac136ddd64dba72",
                   "v" => v
                 },
                 reject_ctx
               )
    end

    test "user_tx fetch carries tx + display; submitted-report is noted", %{ctx: ctx} do
      v = ctx.pinned.version

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef", value: 0},
          display: %{summary_lines: ["Sell YES"]}
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())

      assert {200, body} =
               Intake.handle_order(%{"order_ref" => ref, "token" => token, "v" => v}, ctx)

      assert body["kind"] == "user_tx"
      assert body["tx"]["data"] == "0xdeadbeef"
      assert body["display"]["summary_lines"] == ["Sell YES"]

      tx_hash = "0x" <> String.duplicate("ef", 32)

      assert {200, %{"status" => "noted"}} =
               Intake.handle_submitted(
                 %{"order_ref" => ref, "token" => token, "tx_hash" => tx_hash, "v" => v},
                 ctx
               )

      assert_received {:submitted, _order_id, ^tx_hash}

      assert {422, %{"field" => "tx_hash"}} =
               Intake.handle_submitted(
                 %{"order_ref" => ref, "token" => token, "tx_hash" => "zzz", "v" => v},
                 ctx
               )

      bad_hex = "0x" <> String.duplicate("zz", 32)

      assert {422, %{"field" => "tx_hash"}} =
               Intake.handle_submitted(
                 %{"order_ref" => ref, "token" => token, "tx_hash" => bad_hex, "v" => v},
                 ctx
               )
    end

    test "submitted-report without callback is noted and expired or missing orders are typed",
         %{ctx: ctx, store: store} do
      v = ctx.pinned.version

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef", value: 0}
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())
      tx_hash = "0x" <> String.duplicate("ef", 32)

      assert {200, %{"status" => "noted"}} =
               Intake.handle_submitted(
                 %{"order_ref" => ref, "token" => token, "tx_hash" => tx_hash, "v" => v},
                 Map.delete(ctx, :submitted_fn)
               )

      assert {404, %{"error" => "not found"}} =
               Intake.handle_submitted(
                 %{
                   "order_ref" => String.duplicate("cd", 32),
                   "token" =>
                     DelegatedSpend.Intake.Token.mint(
                       "tsecret",
                       String.duplicate("cd", 32),
                       "ref-#{@user_id}",
                       future()
                     ),
                   "tx_hash" => tx_hash,
                   "v" => v
                 },
                 ctx
               )

      # seed an already-expired order straight into the store — no sleeping
      expired_ref = String.duplicate("ee", 32)

      :ok =
        MemoryStore.put_order(store, %{
          order_id: "0x" <> String.duplicate("aa", 32),
          order_ref: expired_ref,
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0},
          display: %{},
          expected_owner: nil,
          expires_at: System.os_time(:second) - 5
        })

      etoken =
        DelegatedSpend.Intake.Token.mint("tsecret", expired_ref, "ref-#{@user_id}", future())

      assert {410, %{"error" => "expired"}} =
               Intake.handle_submitted(
                 %{"order_ref" => expired_ref, "token" => etoken, "tx_hash" => tx_hash, "v" => v},
                 ctx
               )
    end

    test "expired user_tx order fetch is 410 and does not expose tx", %{ctx: ctx, store: store} do
      v = ctx.pinned.version
      expired_ref = String.duplicate("ab", 32)

      :ok =
        MemoryStore.put_order(store, %{
          order_id: "0x" <> String.duplicate("bb", 32),
          order_ref: expired_ref,
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0},
          display: %{},
          expected_owner: nil,
          expires_at: System.os_time(:second) - 5
        })

      token =
        DelegatedSpend.Intake.Token.mint("tsecret", expired_ref, "ref-#{@user_id}", future())

      assert {410, %{"error" => "expired"}} =
               Intake.handle_order(%{"order_ref" => expired_ref, "token" => token, "v" => v}, ctx)
    end

    test "submitted-report remains best-effort when callback raises", %{ctx: ctx} do
      v = ctx.pinned.version

      {:ok, %{order_ref: ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef", value: 0}
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", ref, "ref-#{@user_id}", future())
      tx_hash = "0x" <> String.duplicate("ef", 32)
      ctx = Map.put(ctx, :submitted_fn, fn _order_id, _tx -> raise "scanner offline" end)

      assert {200, %{"status" => "noted"}} =
               Intake.handle_submitted(
                 %{"order_ref" => ref, "token" => token, "tx_hash" => tx_hash, "v" => v},
                 ctx
               )

      exit_ctx = Map.put(ctx, :submitted_fn, fn _order_id, _tx -> exit(:watcher_down) end)

      assert {200, %{"status" => "noted"}} =
               Intake.handle_submitted(
                 %{"order_ref" => ref, "token" => token, "tx_hash" => tx_hash, "v" => v},
                 exit_ctx
               )
    end

    test "unauthenticated /wallet and /orders/submitted are 401 before ANY work", %{ctx: ctx} do
      v = ctx.pinned.version
      addr = "0x8ba1f109551bd432803012645ac136ddd64dba72"
      tx_hash = "0x" <> String.duplicate("ef", 32)

      {:ok, %{order_ref: bind_ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "bind"
        })

      {:ok, %{order_ref: tx_ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "user_tx",
          tx: %{to: "0x" <> String.duplicate("11", 20), data: "0x", value: 0}
        })

      # a token minted for ANOTHER ref must not open these
      wrong =
        DelegatedSpend.Intake.Token.mint(
          "tsecret",
          String.duplicate("cd", 32),
          "ref-#{@user_id}",
          future()
        )

      for bad <- [nil, "", "garbage", wrong] do
        assert {401, %{"error" => "unauthorized"}} =
                 Intake.handle_wallet(
                   %{"bind_ref" => bind_ref, "token" => bad, "address" => addr, "v" => v},
                   ctx
                 )

        assert {401, %{"error" => "unauthorized"}} =
                 Intake.handle_submitted(
                   %{"order_ref" => tx_ref, "token" => bad, "tx_hash" => tx_hash, "v" => v},
                   ctx
                 )
      end

      refute_received {:bound, _, _, _}
      refute_received {:submitted, _, _}

      # the failed attempts did NOT burn the bind order: a real bind still lands
      token = DelegatedSpend.Intake.Token.mint("tsecret", bind_ref, "ref-#{@user_id}", future())

      assert {200, %{"status" => "bound"}} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref, "token" => token, "address" => addr, "v" => v},
                 ctx
               )
    end

    test "submitted-report against a non-user_tx order is 422 and never reaches submitted_fn", %{
      ctx: ctx
    } do
      v = ctx.pinned.version
      permit_ref = register(ctx.keeper, @user_id)
      token = DelegatedSpend.Intake.Token.mint("tsecret", permit_ref, "ref-#{@user_id}", future())
      tx_hash = "0x" <> String.duplicate("ef", 32)

      assert {422, %{"error" => "invalid", "field" => "kind"}} =
               Intake.handle_submitted(
                 %{"order_ref" => permit_ref, "token" => token, "tx_hash" => tx_hash, "v" => v},
                 ctx
               )

      refute_received {:submitted, _, _}
    end

    test "crashing wallet_fn is a 422 bind rejection and still burns the single-use ref", %{
      ctx: ctx
    } do
      v = ctx.pinned.version
      addr = "0x8ba1f109551bd432803012645ac136ddd64dba72"

      {:ok, %{order_ref: bind_ref}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "bind"
        })

      token = DelegatedSpend.Intake.Token.mint("tsecret", bind_ref, "ref-#{@user_id}", future())

      crash_ctx =
        Map.put(ctx, :wallet_fn, fn _user_ref, _address, _bind_ref -> raise "db down" end)

      assert {422, %{"error" => "bind rejected"}} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref, "token" => token, "address" => addr, "v" => v},
                 crash_ctx
               )

      # a dead persistence GenServer EXITS rather than raises — same contract
      {:ok, %{order_ref: bind_ref2}} =
        Keeper.register_order(ctx.keeper, "market_phase", %{
          user_ref: "ref-#{@user_id}",
          amount: 0,
          action_args: [],
          kind: "bind"
        })

      token2 = DelegatedSpend.Intake.Token.mint("tsecret", bind_ref2, "ref-#{@user_id}", future())
      exit_ctx = Map.put(ctx, :wallet_fn, fn _user_ref, _address, _bind_ref -> exit(:db_down) end)

      assert {422, %{"error" => "bind rejected"}} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref2, "token" => token2, "address" => addr, "v" => v},
                 exit_ctx
               )

      # fail-closed single-use: the ref is consumed even though the bind failed
      assert {410, _} =
               Intake.handle_wallet(
                 %{"bind_ref" => bind_ref, "token" => token, "address" => addr, "v" => v},
                 ctx
               )
    end
  end

  test "handle_grant is rate limited too (429 after the bucket is consumed)" do
    %{ctx: ctx, keeper: keeper} = start_stack(1)
    ref = register(keeper, @user_id)
    params = %{"init_data" => init_data(), "order_ref" => ref, "permit" => permit_env(25_000_000)}

    assert {200, _} = Intake.handle_grant(params, ctx)
    assert {429, %{"error" => "rate limited"}} = Intake.handle_grant(params, ctx)
  end

  test "Rate.start_link with :name — supervision-friendly, usable by name in ctx" do
    pid = Rate.start()
    assert Rate.allow?(pid, "default", 1)
    refute Rate.allow?(pid, "default", 1)

    {:ok, pid} = Rate.start_link(60, name: :spend_rate_named_test)
    assert Process.whereis(:spend_rate_named_test) == pid
    assert Rate.allow?(:spend_rate_named_test, "u", 1)
    refute Rate.allow?(:spend_rate_named_test, "u", 1)
  end

  test "Rate windows roll over — an exhausted bucket refills in the next fixed window" do
    pid = Rate.start(60)

    assert Rate.allow?(pid, "u", 1, 100)
    # same window (div 60): still exhausted at its last second
    refute Rate.allow?(pid, "u", 1, 119)
    # next window refills; the one after does too
    assert Rate.allow?(pid, "u", 1, 120)
    refute Rate.allow?(pid, "u", 1, 121)
    assert Rate.allow?(pid, "u", 1, 180)
  end

  test "expired order surfaces as the typed 422 failure contract on handle_grant" do
    # order_ttl_s: 0 → the order expires immediately; the keeper's {:failed,
    # :expired} must map to the documented {422, status: failed, reason: expired}.
    %{ctx: ctx, keeper: keeper} = start_stack(100, 0)
    ref = register(keeper, @user_id)

    Process.sleep(1100)

    assert {422, %{"status" => "failed", "reason" => "expired"}} =
             Intake.handle_grant(
               %{
                 "init_data" => init_data(),
                 "order_ref" => ref,
                 "permit" => permit_env(25_000_000)
               },
               ctx
             )
  end
end
