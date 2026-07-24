# Compiled only when the optional :plug dependency is present: the whole
# module is host-plane HTTP glue, and the package must keep compiling for
# consumers (and the swarm engine) that don't ship plug.
if Code.ensure_loaded?(Plug.Conn) do
  defmodule DelegatedSpend.Intake.Plug do
    @moduledoc """
    Mountable HTTP surface for the wallet dapp — the serving glue every
    adopting host was hand-rolling around the pure `DelegatedSpend.Intake`
    handlers. Mount it under any Plug server (Bandit, Cowboy, a
    `Plug.Router` `forward`):

        Bandit.start_link(
          plug: {DelegatedSpend.Intake.Plug,
                 DelegatedSpend.Intake.Plug.init(
                   ctx: my_intake_ctx,
                   config: my_config_map
                 )},
          port: 4340
        )

    It serves:

      * `GET /` + the packaged `webapp/` statics (extension-allowlisted,
        traversal-guarded to the package's own `webapp/` dir),
      * `GET /config.json` — the HOST-provided `:config` map, matched
        case-insensitively against the resolved path so no spelling
        (`/Config.json`, `/./config.json`) can reach the package's static
        stale-pin file on a case-insensitive filesystem,
      * `POST <intakeUrl>/orders` and `POST <intakeUrl>/orders/submitted`
        (the two routes the dapp's `user_tx` flow calls) — thin JSON
        adapters over `DelegatedSpend.Intake.handle_order/2` and
        `handle_submitted/2` with the host `:ctx`. Bodies are read raw and
        capped (413 oversize, 400 bad JSON — never a crash); requests
        without a usable credential shape are refused 401 before any
        handler work.

    ## Init opts

      * `:config` (REQUIRED) — the served config.json map. Deployment
        config is host-specific by design; there is no fallback to the
        package's static file (that stale pin is exactly the drift the
        dapp's `configDrift` gate exists to catch). Its `"intakeUrl"`
        (default `"/spend"`) also anchors the POST routes, so the served
        config and the mounted routes can never disagree.
      * `:ctx` — the ctx map for the pure Intake handlers (`token_secret`,
        `keeper`, `pinned`, optional `submitted_fn`/`compliance`…).
      * `:body_limit` — request-body cap in bytes (default 65_536).
      * `:webapp_dir` — override the served statics dir. By default the
        package's own `webapp/` is resolved from THIS source file's
        compile-time path (`webapp/` is not under `priv/` and never reaches
        `_build`, so `Application.app_dir/1` would miss it). That works for
        path and git deps, where the source checkout persists at runtime;
        for a release that prunes source trees, copy `webapp/` into the
        release and pass `:webapp_dir` explicitly.
    """

    @behaviour Plug

    import Plug.Conn

    require Logger

    # put_resp_content_type appends "; charset=utf-8" itself — plain types.
    @content_types %{
      ".html" => "text/html",
      ".mjs" => "text/javascript",
      ".js" => "text/javascript",
      ".css" => "text/css",
      ".json" => "application/json",
      ".svg" => "image/svg+xml"
    }

    @default_body_limit 65_536
    @default_webapp_dir Path.expand("../../../webapp", __DIR__)

    @impl true
    def init(opts) do
      opts = Map.new(opts)

      config =
        case Map.fetch(opts, :config) do
          {:ok, config} when is_map(config) ->
            config

          _ ->
            raise ArgumentError,
                  "DelegatedSpend.Intake.Plug requires a :config map (the served config.json)"
        end

      %{
        ctx: Map.get(opts, :ctx, %{}),
        config: config,
        body_limit: Map.get(opts, :body_limit, @default_body_limit),
        webapp_dir: Path.expand(Map.get(opts, :webapp_dir) || @default_webapp_dir),
        intake: intake_segments(config)
      }
    end

    @impl true
    def call(conn, opts) do
      cond do
        conn.method == "GET" and conn.path_info == [] ->
          serve_webapp(conn, "index.html", opts)

        conn.method == "POST" and conn.path_info == opts.intake ++ ["orders"] ->
          handle_intake(conn, &DelegatedSpend.Intake.handle_order/2, opts)

        conn.method == "POST" and conn.path_info == opts.intake ++ ["orders", "submitted"] ->
          handle_intake(conn, &DelegatedSpend.Intake.handle_submitted/2, opts)

        conn.method == "GET" ->
          serve_webapp(conn, Enum.join(conn.path_info, "/"), opts)

        true ->
          send_resp(conn, 404, "")
      end
    end

    # ── intake adapter ─────────────────────────────────────────────────────

    # Oversize bodies answer 413 cleanly — a bare {:ok, …} match would
    # MatchError on {:more, …}, crashing the request process and logging
    # attacker-controlled body fragments.
    defp handle_intake(conn, handler, opts) do
      case read_body(conn, length: opts.body_limit) do
        {:ok, raw, conn} -> handle_intake_body(conn, handler, raw, opts)
        {:more, _partial, conn} -> json_resp(conn, 413, %{"error" => "payload_too_large"})
        {:error, _reason} -> json_resp(conn, 400, %{"error" => "bad_request"})
      end
    end

    defp handle_intake_body(conn, handler, raw, opts) do
      case Jason.decode(raw) do
        {:ok, params} when is_map(params) ->
          if credential_shape?(params, opts.ctx) do
            {status, body} = run_handler(handler, params, opts.ctx)
            json_resp(conn, status, body)
          else
            json_resp(conn, 401, %{"error" => "unauthorized"})
          end

        _ ->
          json_resp(conn, 400, %{"error" => "bad_request"})
      end
    end

    # Fail closed BEFORE any handler work: a request is only passed through
    # when it carries a credential the configured ctx can actually verify
    # (token needs :token_secret; init_data needs :bot_token). Anything else
    # is 401 here — the pure handlers assume their auth ctx keys exist.
    defp credential_shape?(params, ctx) do
      (is_binary(Map.get(ctx, :token_secret)) and nonempty?(params["token"])) or
        (is_binary(Map.get(ctx, :bot_token)) and nonempty?(params["init_data"]))
    end

    defp nonempty?(value), do: is_binary(value) and value != ""

    # A dead/absent keeper EXITS the caller (:noproc) rather than raising —
    # catch both and answer without ever echoing request contents.
    defp run_handler(handler, params, ctx) do
      handler.(params, ctx)
    rescue
      e ->
        Logger.warning("DelegatedSpend.Intake.Plug: handler raised #{Exception.message(e)}")
        {500, %{"error" => "internal"}}
    catch
      kind, reason ->
        Logger.warning("DelegatedSpend.Intake.Plug: handler #{kind}: #{inspect(reason)}")
        {503, %{"error" => "unavailable"}}
    end

    # ── static webapp ──────────────────────────────────────────────────────

    defp serve_webapp(conn, rel, opts) do
      dir = opts.webapp_dir
      full = Path.expand(rel, dir)
      ctype = Map.get(@content_types, Path.extname(full))

      cond do
        not String.starts_with?(full, dir <> "/") ->
          send_resp(conn, 404, "")

        # ANY spelling that resolves to the package's static config.json
        # ("/config.json", "/Config.json", "/./config.json") must serve the
        # host override, never the stale pin. Case-insensitive on purpose:
        # on a case-insensitive filesystem "/CONFIG.JSON" IS that file.
        String.downcase(full) == String.downcase(Path.join(dir, "config.json")) ->
          json_resp(conn, 200, opts.config)

        is_nil(ctype) ->
          send_resp(conn, 404, "")

        not File.regular?(full) ->
          send_resp(conn, 404, "")

        true ->
          conn |> put_resp_content_type(ctype) |> send_file(200, full)
      end
    end

    defp json_resp(conn, status, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp intake_segments(config) do
      url = Map.get(config, "intakeUrl") || Map.get(config, :intakeUrl) || "/spend"
      String.split(url, "/", trim: true)
    end
  end
end
