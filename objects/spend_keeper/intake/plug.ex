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
      * `POST <intakeUrl>/orders`, `POST <intakeUrl>/orders/submitted`,
        `POST <intakeUrl>/terms`, `POST <intakeUrl>/authorization` and
        `POST <intakeUrl>/authorization/self` (every route the dapp's
        `user_tx` and EIP-3009 authorization flows call) — thin JSON adapters
        over `DelegatedSpend.Intake.handle_order/3`, `handle_submitted/3`,
        `handle_terms/3`, `handle_authorization/3` and
        `handle_self_authorization/3`
        with trusted request metadata and the host `:ctx`. Bodies are read
        raw and capped (413 oversize, 400 bad JSON — never a crash);
        requests without a usable credential shape are refused 401 before
        any handler work. **Transport only**: every authority decision
        (geofence, `initData` authentication, rate limit, terms, pinned
        config) lives inside the `Intake` handlers themselves — this plug
        never calls the keeper directly.

    ## Scope: the user_tx lane, terms included

    `/terms` is routed because it is not optional decoration: with
    `ctx.compliance` configured, `handle_order/3` WITHHOLDS the executable
    `tx` and `handle_submitted/3` answers `428 terms_required` until the
    current terms are accepted, and the dapp accepts them by POSTing
    `<intakeUrl>/terms` (`webapp/lib/flow.mjs`). A plug that takes the
    compliance options but does not route that answer gives every
    compliance-enabled consumer a permanently bricked lane — the order view
    withholds `tx` forever and nothing can ever accept the terms. Routed
    unconditionally: when the host configures no `:compliance`, the pure
    handler is the authority and answers `503 unavailable` (there is nothing
    to accept), which is why this needs no branch on the ctx.

    The PERMIT grant lane (`POST /grants`, `POST /wallet` —
    `DelegatedSpend.Intake.handle_grant/3` and `handle_wallet/3`) is
    deliberately NOT routed here. It needs a keeper configured with a signer,
    a router and an action ABI, plus a host-owned `wallet_fn`, i.e. a
    different deployment shape with its own decisions to make; a host running
    that lane mounts its own router or forwards those two paths. This plug is
    the user_tx/bind-read surface, PLUS the authorization (EIP-3009) lane
    below — which, unlike the permit lane, needs no router/action ABI and no
    host `wallet_fn`, only the keeper's own `:treasury_address` /
    `:token_address`, so it fits this plug's existing deployment shape.

    ## Init opts

      * `:config` (REQUIRED) — the served config.json map. Deployment
        config is host-specific by design; there is no fallback to the
        package's static file (that stale pin is exactly the drift the
        dapp's `configDrift` gate exists to catch). Its `"intakeUrl"`
        (default `"/spend"`) also anchors the POST routes, so the served
        config and the mounted routes can never disagree.
      * `:ctx` — the ctx map for the pure Intake handlers (`token_secret`,
        `keeper`, `pinned`, optional `submitted_fn`/`compliance`…).
      * `:trusted_hops`, `:country_header`, `:session_cookie` — passed to
        `DelegatedSpend.Compliance.Meta.build/4`. `trusted_hops` defaults to
        `0`, `country_header` to none, and `session_cookie` to
        `"spend_session"`; deployments enabling compliance must name the
        country header their trusted edge overwrites.
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

    alias DelegatedSpend.Compliance.Meta

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
        meta_opts: [
          trusted_hops: Map.get(opts, :trusted_hops, 0),
          country_header: Map.get(opts, :country_header),
          session_cookie: Map.get(opts, :session_cookie, "spend_session")
        ],
        intake: intake_segments(config)
      }
    end

    @impl true
    def call(conn, opts) do
      cond do
        conn.method == "GET" and conn.path_info == [] ->
          serve_webapp(conn, "index.html", opts)

        conn.method == "POST" and conn.path_info == opts.intake ++ ["orders"] ->
          handle_intake(conn, &DelegatedSpend.Intake.handle_order/3, opts)

        conn.method == "POST" and conn.path_info == opts.intake ++ ["orders", "submitted"] ->
          handle_intake(conn, &DelegatedSpend.Intake.handle_submitted/3, opts)

        # The compliance answer to a 428 from either route above. Without it a
        # compliance-enabled consumer's lane can never be un-gated.
        conn.method == "POST" and conn.path_info == opts.intake ++ ["terms"] ->
          handle_intake(conn, &DelegatedSpend.Intake.handle_terms/3, opts)

        # Unlike the grant (permit) lane below, the authorization (EIP-3009)
        # lane needs no router/action ABI and no host wallet_fn — only the
        # keeper's own :treasury_address/:token_address — so it is routed
        # here like /terms, not left to a host-mounted router. All FIVE
        # authority gates still run inside `handle_authorization/3` itself;
        # this is transport only (see the moduledoc's "authority" note).
        conn.method == "POST" and conn.path_info == opts.intake ++ ["authorization"] ->
          handle_intake(conn, &DelegatedSpend.Intake.handle_authorization/3, opts)

        # Self-submit validates the signed EIP-3009 envelope server-side, then
        # returns calldata for the payer's wallet. Like the sponsored sibling,
        # it needs no host router/action ABI or wallet callback.
        conn.method == "POST" and
            conn.path_info == opts.intake ++ ["authorization", "self"] ->
          handle_intake(conn, &DelegatedSpend.Intake.handle_self_authorization/3, opts)

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
      conn = fetch_cookies(conn)
      meta = Meta.build(conn.remote_ip, conn.req_headers, conn.req_cookies, opts.meta_opts)

      case read_body(conn, length: opts.body_limit) do
        {:ok, raw, conn} -> handle_intake_body(conn, handler, raw, meta, opts)
        {:more, _partial, conn} -> json_resp(conn, 413, %{"error" => "payload_too_large"})
        {:error, _reason} -> json_resp(conn, 400, %{"error" => "bad_request"})
      end
    end

    defp handle_intake_body(conn, handler, raw, meta, opts) do
      case Jason.decode(raw) do
        {:ok, params} when is_map(params) ->
          if credential_shape?(params, opts.ctx) do
            {status, body} = run_handler(handler, params, meta, opts.ctx)
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
    defp run_handler(handler, params, meta, ctx) do
      handler.(params, meta, ctx)
    rescue
      _ ->
        Logger.warning("DelegatedSpend.Intake.Plug: handler raised")
        {500, %{"error" => "internal"}}
    catch
      _, _ ->
        Logger.warning("DelegatedSpend.Intake.Plug: handler exited")
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

        not canonical_descendant?(full, dir) ->
          send_resp(conn, 404, "")

        true ->
          conn |> put_resp_content_type(ctype) |> send_file(200, full)
      end
    end

    defp canonical_descendant?(path, dir) do
      with {:ok, real_path} <- canonical_path(path),
           {:ok, real_dir} <- canonical_path(dir) do
        String.starts_with?(real_path, real_dir <> "/")
      else
        _ -> false
      end
    end

    # Elixir 1.14 has no File.realpath/1. Resolve every existing path component,
    # restarting after each link so relative targets and links inside links are
    # handled before the containment check.
    defp canonical_path(path), do: resolve_segments(Path.split(Path.expand(path)), 0)

    defp resolve_segments([root | segments], links),
      do: resolve_segments(root, segments, links)

    defp resolve_segments(resolved, [], _links), do: {:ok, resolved}

    defp resolve_segments(resolved, [segment | rest], links) do
      candidate = Path.join(resolved, segment)

      case File.read_link(candidate) do
        {:ok, target} when links < 40 ->
          target = Path.expand(target, resolved)
          resolve_segments(Path.split(Path.join([target | rest])), links + 1)

        {:ok, _target} ->
          {:error, :too_many_symlinks}

        {:error, :einval} ->
          resolve_segments(candidate, rest, links)

        {:error, reason} ->
          {:error, reason}
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
