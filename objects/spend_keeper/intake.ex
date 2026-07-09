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
    * A version mismatch (stale Mini App build) is rejected at runtime (409).
    * `initData` never appears in logs or errors.

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
          {200,
           %{
             "order_ref" => view.order_ref,
             "amount" => view.amount,
             "expires_at" => view.expires_at
           }}

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
            {:submitted, hash} -> {200, %{"status" => "submitted", "tx" => hash}}
            {:credited, hash} -> {200, %{"status" => "credited", "tx" => hash}}
            {:failed, :not_found} -> {404, %{"error" => "not found"}}
            {:failed, reason} -> {422, %{"status" => "failed", "reason" => to_string(reason)}}
            :unknown -> {404, %{"error" => "not found"}}
          end
      end
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
