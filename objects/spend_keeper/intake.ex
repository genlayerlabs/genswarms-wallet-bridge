defmodule DelegatedSpend.Intake do
  @moduledoc """
  Package-shipped intake (spec §6.1) as PURE HANDLERS — request params →
  `{http_status, body_map}`. The consuming app supplies HTTP serving (its
  own Bandit/Plug glue), the fail-closed bind policy, and the
  `telegram_user_id → user_ref` function.

  Server-side authority (do-not-weaken):
    * `user_ref` derives ONLY from verified `initData`; nothing client-sent
      is authoritative.
    * Unauthenticated requests are rejected BEFORE any work (401, no store
      reads, no rate-bucket consumption for unauthenticated callers).
    * Grant envelopes are strictly validated against pinned config.
    * A version mismatch (stale wallet dapp build) is rejected at runtime (409).
    * `initData` never appears in logs or errors.

  Callback authority:
    * `wallet_fn` is consumer-owned, request-critical wallet persistence.
    * `wallet_view_fn` is the consumer-owned wallet lookup.
    * `submitted_fn` is an untrusted, best-effort transaction hint with no
      product-credit authority.

  ctx: `%{bot_token:, max_age_s:, user_ref_fn:, keeper:, pinned:, rate:}`
  where `pinned = %{chain_id:, token:, router:, version:}` and
  `rate = {RateLimiter-pid, max_per_window}` (see `DelegatedSpend.Intake.Rate`).
  """

  alias DelegatedSpend.Intake.{GrantValidation, Rate, TelegramAuth, Token}
  alias DelegatedSpend.Keeper

  @doc "GET /orders?order_ref=… — fetch a pending order for the verified user."
  def handle_order(params, ctx) when is_map(params) do
    order_ref = to_string(params["order_ref"] || "")

    with :ok <- pin_version(params, ctx),
         {:ok, user_ref} <- authenticate(params, ctx, order_ref),
         :ok <- allow(ctx, user_ref) do
      case Keeper.fetch_order(ctx.keeper, order_ref, user_ref) do
        {:ok, view} ->
          if expired_user_tx?(view) do
            {410, %{"error" => "expired"}}
          else
            base = %{
              "order_ref" => view.order_ref,
              "kind" => view.kind,
              "amount" => view.amount,
              "expires_at" => view.expires_at,
              # The keeper's RUNTIME chain id, on every view of every kind:
              # the dapp fails CLOSED when its static config.json disagrees
              # (config drift — nothing may be signed on a mismatched chain).
              "chain_id" => view.chain_id,
              "display" => stringify(view.display)
            }

            # Owner-bound orders carry the wallet they must be paid from (an
            # address the user already knows, not a secret) so the dapp can
            # refuse a mismatched connected wallet before anything is signed.
            base =
              case Map.get(view, :expected_owner) do
                nil -> base
                owner -> Map.put(base, "expected_owner", owner)
              end

            body =
              case view.kind do
                "user_tx" ->
                  Map.put(base, "tx", stringify(view.tx))

                "bind" ->
                  Map.put(base, "current_wallet", wallet_view(ctx, user_ref))

                _ ->
                  base
              end

            {200, body}
          end

        {:error, :not_found} ->
          {404, %{"error" => "not found"}}
      end
    else
      {:error, status, body} -> {status, body}
    end
  end

  @doc """
  POST /grants — permit envelope for a pending order. Validates strictly
  against pinned config, then hands to the keeper for execution.
  """
  def handle_grant(params, ctx) when is_map(params) do
    order_ref = to_string(params["order_ref"] || "")

    with {:ok, user_ref} <- authenticate(params, ctx, order_ref),
         :ok <- allow(ctx, user_ref) do
      case GrantValidation.validate_permit(params["permit"] || %{}, ctx.pinned) do
        {:error, {:pinned_mismatch, :version}} ->
          {409, %{"error" => "version mismatch"}}

        {:error, {:pinned_mismatch, field}} ->
          {422, %{"error" => "pinned mismatch", "field" => to_string(field)}}

        {:error, {:invalid, field}} ->
          {422, %{"error" => "invalid", "field" => to_string(field)}}

        {:ok, permit} ->
          case Keeper.execute_with_permit(ctx.keeper, order_ref, user_ref, permit) do
            :pending -> {200, %{"status" => "pending"}}
            {:submitted, hash} -> {200, %{"status" => "submitted", "tx" => hash}}
            {:mined, hash} -> {200, %{"status" => "mined", "tx" => hash}}
            {:failed, :not_found} -> {404, %{"error" => "not found"}}
            {:failed, reason} -> {422, %{"status" => "failed", "reason" => to_string(reason)}}
            :unknown -> {404, %{"error" => "not found"}}
          end
      end
    else
      {:error, status, body} -> {status, body}
    end
  end

  @doc "POST /wallet — bind a connected wallet address through a bind order."
  def handle_wallet(params, ctx) when is_map(params) do
    bind_ref = to_string(params["bind_ref"] || "")

    with :ok <- pin_version(params, ctx),
         {:ok, user_ref} <- authenticate(params, ctx, bind_ref),
         :ok <- allow(ctx, user_ref),
         {:ok, wallet_fn} <- fetch_fn(ctx, :wallet_fn, 3),
         {:ok, address} <- checksum_address(params["address"]),
         {:ok, order} <- fetch_kind(ctx, bind_ref, user_ref, "bind"),
         {:ok, _order} <- consume(ctx, order, user_ref) do
      # The ref is consumed BEFORE the callback on purpose (single-use,
      # fail-closed): a rejected or crashing wallet_fn burns it and the user
      # asks for a fresh bind link — a failure is never replayable.
      case safe_wallet(wallet_fn, user_ref, address, bind_ref) do
        :ok -> {200, %{"status" => "bound", "address" => address}}
        _ -> {422, %{"error" => "bind rejected"}}
      end
    else
      {:error, status, body} -> {status, body}
    end
  end

  @doc "POST /orders/submitted — best-effort user_tx hash report; watcher hint only."
  def handle_submitted(params, ctx) when is_map(params) do
    order_ref = to_string(params["order_ref"] || "")

    with :ok <- pin_version(params, ctx),
         {:ok, user_ref} <- authenticate(params, ctx, order_ref),
         :ok <- allow(ctx, user_ref),
         {:ok, tx_hash} <- tx_hash(params["tx_hash"]),
         {:ok, order} <- fetch_kind(ctx, order_ref, user_ref, "user_tx") do
      case Map.get(ctx, :submitted_fn) do
        fun when is_function(fun, 2) -> safe_submitted(fun, order.order_id, tx_hash)
        _ -> :ok
      end

      {200, %{"status" => "noted"}}
    else
      {:error, status, body} -> {status, body}
    end
  end

  # ── auth + rate ────────────────────────────────────────────────────────────

  defp authenticate(params, ctx, ref) do
    case {params["token"], Map.get(ctx, :token_secret)} do
      {token, secret} when is_binary(token) and is_binary(secret) ->
        case Token.verify(secret, ref, token) do
          {:ok, user_ref} -> {:ok, user_ref}
          {:error, _reason} -> {:error, 401, %{"error" => "unauthorized"}}
        end

      _ ->
        case TelegramAuth.verify(params["init_data"], ctx.bot_token, ctx.max_age_s) do
          {:ok, %{user_id: user_id}} ->
            {:ok, ctx.user_ref_fn.(user_id)}

          {:error, _reason} ->
            # deliberately reason-blind to the caller; never echoes the payload
            {:error, 401, %{"error" => "unauthorized"}}
        end
    end
  end

  defp pin_version(params, %{pinned: %{version: version}}) when is_binary(version) do
    if params["v"] == version,
      do: :ok,
      else: {:error, 409, %{"error" => "version mismatch"}}
  end

  defp pin_version(_params, _ctx), do: :ok

  defp wallet_view(ctx, user_ref) do
    case Map.get(ctx, :wallet_view_fn) do
      fun when is_function(fun, 1) -> fun.(user_ref)
      _ -> nil
    end
  end

  defp expired_user_tx?(%{kind: "user_tx", expires_at: exp}), do: System.os_time(:second) > exp
  defp expired_user_tx?(_view), do: false

  defp fetch_fn(ctx, key, arity) do
    case Map.get(ctx, key) do
      fun when is_function(fun, arity) -> {:ok, fun}
      _ -> {:error, 503, %{"error" => "unavailable"}}
    end
  end

  defp fetch_kind(ctx, ref, user_ref, kind) do
    case Keeper.fetch_order_full(ctx.keeper, ref, user_ref) do
      {:error, :not_found} ->
        {:error, 404, %{"error" => "not found"}}

      {:ok, %{kind: ^kind} = order} ->
        if System.os_time(:second) > order.expires_at,
          do: {:error, 410, %{"error" => "expired"}},
          else: {:ok, order}

      {:ok, _wrong_kind} ->
        {:error, 422, %{"error" => "invalid", "field" => "kind"}}
    end
  end

  defp consume(ctx, order, user_ref) do
    case Keeper.consume_order(ctx.keeper, order.order_id, user_ref) do
      {:ok, order} -> {:ok, order}
      :already_consumed -> {:error, 410, %{"error" => "expired"}}
      :not_found -> {:error, 404, %{"error" => "not found"}}
    end
  end

  defp checksum_address(addr) when is_binary(addr) do
    bytes = DelegatedSpend.Evm.Address.to_bytes(String.trim(addr))

    if byte_size(bytes) == 20 and bytes != <<0::160>>,
      do: {:ok, DelegatedSpend.Evm.Address.checksum(bytes)},
      else: {:error, 422, %{"error" => "invalid", "field" => "address"}}
  rescue
    _ -> {:error, 422, %{"error" => "invalid", "field" => "address"}}
  end

  defp checksum_address(_), do: {:error, 422, %{"error" => "invalid", "field" => "address"}}

  defp tx_hash("0x" <> hex = h) when byte_size(hex) == 64 do
    if Regex.match?(~r/^[0-9a-fA-F]+$/, hex),
      do: {:ok, h},
      else: {:error, 422, %{"error" => "invalid", "field" => "tx_hash"}}
  end

  defp tx_hash(_), do: {:error, 422, %{"error" => "invalid", "field" => "tx_hash"}}

  # rescue alone misses exits — and a dead persistence GenServer EXITS the
  # caller rather than raising, so both callback shields need catch too.
  defp safe_submitted(fun, order_id, tx_hash) do
    fun.(order_id, tx_hash)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_wallet(fun, user_ref, address, bind_ref) do
    fun.(user_ref, address, bind_ref)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp allow(%{rate: {limiter, max}}, user_ref) do
    if Rate.allow?(limiter, user_ref, max),
      do: :ok,
      else: {:error, 429, %{"error" => "rate limited"}}
  end

  defp allow(_ctx, _user_ref), do: :ok
end

defmodule DelegatedSpend.Intake.Rate do
  @moduledoc "Minimal per-user_ref fixed-window rate limiter (Agent)."

  def start(window_s \\ 60) do
    {:ok, pid} = start_link(window_s)
    pid
  end

  @doc """
  Supervision-friendly variant: returns `{:ok, pid}` and accepts `name:` so a
  restarted limiter stays reachable at the same name (an app passing the name
  in its intake ctx never holds a stale pid).
  """
  def start_link(window_s \\ 60, opts \\ []) do
    agent_opts = if opts[:name], do: [name: opts[:name]], else: []
    Agent.start_link(fn -> %{window_s: window_s, buckets: %{}} end, agent_opts)
  end

  def allow?(pid, key, max, now_s \\ System.os_time(:second)) do
    Agent.get_and_update(pid, fn s ->
      win = div(now_s, s.window_s)

      {count, buckets} =
        case s.buckets[key] do
          {^win, c} -> {c, s.buckets}
          _ -> {0, Map.put(s.buckets, key, {win, 0})}
        end

      if count < max do
        {true, %{s | buckets: Map.put(buckets, key, {win, count + 1})}}
      else
        {false, %{s | buckets: buckets}}
      end
    end)
  end
end
