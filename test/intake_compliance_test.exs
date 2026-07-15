defmodule DelegatedSpend.IntakeComplianceTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias DelegatedSpend.Compliance.MemoryStore, as: ComplianceStore
  alias DelegatedSpend.Compliance.Terms
  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Intake
  alias DelegatedSpend.Intake.{Rate, Token}
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.{MemoryStore, Signer}

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @other_private_key <<2::256>>
  @bot_token "1234567:TEST-fake-bot-token-for-vectors"
  @router "0x0000000000000000000000000000000000000BbB"
  @token "0x0000000000000000000000000000000000000AaA"
  @user_ref "ref-777000111"
  @other_user_ref "ref-666000000"
  @terms_hash "0x" <> String.duplicate("11", 32)
  @old_terms_hash "0x" <> String.duplicate("22", 32)
  @terms %{hash: @terms_hash, url: "https://example.test/terms-v2"}
  @terms_required {428,
                   %{
                     "error" => "terms_required",
                     "terms" => %{
                       "v_hash" => @terms_hash,
                       "url" => "https://example.test/terms-v2"
                     }
                   }}

  defmodule MissingAcceptanceStore do
  end

  defmodule FailingAcceptanceStore do
    def get_acceptance(:raise, _user_ref, _v_hash), do: raise("store down")
    def get_acceptance(:exit, _user_ref, _v_hash), do: exit(:store_down)
    def get_acceptance(:throw, _user_ref, _v_hash), do: throw(:store_down)

    def record_acceptance(:non_ok, _acceptance), do: :error
    def record_acceptance(:raise, _acceptance), do: raise("store down")
    def record_acceptance(:exit, _acceptance), do: exit(:store_down)
    def record_acceptance(:throw, _acceptance), do: throw(:store_down)
  end

  setup do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    keeper_store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, keeper_store},
        router: @router,
        action: %{
          with_permit_name: "payWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
        },
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        sweep_ms: 3_600_000
      )

    test_pid = self()

    ctx = %{
      bot_token: @bot_token,
      max_age_s: 900,
      user_ref_fn: fn user_id -> "ref-" <> Integer.to_string(user_id) end,
      keeper: keeper,
      pinned: %{chain_id: 84_532, token: @token, router: @router, version: "0.2.0"},
      rate: {Rate.start(60), 100},
      token_secret: "tsecret",
      wallet_fn: fn user_ref, address, bind_ref ->
        send(test_pid, {:bound, user_ref, address, bind_ref})
        :ok
      end
    }

    compliance_store = ComplianceStore.start()

    {:ok,
     ctx: with_terms(ctx, compliance_store),
     base_ctx: ctx,
     compliance_store: compliance_store,
     fake: fake,
     keeper: keeper,
     keeper_store: keeper_store}
  end

  test "valid ref-scoped token persists only normalized acceptance evidence", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    envelope = signed_acceptance(ctx)

    meta = %{
      ip: "203.0.113.4",
      country: "uS",
      user_agent: "wallet-test/1.0",
      session_id: "session-1",
      raw: "must-not-persist"
    }

    before = System.os_time(:second)

    assert {200, %{"status" => "accepted", "v_hash" => @terms_hash}} =
             Intake.handle_terms(terms_params(ctx, ref, envelope), meta, ctx)

    after_request = System.os_time(:second)
    persisted = ComplianceStore.get_acceptance(store, @user_ref, @terms_hash)

    assert persisted == %{
             user_ref: @user_ref,
             v_hash: @terms_hash,
             account: envelope["account"],
             sig: %{
               v: envelope["sig"]["v"],
               r: envelope["sig"]["r"],
               s: envelope["sig"]["s"]
             },
             issued_at: envelope["issued_at"],
             accepted_at: persisted.accepted_at,
             meta: %{
               ip: "203.0.113.4",
               country: "US",
               user_agent: "wallet-test/1.0",
               session_id: "session-1"
             }
           }

    assert persisted.accepted_at in before..after_request
    refute Map.has_key?(persisted, :ref)
    refute Map.has_key?(persisted, :token)
    refute Map.has_key?(persisted, :init_data)
    refute persisted.user_ref == 777_000_111
    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "endpoint acceptance satisfies the current terms order view", %{
    ctx: ctx,
    keeper: keeper
  } do
    ref = register_order(keeper)
    order = order_params(ctx, ref)

    assert {200, %{"terms" => %{"required" => true}}} =
             Intake.handle_order(order, %{country: "US"}, ctx)

    assert {200, %{"status" => "accepted"}} =
             Intake.handle_terms(
               terms_params(ctx, ref, signed_acceptance(ctx)),
               %{country: "US"},
               ctx
             )

    assert {200, %{"terms" => %{"required" => false}}} =
             Intake.handle_order(order, %{country: "US"}, ctx)
  end

  test "valid acceptance replay is 200 and preserves first evidence", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    first = signed_acceptance(ctx)

    assert {200, %{"status" => "accepted", "v_hash" => @terms_hash}} =
             Intake.handle_terms(
               terms_params(ctx, ref, first),
               %{country: "US", session_id: "first"},
               ctx
             )

    persisted = ComplianceStore.get_acceptance(store, @user_ref, @terms_hash)
    replay = signed_acceptance(ctx, %{"issued_at" => first["issued_at"] + 1})

    assert {200, %{"status" => "accepted", "v_hash" => @terms_hash}} =
             Intake.handle_terms(
               terms_params(ctx, ref, replay),
               %{country: "US", session_id: "second"},
               ctx
             )

    assert ComplianceStore.get_acceptance(store, @user_ref, @terms_hash) == persisted
  end

  test "mixed-case configured hash is canonical across responses, persistence, and lookups", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    canonical_hash = Terms.hash_terms("mixed-case configured terms")
    assert canonical_hash =~ ~r/[a-f]/
    mixed_hash = "0x" <> (canonical_hash |> String.slice(2..-1//1) |> String.upcase())
    ctx = put_in(ctx, [:compliance, :terms, :hash], mixed_hash)
    ref = register_order(keeper)
    order = order_params(ctx, ref)
    terms_url = @terms.url

    assert {200, %{"terms" => %{"required" => true, "v_hash" => ^canonical_hash}}} =
             Intake.handle_order(order, %{country: "US"}, ctx)

    stale = signed_acceptance(ctx, %{"v_hash" => @old_terms_hash})

    assert {409,
            %{
              "error" => "terms_stale",
              "v_hash" => ^canonical_hash,
              "terms" => %{"v_hash" => ^canonical_hash, "url" => ^terms_url}
            }} = Intake.handle_terms(terms_params(ctx, ref, stale), %{country: "US"}, ctx)

    current = signed_acceptance(ctx, %{"v_hash" => canonical_hash})

    assert {200, %{"status" => "accepted", "v_hash" => ^canonical_hash}} =
             Intake.handle_terms(terms_params(ctx, ref, current), %{country: "US"}, ctx)

    assert %{v_hash: ^canonical_hash} =
             ComplianceStore.get_acceptance(store, @user_ref, canonical_hash)

    assert ComplianceStore.get_acceptance(store, @user_ref, mixed_hash) == nil

    assert {200, %{"terms" => %{"required" => false, "v_hash" => ^canonical_hash}}} =
             Intake.handle_order(order, %{country: "US"}, ctx)
  end

  test "token authentication is bound to the request ref", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)

    params =
      terms_params(ctx, ref, signed_acceptance(ctx))
      |> Map.put("token", token("wrong-ref"))

    assert {401, %{"error" => "unauthorized"}} =
             Intake.handle_terms(params, %{country: "US"}, ctx)

    assert ComplianceStore.get_acceptance(store, @user_ref, @terms_hash) == nil
    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "verified initData authenticates terms acceptance", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)

    params =
      terms_params(ctx, ref, signed_acceptance(ctx))
      |> Map.delete("token")
      |> Map.put("init_data", init_data())

    assert {200, %{"status" => "accepted", "v_hash" => @terms_hash}} =
             Intake.handle_terms(params, %{country: "US"}, ctx)

    assert %{user_ref: @user_ref} =
             ComplianceStore.get_acceptance(store, @user_ref, @terms_hash)
  end

  test "terms validation maps stale, pin, field, signature, and ref failures", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    valid = signed_acceptance(ctx)
    base = terms_params(ctx, ref, valid)

    stale = signed_acceptance(ctx, %{"v_hash" => @old_terms_hash})
    wrong_signer = signed_acceptance(ctx, %{}, @other_private_key)

    cases = [
      {Map.delete(base, "ref"), {422, %{"error" => "invalid", "field" => "ref"}}},
      {Map.put(base, "ref", ""), {422, %{"error" => "invalid", "field" => "ref"}}},
      {Map.put(base, "ref", 123), {422, %{"error" => "invalid", "field" => "ref"}}},
      {Map.put(base, "v", "0.1.0"), {409, %{"error" => "version mismatch"}}},
      {put_in(base, ["acceptance", "v"], "0.1.0"), {409, %{"error" => "version mismatch"}}},
      {put_in(base, ["acceptance", "chain_id"], ctx.pinned.chain_id + 1),
       {422, %{"error" => "invalid", "field" => "chain_id"}}},
      {Map.put(base, "acceptance", nil), {422, %{"error" => "invalid", "field" => "envelope"}}},
      {put_in(base, ["acceptance", "issued_at"], valid["issued_at"] - 901),
       {422, %{"error" => "invalid", "field" => "issued_at"}}},
      {Map.put(base, "acceptance", stale),
       {409,
        %{
          "error" => "terms_stale",
          "v_hash" => @terms_hash,
          "terms" => %{"v_hash" => @terms_hash, "url" => @terms.url}
        }}},
      {put_in(base, ["acceptance", "sig", "r"], "0x" <> String.duplicate("00", 32)),
       {422, %{"error" => "invalid", "field" => "sig"}}},
      {put_in(base, ["acceptance", "issued_at"], valid["issued_at"] + 1),
       {422, %{"error" => "invalid", "field" => "sig"}}},
      {Map.put(base, "acceptance", wrong_signer),
       {422, %{"error" => "invalid", "field" => "sig"}}}
    ]

    for {params, expected} <- cases do
      assert Intake.handle_terms(params, %{country: "US"}, ctx) == expected
    end

    assert ComplianceStore.get_acceptance(store, @user_ref, @terms_hash) == nil
    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "missing or malformed acceptance configuration returns unavailable", %{
    base_ctx: base_ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    params = terms_params(base_ctx, ref, signed_acceptance(base_ctx))

    invalid_compliance = [
      nil,
      %{geo_allow: ["US"]},
      %{geo_allow: ["US"], terms: nil, store: {ComplianceStore, store}},
      %{geo_allow: ["US"], terms: %{}, store: {ComplianceStore, store}},
      %{geo_allow: ["US"], terms: %{hash: @terms_hash}, store: {ComplianceStore, store}},
      %{
        geo_allow: ["US"],
        terms: %{hash: "0x1234", url: @terms.url},
        store: {ComplianceStore, store}
      },
      %{
        geo_allow: ["US"],
        terms: %{hash: "0x" <> String.duplicate("zz", 32), url: @terms.url},
        store: {ComplianceStore, store}
      },
      %{geo_allow: ["US"], terms: %{hash: @terms_hash, url: ""}, store: {ComplianceStore, store}},
      %{geo_allow: ["US"], terms: @terms},
      %{geo_allow: ["US"], terms: @terms, store: :invalid},
      %{geo_allow: ["US"], terms: @terms, store: {"not-a-module", :ignored}},
      %{geo_allow: ["US"], terms: @terms, store: {MissingAcceptanceStore, :ignored}}
    ]

    for compliance <- invalid_compliance do
      ctx =
        if compliance,
          do: Map.put(base_ctx, :compliance, compliance),
          else: Map.delete(base_ctx, :compliance)

      assert {503, %{"error" => "unavailable"}} =
               Intake.handle_terms(params, %{country: "US"}, ctx)
    end

    assert ComplianceStore.get_acceptance(store, @user_ref, @terms_hash) == nil
  end

  test "acceptance persistence is fail-closed for every unsuccessful callback", %{
    base_ctx: base_ctx,
    keeper: keeper
  } do
    ref = register_order(keeper)
    params = terms_params(base_ctx, ref, signed_acceptance(base_ctx))

    for failure <- [:non_ok, :raise, :exit, :throw] do
      ctx =
        Map.put(base_ctx, :compliance, %{
          geo_allow: ["US"],
          terms: @terms,
          store: {FailingAcceptanceStore, failure}
        })

      assert {503, %{"error" => "unavailable"}} =
               Intake.handle_terms(params, %{country: "US"}, ctx)
    end
  end

  test "rate limiting runs before terms configuration and failed requests write nothing", %{
    base_ctx: base_ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    params = terms_params(base_ctx, ref, signed_acceptance(base_ctx))
    limiter = Rate.start(60)

    invalid_ctx =
      base_ctx
      |> Map.put(:rate, {limiter, 1})
      |> Map.put(:compliance, %{geo_allow: ["US"], terms: nil, store: {ComplianceStore, store}})

    assert {503, %{"error" => "unavailable"}} =
             Intake.handle_terms(params, %{country: "US"}, invalid_ctx)

    assert {429, %{"error" => "rate limited"}} =
             Intake.handle_terms(params, %{country: "US"}, with_terms(invalid_ctx, store))

    assert ComplianceStore.get_acceptance(store, @user_ref, @terms_hash) == nil
    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "compliance without terms preserves the exact order response", %{
    base_ctx: ctx,
    keeper: keeper
  } do
    ref = register_order(keeper)
    params = order_params(ctx, ref)

    assert response = {200, body} = Intake.handle_order(params, ctx)
    refute Map.has_key?(body, "terms")

    off_ctx = Map.put(ctx, :compliance, %{geo_allow: ["US"]})
    assert ^response = Intake.handle_order(params, %{country: "US"}, off_ctx)
  end

  test "order view reports current terms required before acceptance and satisfied after", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    manual = %{address: "0x0000000000000000000000000000000000000001", amount: 1_000_000}

    {:ok, %{order_ref: ref}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: @user_ref,
        amount: 1_000_000,
        action_args: [],
        display: %{manual: manual}
      })

    params = order_params(ctx, ref)

    assert {200,
            %{
              "display" => gated_display,
              "terms" => %{
                "required" => true,
                "v_hash" => @terms_hash,
                "url" => "https://example.test/terms-v2"
              }
            }} = Intake.handle_order(params, %{country: "US"}, ctx)

    refute Map.has_key?(gated_display, "manual")

    :ok = ComplianceStore.record_acceptance(store, acceptance(@user_ref, @terms_hash))

    assert {200,
            %{
              "display" => %{"manual" => stringified_manual},
              "terms" => %{
                "required" => false,
                "v_hash" => @terms_hash,
                "url" => "https://example.test/terms-v2"
              }
            }} = Intake.handle_order(params, %{country: "US"}, ctx)

    assert stringified_manual == Map.new(manual, fn {key, value} -> {to_string(key), value} end)

    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "two-arity calls log the deny-all diagnosis only when compliance is configured", %{
    ctx: ctx,
    base_ctx: base_ctx,
    keeper: keeper
  } do
    ref = register_order(keeper)
    params = order_params(ctx, ref)

    log =
      capture_log(fn ->
        assert {451, %{"error" => "geo_blocked"}} = Intake.handle_order(params, ctx)
      end)

    assert log =~ "handle_order/2"
    assert log =~ "geofence denies every request"

    log = capture_log(fn -> assert {200, _} = Intake.handle_order(params, base_ctx) end)
    refute log =~ "handle_order/2"
  end

  test "user_tx order view withholds the tx payload until terms are accepted", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    {:ok, %{order_ref: ref}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: @user_ref,
        amount: 0,
        action_args: [],
        kind: "user_tx",
        tx: %{to: "0x" <> String.duplicate("11", 20), data: "0xdeadbeef", value: 0},
        display: %{summary_lines: ["Sell YES"]}
      })

    params = order_params(ctx, ref)

    assert {200, %{"kind" => "user_tx", "terms" => %{"required" => true}} = gated} =
             Intake.handle_order(params, %{country: "US"}, ctx)

    refute Map.has_key?(gated, "tx")

    :ok = ComplianceStore.record_acceptance(store, acceptance(@user_ref, @terms_hash))

    assert {200, %{"terms" => %{"required" => false}, "tx" => %{"data" => "0xdeadbeef"}}} =
             Intake.handle_order(params, %{country: "US"}, ctx)
  end

  test "old-hash and other-user acceptances do not satisfy the current user and hash", %{
    ctx: ctx,
    compliance_store: store
  } do
    :ok = ComplianceStore.record_acceptance(store, acceptance(@user_ref, @old_terms_hash))
    :ok = ComplianceStore.record_acceptance(store, acceptance(@other_user_ref, @terms_hash))

    ref = String.duplicate("ab", 32)
    params = %{"order_ref" => ref, "token" => token(ref), "permit" => %{}}

    assert @terms_required = Intake.handle_grant(params, %{country: "US"}, ctx)

    :ok = ComplianceStore.record_acceptance(store, acceptance(@user_ref, @terms_hash))

    assert {409, %{"error" => "version mismatch"}} =
             Intake.handle_grant(params, %{country: "US"}, ctx)
  end

  test "grant, wallet, and submitted gates run before validation and keeper work", %{
    ctx: ctx,
    compliance_store: store,
    fake: fake,
    keeper_store: keeper_store
  } do
    ref = String.duplicate("ab", 32)
    auth = token(ref)

    assert @terms_required =
             Intake.handle_grant(
               %{"order_ref" => ref, "token" => auth, "permit" => %{}},
               %{country: "US"},
               ctx
             )

    assert @terms_required =
             Intake.handle_wallet(
               %{"bind_ref" => ref, "token" => auth, "address" => "bad", "v" => "0.2.0"},
               %{country: "US"},
               Map.delete(ctx, :wallet_fn)
             )

    assert @terms_required =
             Intake.handle_submitted(
               %{"order_ref" => ref, "token" => auth, "tx_hash" => "bad", "v" => "0.2.0"},
               %{country: "US"},
               ctx
             )

    assert FakeRpc.sent(fake) == []
    assert MemoryStore.list_inflight(keeper_store) == []
    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "a 428 does not consume a bind ref and the same ref binds after acceptance", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    address = "0x8ba1f109551bd432803012645ac136ddd64dba72"

    params = %{
      "bind_ref" => ref,
      "token" => token(ref),
      "address" => address,
      "v" => "0.2.0"
    }

    assert @terms_required = Intake.handle_wallet(params, %{country: "US"}, ctx)
    refute_received {:bound, _, _, _}
    assert ComplianceStore.events_for(store, @user_ref) == []

    :ok =
      ComplianceStore.record_acceptance(
        store,
        acceptance(@user_ref, @terms_hash, "0x0000000000000000000000000000000000000001")
      )

    assert {200, %{"status" => "bound", "address" => bound}} =
             Intake.handle_wallet(params, %{country: "US"}, ctx)

    assert_received {:bound, @user_ref, ^bound, ^ref}
  end

  test "malformed terms and unreadable stores fail closed", %{base_ctx: ctx, keeper: keeper} do
    ref = register_order(keeper)
    params = order_params(ctx, ref)

    invalid_compliance = [
      %{geo_allow: ["US"], terms: nil},
      %{geo_allow: ["US"], terms: %{}},
      %{geo_allow: ["US"], terms: %{hash: @terms_hash}},
      %{geo_allow: ["US"], terms: %{hash: "0x1234", url: @terms.url}},
      %{geo_allow: ["US"], terms: %{hash: @terms_hash, url: ""}},
      %{geo_allow: ["US"], terms: @terms},
      %{geo_allow: ["US"], terms: @terms, store: :invalid},
      %{geo_allow: ["US"], terms: @terms, store: {"not-a-module", :ignored}},
      %{geo_allow: ["US"], terms: @terms, store: {MissingAcceptanceStore, :ignored}},
      %{geo_allow: ["US"], terms: @terms, store: {FailingAcceptanceStore, :raise}},
      %{geo_allow: ["US"], terms: @terms, store: {FailingAcceptanceStore, :exit}},
      %{geo_allow: ["US"], terms: @terms, store: {FailingAcceptanceStore, :throw}}
    ]

    for compliance <- invalid_compliance do
      assert {503, %{"error" => "unavailable"}} =
               Intake.handle_order(
                 params,
                 %{country: "US"},
                 Map.put(ctx, :compliance, compliance)
               )
    end
  end

  test "geofence remains first, two-arity stays fail-closed, and auth precedes the terms read", %{
    base_ctx: base_ctx
  } do
    ref = String.duplicate("ab", 32)
    params = %{"order_ref" => ref, "token" => token(ref), "v" => "0.2.0"}

    ctx =
      base_ctx
      |> Map.put(:rate, {Rate.start(60), 1})
      |> Map.put(:compliance, %{
        geo_allow: ["US"],
        terms: @terms,
        store: {FailingAcceptanceStore, :raise}
      })

    for handler <- [
          :handle_order,
          :handle_grant,
          :handle_wallet,
          :handle_submitted,
          :handle_terms
        ] do
      assert {451, %{"error" => "geo_blocked"}} =
               apply(Intake, handler, [%{}, %{country: "CA"}, ctx])

      assert {451, %{"error" => "geo_blocked"}} = apply(Intake, handler, [%{}, ctx])
    end

    assert {401, %{"error" => "unauthorized"}} =
             Intake.handle_order(
               %{"order_ref" => ref, "token" => "bad", "v" => "0.2.0"},
               %{country: "US"},
               ctx
             )

    assert {503, %{"error" => "unavailable"}} =
             Intake.handle_order(params, %{country: "US"}, ctx)
  end

  test "rate limiting remains before the terms gate", %{ctx: ctx, compliance_store: store} do
    ref = String.duplicate("ab", 32)
    params = %{"order_ref" => ref, "token" => token(ref), "permit" => %{}}
    ctx = Map.put(ctx, :rate, {Rate.start(60), 1})

    assert @terms_required = Intake.handle_grant(params, %{country: "US"}, ctx)

    assert {429, %{"error" => "rate limited"}} =
             Intake.handle_grant(params, %{country: "US"}, ctx)

    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  defp with_terms(ctx, store) do
    Map.put(ctx, :compliance, %{
      geo_allow: ["US"],
      terms: @terms,
      store: {ComplianceStore, store}
    })
  end

  defp register_order(keeper) do
    {:ok, %{order_ref: ref}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: @user_ref,
        amount: 0,
        action_args: [],
        kind: "bind"
      })

    ref
  end

  defp order_params(ctx, ref),
    do: %{"order_ref" => ref, "token" => token(ref), "v" => ctx.pinned.version}

  defp token(ref),
    do: Token.mint("tsecret", ref, @user_ref, System.os_time(:second) + 600)

  defp terms_params(ctx, ref, envelope) do
    %{
      "v" => ctx.pinned.version,
      "token" => token(ref),
      "ref" => ref,
      "acceptance" => envelope
    }
  end

  defp signed_acceptance(ctx, overrides \\ %{}, private_key \\ @anvil0) do
    envelope =
      Map.merge(
        %{
          "v" => ctx.pinned.version,
          "chain_id" => ctx.pinned.chain_id,
          "v_hash" => @terms_hash,
          "account" => Address.from_private_key(@anvil0),
          "issued_at" => System.os_time(:second)
        },
        overrides
      )

    digest =
      Terms.digest(
        envelope["chain_id"],
        envelope["v_hash"],
        envelope["account"],
        envelope["issued_at"]
      )

    {r, s, recid} = Secp256k1.sign(digest, private_key)

    Map.put(envelope, "sig", %{
      "v" => recid + 27,
      "r" => hex(r),
      "s" => hex(s)
    })
  end

  defp init_data do
    fields = %{
      "auth_date" => Integer.to_string(System.os_time(:second)),
      "query_id" => "AAF03",
      "user" => ~s({"id":777000111,"first_name":"A"})
    }

    data_check_string =
      fields
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", @bot_token)

    hash =
      :crypto.mac(:hmac, :sha256, secret, data_check_string)
      |> Base.encode16(case: :lower)

    URI.encode_query(Map.put(fields, "hash", hash))
  end

  defp hex(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  defp acceptance(user_ref, v_hash, account \\ "0x0000000000000000000000000000000000000002") do
    %{
      user_ref: user_ref,
      v_hash: v_hash,
      account: account,
      sig: %{v: 27, r: "0x11", s: "0x22"},
      issued_at: 100,
      accepted_at: 101,
      meta: %{}
    }
  end
end
