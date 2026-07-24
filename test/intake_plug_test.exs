defmodule DelegatedSpend.Intake.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias DelegatedSpend.Intake.Plug, as: IntakePlug
  alias DelegatedSpend.Intake.Token
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.MemoryStore
  alias DelegatedSpend.Orders

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
    test "round-trips a registered user_tx order", ctx do
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

    @tag capture_log: true
    test "a raising handler answers 500, never a crash", ctx do
      # ctx without :keeper makes the pure handler raise (KeyError) after auth
      opts = IntakePlug.init(ctx: %{token_secret: @secret}, config: @config)

      body = Jason.encode!(%{"order_ref" => ctx.order_ref, "token" => ctx.token})
      conn = post_json("/spend/orders", body, opts)
      assert conn.status == 500
      assert json(conn) == %{"error" => "internal"}
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
  end

  describe "routing" do
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
