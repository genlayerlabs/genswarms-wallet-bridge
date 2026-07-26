defmodule DelegatedSpend.Intake.PlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias DelegatedSpend.Compliance.MemoryStore, as: ComplianceStore
  alias DelegatedSpend.Compliance.Terms
  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.Intake.Plug, as: IntakePlug
  alias DelegatedSpend.Intake.Token
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.MemoryStore
  alias DelegatedSpend.Orders

  @acceptance_key Base.decode16!(
                    "AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80"
                  )
  @terms_hash "0x" <> String.duplicate("11", 32)

  @secret "plug-test-secret"
  @chain_id 84_532
  @token_addr "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  @recipient "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"

  @config %{
    "version" => "test-v",
    "chainId" => @chain_id,
    "token" => @token_addr,
    "tokenName" => "USDC",
    "intakeUrl" => "/spend",
    "actionLabel" => "Top up"
  }

  setup do
    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(%{
        store: {MemoryStore, store},
        source_allowlist: ["app"],
        order_ttl_s: 900,
        chain_id: @chain_id
      })

    parent = self()

    ctx = %{
      keeper: keeper,
      token_secret: @secret,
      pinned: %{
        chain_id: @chain_id,
        token: @token_addr,
        router: "0x0000000000000000000000000000000000000000",
        version: "test-v"
      },
      submitted_fn: fn order_id, tx_hash -> send(parent, {:submitted, order_id, tx_hash}) end
    }

    order_ref = Orders.mint_order_ref()
    user_ref = Orders.user_ref("42", "plug-test-salt")

    {:ok, _ack} =
      Keeper.register_order(keeper, "app", %{
        order_ref: order_ref,
        user_ref: user_ref,
        amount: 2_500_000,
        action_args: [],
        kind: "user_tx",
        tx: Orders.erc20_transfer_order(@token_addr, @recipient, 2_500_000)
      })

    token = Token.mint(@secret, order_ref, user_ref, System.os_time(:second) + 900)

    %{
      ctx: ctx,
      opts: IntakePlug.init(ctx: ctx, config: @config),
      order_ref: order_ref,
      user_ref: user_ref,
      token: token
    }
  end

  defp post_json(path, body, opts) do
    :post
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> IntakePlug.call(opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # A real EIP-191 terms acceptance envelope (same construction as
  # test/intake_compliance_test.exs) — the /terms route is worth nothing if it
  # is only exercised with evidence the verifier rejects.
  defp signed_acceptance do
    envelope = %{
      "v" => "test-v",
      "chain_id" => @chain_id,
      "v_hash" => @terms_hash,
      "account" => Address.from_private_key(@acceptance_key),
      "issued_at" => System.os_time(:second)
    }

    digest =
      Terms.digest(
        envelope["chain_id"],
        envelope["v_hash"],
        envelope["account"],
        envelope["issued_at"]
      )

    {r, s, recid} = Secp256k1.sign(digest, @acceptance_key)

    Map.put(envelope, "sig", %{
      "v" => recid + 27,
      "r" => "0x" <> Base.encode16(r, case: :lower),
      "s" => "0x" <> Base.encode16(s, case: :lower)
    })
  end

  describe "static webapp serving" do
    test "GET / serves index.html", %{opts: opts} do
      conn = IntakePlug.call(conn(:get, "/"), opts)
      assert conn.status == 200
      assert {"content-type", "text/html; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body =~ "<html"
    end

    test "GET /app.mjs serves the module with its content type", %{opts: opts} do
      conn = IntakePlug.call(conn(:get, "/app.mjs"), opts)
      assert conn.status == 200
      assert {"content-type", "text/javascript; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body == File.read!("webapp/app.mjs")
    end

    test "nested statics are served, unknown files and extensions 404", %{opts: opts} do
      assert IntakePlug.call(conn(:get, "/lib/flow.mjs"), opts).status == 200
      assert IntakePlug.call(conn(:get, "/nope.mjs"), opts).status == 404
      assert IntakePlug.call(conn(:get, "/spike"), opts).status == 404
    end

    test "traversal outside webapp/ is 404, even for allowlisted extensions", %{opts: opts} do
      assert IntakePlug.call(conn(:get, "/../mix.exs"), opts).status == 404
      assert IntakePlug.call(conn(:get, "/../webapp/../mix.exs"), opts).status == 404
      assert IntakePlug.call(conn(:get, "/../test/orders_test.exs"), opts).status == 404

      assert IntakePlug.call(conn(:get, "/lib/../../objects/spend_keeper/orders.ex"), opts).status ==
               404
    end

    test "a symlink to an allowlisted file outside webapp_dir is 404" do
      tmp =
        Path.join(System.tmp_dir!(), "dsp-plug-symlink-#{System.unique_integer([:positive])}")

      webapp = Path.join(tmp, "webapp")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(webapp)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.mjs"), "outside secret")
      File.ln_s!(Path.join(outside, "secret.mjs"), Path.join(webapp, "escape.mjs"))
      on_exit(fn -> File.rm_rf(tmp) end)

      opts = IntakePlug.init(ctx: %{}, config: @config, webapp_dir: webapp)
      conn = IntakePlug.call(conn(:get, "/escape.mjs"), opts)

      assert conn.status == 404
      refute conn.resp_body =~ "outside secret"
    end
  end

  describe "config.json override" do
    test "GET /config.json serves the host map, not the packaged file", %{opts: opts} do
      conn = IntakePlug.call(conn(:get, "/config.json"), opts)
      assert conn.status == 200
      assert json(conn) == @config
      refute json(conn) == "webapp/config.json" |> File.read!() |> Jason.decode!()
    end

    test "case spellings cannot bypass the override", %{opts: opts} do
      for path <- ["/Config.json", "/CONFIG.JSON", "/config.JSON"] do
        conn = IntakePlug.call(conn(:get, path), opts)
        assert conn.status == 200, "#{path} must serve the override"
        assert json(conn) == @config, "#{path} served the stale packaged file"
      end
    end

    test "dot-segment spellings that resolve to config.json serve the override", %{opts: opts} do
      conn = IntakePlug.call(conn(:get, "/./config.json"), opts)
      assert conn.status == 200
      assert json(conn) == @config

      conn = IntakePlug.call(conn(:get, "/lib/../config.json"), opts)
      assert conn.status == 200
      assert json(conn) == @config
    end
  end

  describe "POST /spend/orders" do
    test "round-trips a registered user_tx order with compliance off", ctx do
      body =
        Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => ctx.token, "v" => "test-v"})

      conn = post_json("/spend/orders", body, ctx.opts)
      assert conn.status == 200

      view = json(conn)
      assert view["kind"] == "user_tx"
      assert view["chain_id"] == @chain_id
      assert view["amount"] == 2_500_000
      assert view["tx"]["to"] == @token_addr
    end

    test "401 without any token", ctx do
      conn = post_json("/spend/orders", Jason.encode!(%{"order_ref" => ctx.order_ref}), ctx.opts)
      assert conn.status == 401
      assert json(conn) == %{"error" => "unauthorized"}

      # empty-string token is not a credential shape either
      conn =
        post_json(
          "/spend/orders",
          Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => ""}),
          ctx.opts
        )

      assert conn.status == 401
    end

    test "401 with a forged token", ctx do
      forged = Token.mint("wrong-secret", ctx.order_ref, ctx.user_ref, 4_000_000_000)

      conn =
        post_json(
          "/spend/orders",
          Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => forged, "v" => "test-v"}),
          ctx.opts
        )

      assert conn.status == 401
      assert json(conn) == %{"error" => "unauthorized"}
    end

    test "413 on an oversize body, bounded by :body_limit", _ctx do
      small = IntakePlug.init(ctx: %{token_secret: @secret}, config: @config, body_limit: 64)
      body = Jason.encode!(%{"token" => "t", "pad" => String.duplicate("x", 500)})

      conn = post_json("/spend/orders", body, small)
      assert conn.status == 413
      assert json(conn) == %{"error" => "payload_too_large"}
    end

    test "400 on bad JSON and non-map JSON", ctx do
      assert post_json("/spend/orders", "{not json", ctx.opts).status == 400
      assert post_json("/spend/orders", "[1,2,3]", ctx.opts).status == 400
      assert json(post_json("/spend/orders", "", ctx.opts)) == %{"error" => "bad_request"}
    end

    @tag capture_log: true
    test "a crashing/dead keeper answers a clean error, never a crash", ctx do
      dead_ctx = %{
        keeper: :no_such_keeper_process,
        token_secret: @secret,
        pinned: %{chain_id: @chain_id, token: @token_addr, router: "0x0", version: "test-v"}
      }

      opts = IntakePlug.init(ctx: dead_ctx, config: @config)

      body =
        Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => ctx.token, "v" => "test-v"})

      conn = post_json("/spend/orders", body, opts)
      assert conn.status == 503
      assert json(conn) == %{"error" => "unavailable"}
    end

    test "a raising handler answers 500 without exposing secret material", ctx do
      # ctx without :keeper makes the pure handler raise (KeyError) after auth
      secret = "handler-crash-secret-#{System.unique_integer([:positive])}"
      token = Token.mint(secret, ctx.order_ref, ctx.user_ref, 4_000_000_000)
      opts = IntakePlug.init(ctx: %{token_secret: secret}, config: @config)

      body = Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => token})
      parent = self()

      log =
        capture_log(fn ->
          send(parent, {:crash_response, post_json("/spend/orders", body, opts)})
        end)

      assert_receive {:crash_response, conn}
      assert conn.status == 500
      assert json(conn) == %{"error" => "internal"}
      refute log =~ secret
      refute log =~ token
      refute conn.resp_body =~ secret
      refute conn.resp_body =~ token
    end

    test "compliance-on requests receive trusted metadata instead of a spurious 451", ctx do
      compliance_store = ComplianceStore.start()

      compliance_ctx =
        Map.put(ctx.ctx, :compliance, %{
          geo_block: ["CU"],
          store: {ComplianceStore, compliance_store}
        })

      opts =
        IntakePlug.init(
          ctx: compliance_ctx,
          config: @config,
          trusted_hops: 1,
          country_header: "x-geo-country"
        )

      body =
        Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => ctx.token, "v" => "test-v"})

      conn =
        :post
        |> conn("/spend/orders", body)
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> put_req_header("x-geo-country", "US")
        |> put_req_header("user-agent", "wallet-plug-test/1.0")
        |> put_req_header("cookie", "spend_session=session-1")
        |> IntakePlug.call(opts)

      assert conn.status == 200
      refute json(conn) == %{"error" => "geo_blocked"}
    end
  end

  describe "POST /spend/orders/submitted" do
    test "delegates to handle_submitted and reaches submitted_fn", ctx do
      tx_hash = "0x" <> String.duplicate("ab", 32)

      body =
        Jason.encode!(%{
          "order_ref" => ctx.order_ref,
          "token" => ctx.token,
          "v" => "test-v",
          "tx_hash" => tx_hash
        })

      conn = post_json("/spend/orders/submitted", body, ctx.opts)
      assert conn.status == 200
      assert json(conn) == %{"status" => "noted"}
      assert_receive {:submitted, "0x" <> _, ^tx_hash}
    end

    test "passes IP, headers, country, and session metadata to compliance handlers", ctx do
      compliance_store = ComplianceStore.start()

      compliance_ctx =
        Map.put(ctx.ctx, :compliance, %{
          geo_block: ["CU"],
          store: {ComplianceStore, compliance_store}
        })

      opts =
        IntakePlug.init(
          ctx: compliance_ctx,
          config: @config,
          trusted_hops: 1,
          country_header: "x-geo-country"
        )

      tx_hash = "0x" <> String.duplicate("cd", 32)

      body =
        Jason.encode!(%{
          "order_ref" => ctx.order_ref,
          "token" => ctx.token,
          "v" => "test-v",
          "tx_hash" => tx_hash
        })

      conn =
        :post
        |> conn("/spend/orders/submitted", body)
        |> Map.put(:remote_ip, {10, 0, 0, 1})
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-forwarded-for", "203.0.113.9")
        |> put_req_header("x-geo-country", "us")
        |> put_req_header("user-agent", "wallet-plug-test/1.0")
        |> put_req_header("cookie", "spend_session=session-1")
        |> IntakePlug.call(opts)

      assert conn.status == 200

      assert [
               %{
                 kind: "tx_submitted",
                 meta: %{
                   ip: "203.0.113.9",
                   country: "US",
                   user_agent: "wallet-plug-test/1.0",
                   session_id: "session-1"
                 }
               }
             ] = ComplianceStore.events_for(compliance_store, ctx.user_ref)
    end
  end

  # A plug that ACCEPTS the compliance options must also route the one request
  # that answers them. With `ctx.compliance` configured, handle_order withholds
  # the executable `tx` and handle_submitted answers 428 until the current
  # terms are accepted — and the dapp accepts them by POSTing
  # `<intakeUrl>/terms` (webapp/lib/flow.mjs). Unrouted, that is a permanently
  # bricked lane for every compliance-enabled consumer.
  describe "POST /spend/terms" do
    setup ctx do
      compliance_store = ComplianceStore.start()

      compliance_ctx =
        Map.put(ctx.ctx, :compliance, %{
          geo_block: ["CU"],
          terms: %{hash: @terms_hash, url: "https://example.test/terms-v2"},
          store: {ComplianceStore, compliance_store}
        })

      %{
        compliance_store: compliance_store,
        compliance_opts:
          IntakePlug.init(
            ctx: compliance_ctx,
            config: @config,
            trusted_hops: 1,
            country_header: "x-geo-country"
          )
      }
    end

    # Compliance fails CLOSED without country evidence (Geo.allowed?/2), so
    # every compliance-on request carries the edge headers the plug is
    # configured to trust.
    defp post_compliance(path, body, opts) do
      :post
      |> conn(path, body)
      |> Map.put(:remote_ip, {10, 0, 0, 1})
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.9")
      |> put_req_header("x-geo-country", "US")
      |> put_req_header("user-agent", "wallet-plug-test/1.0")
      |> put_req_header("cookie", "spend_session=session-1")
      |> IntakePlug.call(opts)
    end

    test "un-gates the order lane end to end: 428 → accept → tx served", ctx do
      order_body =
        Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => ctx.token, "v" => "test-v"})

      gated = post_compliance("/spend/orders", order_body, ctx.compliance_opts)
      assert gated.status == 200

      assert json(gated)["terms"] == %{
               "required" => true,
               "v_hash" => @terms_hash,
               "url" => "https://example.test/terms-v2"
             }

      refute Map.has_key?(json(gated), "tx")

      submit_body =
        Jason.encode!(%{
          "order_ref" => ctx.order_ref,
          "token" => ctx.token,
          "v" => "test-v",
          "tx_hash" => "0x" <> String.duplicate("ab", 32)
        })

      blocked = post_compliance("/spend/orders/submitted", submit_body, ctx.compliance_opts)
      assert blocked.status == 428
      assert json(blocked)["error"] == "terms_required"

      terms_body =
        Jason.encode!(%{
          "v" => "test-v",
          "token" => ctx.token,
          "ref" => ctx.order_ref,
          "acceptance" => signed_acceptance()
        })

      accepted = post_compliance("/spend/terms", terms_body, ctx.compliance_opts)
      assert accepted.status == 200
      assert json(accepted) == %{"status" => "accepted", "v_hash" => @terms_hash}

      ungated = post_compliance("/spend/orders", order_body, ctx.compliance_opts)
      assert ungated.status == 200
      assert json(ungated)["terms"]["required"] == false
      assert json(ungated)["tx"]["data"] =~ "0xa9059cbb"

      assert post_compliance("/spend/orders/submitted", submit_body, ctx.compliance_opts).status ==
               200
    end

    test "carries trusted request metadata into the persisted acceptance", ctx do
      body =
        Jason.encode!(%{
          "v" => "test-v",
          "token" => ctx.token,
          "ref" => ctx.order_ref,
          "acceptance" => signed_acceptance()
        })

      conn = post_compliance("/spend/terms", body, ctx.compliance_opts)
      assert conn.status == 200

      persisted = ComplianceStore.get_acceptance(ctx.compliance_store, ctx.user_ref, @terms_hash)
      assert persisted.meta.ip == "203.0.113.9"
      assert persisted.meta.country == "US"
      assert persisted.meta.user_agent == "wallet-plug-test/1.0"
      assert persisted.meta.session_id == "session-1"
    end

    test "is refused 401 before any handler work when the credential is missing", ctx do
      body = Jason.encode!(%{"v" => "test-v", "ref" => ctx.order_ref, "acceptance" => %{}})

      conn = post_json("/spend/terms", body, ctx.compliance_opts)
      assert conn.status == 401
      assert json(conn) == %{"error" => "unauthorized"}
    end

    test "answers 503 (not 404) when the host configured no compliance", ctx do
      body =
        Jason.encode!(%{
          "v" => "test-v",
          "token" => ctx.token,
          "ref" => ctx.order_ref,
          "acceptance" => signed_acceptance()
        })

      conn = post_json("/spend/terms", body, ctx.opts)
      assert conn.status == 503
      assert json(conn) == %{"error" => "unavailable"}
    end

    test "follows the configured intakeUrl like every other intake route", _ctx do
      config = Map.put(@config, "intakeUrl", "/wallet-api")
      opts = IntakePlug.init(ctx: %{token_secret: @secret}, config: config)
      body = Jason.encode!(%{"token" => "zz", "ref" => "abc"})

      # reaches the handler (401 from token verify) instead of a 404 router miss
      assert post_json("/wallet-api/terms", body, opts).status == 401
      assert post_json("/spend/terms", body, opts).status == 404
    end
  end

  # The keeper this whole file shares (see the top-level `setup`) has no
  # signer/treasury/token configured — the authorization lane is disabled —
  # so a request that clears the credential gate still gets a typed 422
  # (`authorization_lane_disabled`) from the REAL keeper, never a stub. That
  # is exactly the point: this route is transport only, so proving it
  # reaches the real `Intake.handle_authorization/3` → `Keeper` chain is the
  # whole test, regardless of whether the lane happens to be configured.
  describe "POST /spend/authorization" do
    setup ctx do
      order_ref = Orders.mint_order_ref()

      {:ok, _ack} =
        Keeper.register_order(ctx.ctx.keeper, "app", %{
          order_ref: order_ref,
          user_ref: ctx.user_ref,
          amount: 1_000_000,
          action_args: [],
          kind: "authorization"
        })

      token = Token.mint(@secret, order_ref, ctx.user_ref, System.os_time(:second) + 900)

      %{auth_order_ref: order_ref, auth_token: token}
    end

    defp auth_body(order_ref, token, overrides \\ %{}) do
      envelope =
        Map.merge(
          %{
            "v" => "test-v",
            "chain_id" => @chain_id,
            "token" => @token_addr,
            "from" => "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
            "value" => 1_000_000,
            "valid_after" => 0,
            "valid_before" => 4_000_000_000,
            "signature" => "0x" <> String.duplicate("11", 65)
          },
          overrides
        )

      Jason.encode!(%{
        "order_ref" => order_ref,
        "token" => token,
        "v" => "test-v",
        "authorization" => envelope
      })
    end

    test "transport only: reaches handle_authorization/3 and returns its {status, body} verbatim",
         ctx do
      body = auth_body(ctx.auth_order_ref, ctx.auth_token)
      conn = post_json("/spend/authorization", body, ctx.opts)

      assert conn.status == 422
      assert json(conn) == %{"status" => "failed", "reason" => "authorization_lane_disabled"}
    end

    test "401 without any credential, before any handler work", ctx do
      body = Jason.encode!(%{"order_ref" => ctx.auth_order_ref, "authorization" => %{}})
      conn = post_json("/spend/authorization", body, ctx.opts)
      assert conn.status == 401
      assert json(conn) == %{"error" => "unauthorized"}
    end

    test "413 on an oversize body, bounded by :body_limit", _ctx do
      small = IntakePlug.init(ctx: %{token_secret: @secret}, config: @config, body_limit: 64)
      body = Jason.encode!(%{"token" => "t", "pad" => String.duplicate("x", 500)})

      conn = post_json("/spend/authorization", body, small)
      assert conn.status == 413
      assert json(conn) == %{"error" => "payload_too_large"}
    end

    test "400 on bad JSON and non-map JSON", ctx do
      assert post_json("/spend/authorization", "{not json", ctx.opts).status == 400
      assert post_json("/spend/authorization", "[1,2,3]", ctx.opts).status == 400
    end
  end

  describe "routing" do
    test "the grant lane is NOT routed (this plug is the user_tx surface)", ctx do
      # Not an oversight: /grants and /wallet need a keeper with a signer, a
      # router and an action ABI plus a host-owned wallet_fn. Documented in the
      # moduledoc; pinned here so routing them becomes a deliberate change.
      assert post_json("/spend/grants", "{}", ctx.opts).status == 404
      assert post_json("/spend/wallet", "{}", ctx.opts).status == 404
    end

    test "the authorization lane IS routed here (unlike grants/wallet)", ctx do
      # No router/action ABI and no host wallet_fn needed for this lane, so
      # (unlike /grants and /wallet above) it fits this plug's deployment
      # shape — it reaches the handler (never a 404 router miss).
      refute post_json("/spend/authorization", "{}", ctx.opts).status == 404
    end

    test "unknown POST routes and non-GET/POST methods are 404", ctx do
      assert post_json("/spend/grants", "{}", ctx.opts).status == 404
      assert post_json("/orders", "{}", ctx.opts).status == 404
      assert IntakePlug.call(conn(:delete, "/config.json"), ctx.opts).status == 404
    end

    test "the intake prefix follows config intakeUrl", _ctx do
      config = Map.put(@config, "intakeUrl", "/wallet-api")
      opts = IntakePlug.init(ctx: %{token_secret: @secret}, config: config)

      conn = post_json("/wallet-api/orders", Jason.encode!(%{"token" => "zz"}), opts)
      # reaches the handler (401 from token verify), instead of the 404 router miss
      assert conn.status == 401
      assert post_json("/spend/orders", Jason.encode!(%{"token" => "zz"}), opts).status == 404
    end
  end

  describe "init/1" do
    test "requires a :config map" do
      assert_raise ArgumentError, ~r/:config map/, fn -> IntakePlug.init(ctx: %{}) end
      assert_raise ArgumentError, ~r/:config map/, fn -> IntakePlug.init(config: "nope") end
    end

    test "atom-keyed config works for the intake prefix" do
      opts = IntakePlug.init(ctx: %{}, config: %{intakeUrl: "/x"})
      assert opts.intake == ["x"]
    end

    test "a custom :webapp_dir is honored", %{opts: _opts} do
      tmp =
        Path.join(System.tmp_dir!(), "dsp-plug-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "index.html"), "<html>custom</html>")
      on_exit(fn -> File.rm_rf(tmp) end)

      opts = IntakePlug.init(ctx: %{}, config: @config, webapp_dir: tmp)
      conn = IntakePlug.call(conn(:get, "/"), opts)
      assert conn.status == 200
      assert conn.resp_body == "<html>custom</html>"
    end
  end
end
