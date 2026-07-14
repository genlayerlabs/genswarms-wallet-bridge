defmodule DelegatedSpend.Keeper do
  @moduledoc """
  The keeper core (spec §5.2) — grant/order registry + intent execution +
  typed results, over the Plan-2 Signer. Permit lane only in M1; the grant
  registry stores delegation grants but no redemption path exists until M2.

  Authority model:
    * `register_order(keeper, source, …)` — `source` is the TRUSTED runtime
      envelope sender supplied by the transport glue, never anything inside
      the payload; it is checked against the configured allowlist. Any
      `source`-shaped field inside the order args is inert data.
    * Orders are server-authoritative and immutable: calldata is built solely
      from the stored order; the client's only contributions are the order
      ref (routing) and the permit signature (authorization).
    * The permit must cover EXACTLY the order amount.
    * TTL is checked immediately before broadcast (spec §5.2); expiry is a
      typed failure that consumes nothing and costs nothing.

  Results are durably re-queryable via `order_status/2`. `result_fn` is a
  best-effort technical-status notification invoked once after a new terminal
  result is stored; it is never product-credit authority. `{:mined, tx_hash}`
  means one successful receipt, not confirmation depth or product credit.

  Typed failure reasons: `no_grant | expired | reverted | rpc_timeout |
  not_found | suspended`. `suspended` is the §5.2.1 revert backoff — a grant
  that produced `max_consecutive_reverts` reverts is frozen until
  `reset_backoff/2` (the wallet dapp re-enable).
  """
  use GenServer
  require Logger

  alias DelegatedSpend.Keeper.{PermitLane, Signer}

  # :chain_id is REQUIRED (0.3.1): every order view carries the keeper's
  # runtime chain id so the wallet dapp can refuse to run against a stale
  # static config.json (config drift = wrong-network fund-loss class). A
  # keeper that doesn't know its chain must not serve orders at all.
  @enforce_opts [:store, :source_allowlist, :order_ttl_s, :chain_id]
  @max_json_safe_integer 9_007_199_254_740_991

  # Optional :name registers the server (supervision-friendly: a restarted
  # keeper is reachable at the same name, so app ctx never holds a stale pid).
  def start_link(opts) do
    opts = Map.new(opts)
    Enum.each(@enforce_opts, &Map.fetch!(opts, &1))

    case Map.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def register_order(keeper, source, order_req),
    do: GenServer.call(keeper, {:register_order, source, order_req})

  def fetch_order(keeper, order_ref, user_ref),
    do: GenServer.call(keeper, {:fetch_order, order_ref, user_ref})

  def fetch_order_full(keeper, order_ref, user_ref),
    do: GenServer.call(keeper, {:fetch_order_full, order_ref, user_ref})

  def consume_order(keeper, order_id, user_ref),
    do: GenServer.call(keeper, {:consume_order, order_id, user_ref})

  def execute_with_permit(keeper, order_ref, user_ref, permit),
    do: GenServer.call(keeper, {:execute, order_ref, user_ref, permit}, 60_000)

  def order_status(keeper, order_id), do: GenServer.call(keeper, {:order_status, order_id})

  @doc "Clear a suspended grant's revert backoff (the wallet dapp re-enable path)."
  def reset_backoff(keeper, user_ref), do: GenServer.call(keeper, {:reset_backoff, user_ref})

  @doc "Current consecutive-revert count for a user_ref (advisory / monitoring)."
  def backoff_count(keeper, user_ref), do: GenServer.call(keeper, {:backoff_count, user_ref})

  @doc "Deliver late results for work in flight when the keeper last stopped."
  def reconcile_boot(keeper), do: GenServer.call(keeper, :reconcile_boot, 60_000)

  def sweep_now(keeper), do: GenServer.call(keeper, :sweep_now, 60_000)

  @impl true
  def init(opts) do
    state = %{
      signer: Map.get(opts, :signer),
      # The RUNTIME chain id (the app derives it from its RPC at boot). Not a
      # per-order field: order views stamp it at FETCH time, so orders
      # persisted before an upgrade still report the chain the keeper serves.
      chain_id: opts.chain_id,
      store: opts.store,
      router: Map.get(opts, :router),
      action: Map.get(opts, :action),
      allowlist: MapSet.new(opts.source_allowlist),
      order_ttl_s: opts.order_ttl_s,
      # Fail-closed owner binding: when true, an order WITHOUT an
      # `expected_owner` is refused rather than executed. Apps whose credit
      # machinery scans wallet-on-file-derived addresses set this so a
      # persistence bug that drops the binding can never fail OPEN into a
      # mismatched-wallet spend.
      require_owner_binding: Map.get(opts, :require_owner_binding, false),
      # Minimum permit-deadline slack (seconds) beyond the current chain time,
      # checked before broadcast: a permit that passes simulation now but
      # would revert once mined (deadline in the next block) is a gas-grief
      # vector against the sponsor. 0 disables the check.
      min_deadline_slack_s: Map.get(opts, :min_deadline_slack_s, 0),
      # Per-user_ref revert backoff (spec §5.2.1). 0 disables. After this many
      # CONSECUTIVE reverts the grant is suspended until reset_backoff/2. A
      # mined spend resets the counter.
      max_reverts: Map.get(opts, :max_consecutive_reverts, 0),
      reverts: %{},
      result_fn: Map.get(opts, :result_fn, fn _ -> :ok end),
      rpc_mod: Map.get(opts, :rpc_mod),
      rpc: Map.get(opts, :rpc),
      sweep_ms: Map.get(opts, :sweep_ms, 5_000)
    }

    Process.send_after(self(), :sweep, state.sweep_ms)

    # Supervision-friendly: a supervisor can't easily run the reconcile_boot
    # call after every (re)start, so the keeper can do it itself — first
    # message in its own mailbox, before any order traffic it serves.
    if Map.get(opts, :reconcile_on_init, false), do: send(self(), :reconcile_boot)

    {:ok, state}
  end

  @impl true
  def handle_call({:register_order, source, req}, _from, state) do
    with true <- MapSet.member?(state.allowlist, source) || {:error, {:unknown_source, source}},
         %{user_ref: user_ref, amount: amount, action_args: args} = req,
         {:ok, kind} <- order_kind(req),
         {:ok, order_ref} <- order_ref(state, req, user_ref) do
      order = %{
        order_id: "0x" <> hex(:crypto.strong_rand_bytes(32)),
        order_ref: order_ref,
        user_ref: user_ref,
        amount: amount,
        action_args: args,
        kind: kind,
        tx: Map.get(req, :tx),
        display: Map.get(req, :display, %{}),
        # Optional binding: when set, only a permit signed by exactly this
        # wallet can execute the order (apps whose credit machinery scans
        # addresses derived from a wallet-on-file NEED this — set it to
        # that wallet).
        expected_owner: Map.get(req, :expected_owner),
        expires_at: now_s() + order_ttl(req, state)
      }

      :ok = store(state).put_order(store_ref(state), order)

      {:reply, {:ok, Map.take(order, [:order_id, :order_ref, :expires_at, :amount])}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch_order, order_ref, user_ref}, _from, state) do
    case store(state).get_order_by_ref(store_ref(state), order_ref, user_ref) do
      nil ->
        {:reply, {:error, :not_found}, state}

      order ->
        {:reply, {:ok, order_view(order, state)}, state}
    end
  end

  def handle_call({:fetch_order_full, order_ref, user_ref}, _from, state) do
    case store(state).get_order_by_ref(store_ref(state), order_ref, user_ref) do
      nil -> {:reply, {:error, :not_found}, state}
      order -> {:reply, {:ok, order}, state}
    end
  end

  def handle_call({:consume_order, order_id, user_ref}, _from, state) do
    {:reply, store(state).consume_order(store_ref(state), order_id, user_ref), state}
  end

  def handle_call({:execute, order_ref, user_ref, permit}, _from, state) do
    case store(state).get_order_by_ref(store_ref(state), order_ref, user_ref) do
      nil ->
        {:reply, {:failed, :not_found}, state}

      order ->
        case store(state).get_execution_status(store_ref(state), order.order_id) do
          :unknown ->
            cond do
              Map.get(order, :kind, "permit") != "permit" ->
                {:reply, {:failed, :wrong_kind}, state}

              is_nil(state.signer) ->
                {:reply, {:failed, :permit_lane_disabled}, state}

              # Anti-griefing (spec §5.2.1): a grant that has produced N consecutive
              # reverts is suspended until the user re-enables it via the wallet dapp
              # (reset_backoff/2). Bounds a griefer who keeps triggering reverting
              # spends against the gas sponsor. Checked BEFORE consuming the order.
              suspended?(order.user_ref, state) ->
                {:reply, {:failed, :suspended}, state}

              now_s() > order.expires_at ->
                {:reply, {:failed, :expired}, state}

              permit.value != order.amount ->
                {:reply, {:failed, :no_grant}, state}

              not owner_binding_ok?(order, permit, state) ->
                {:reply, {:failed, :no_grant}, state}

              not deadline_slack_ok?(permit, state) ->
                {:reply, {:failed, :expired}, state}

              true ->
                execute_consumed(order, permit, state)
            end

          status ->
            {:reply, status, state}
        end
    end
  end

  def handle_call({:reset_backoff, user_ref}, _from, state) do
    {:reply, :ok, %{state | reverts: Map.delete(state.reverts, user_ref)}}
  end

  def handle_call({:backoff_count, user_ref}, _from, state) do
    {:reply, Map.get(state.reverts, user_ref, 0), state}
  end

  def handle_call({:order_status, order_id}, _from, state) do
    {:reply, store(state).get_execution_status(store_ref(state), order_id), state}
  end

  def handle_call(:sweep_now, _from, state), do: {:reply, :ok, do_sweep(state)}

  def handle_call(:reconcile_boot, _from, state) do
    {:reply, :ok, do_reconcile(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, state.sweep_ms)
    {:noreply, do_sweep(state)}
  end

  def handle_info(:reconcile_boot, state), do: {:noreply, do_reconcile(state)}

  def handle_info(_other, state), do: {:noreply, state}

  # Spec §5.3: complete result delivery for txs that mined while the keeper
  # was down — but ONLY settle on a DEFINITIVE on-chain receipt. A row with
  # no hash yet, or a hash with no receipt, is left in place (still pending):
  # marking it failed here would falsely tell the app a payment did not
  # happen while the tx is still mineable, risking a double payment via the
  # fallback lane. Every initial and same-nonce replacement hash is written
  # before broadcast, so reconciliation remains complete across restarts.
  defp do_reconcile(state) do
    Enum.reduce(store(state).list_inflight(store_ref(state)), state, fn row, acc ->
      case durable_receipt(acc, row.tx_hashes) do
        {:mined, hash} -> settle(acc, row.order_id, {:mined, hash})
        {:failed, _hash} -> settle(acc, row.order_id, {:failed, :reverted})
        nil -> acc
      end
    end)
  end

  defp durable_receipt(state, hashes) do
    Enum.find_value(hashes, fn hash ->
      case receipt(state, hash) do
        %{"status" => "0x1"} -> {:mined, hash}
        %{"status" => "0x0"} -> {:failed, hash}
        _ -> nil
      end
    end)
  end

  defp receipt(%{rpc_mod: mod} = state, hash) when not is_nil(mod),
    do: safe_receipt(mod, state.rpc, hash)

  defp receipt(%{signer: signer}, hash) when not is_nil(signer),
    do: safe_signer_receipt(signer, hash)

  defp receipt(_state, _hash), do: nil

  # ── execution ─────────────────────────────────────────────────────────────

  defp execute_consumed(order, permit, state) do
    case store(state).begin_execution(
           store_ref(state),
           order.order_id,
           order.user_ref,
           order.order_id
         ) do
      :not_found ->
        {:reply, {:failed, :not_found}, state}

      :already_consumed ->
        {:reply, store(state).get_execution_status(store_ref(state), order.order_id), state}

      {:ok, order} ->
        calldata = PermitLane.build_call(state.action, order.action_args, permit)

        persist_hash_fn = fn hash ->
          store(state).update_inflight_hash(store_ref(state), order.order_id, hash)
        end

        case Signer.submit(
               state.signer,
               order.order_id,
               %{to: state.router, data: calldata},
               persist_hash_fn
             ) do
          {:ok, hash} ->
            {:reply, {:submitted, hash}, state}

          {:error, {:reverted, _info}} ->
            {:reply, {:failed, :reverted}, settle(state, order.order_id, {:failed, :reverted})}

          {:error, _reason} ->
            {:reply, {:failed, :rpc_timeout},
             settle(state, order.order_id, {:failed, :rpc_timeout})}
        end
    end
  end

  # ── result delivery ───────────────────────────────────────────────────────

  defp do_sweep(state) do
    state = if is_nil(state.signer), do: state, else: do_sweep_with_signer(state)
    do_reconcile(state)
  end

  defp do_sweep_with_signer(state) do
    Enum.reduce(store(state).list_inflight(store_ref(state)), state, fn row, acc ->
      case safe_signer_status(acc.signer, row.action_key) do
        {:mined, hash} -> settle(acc, row.order_id, {:mined, hash})
        {:failed, _hash} -> settle(acc, row.order_id, {:failed, :reverted})
        _ -> acc
      end
    end)
  end

  defp settle(state, order_id, result) do
    case store(state).resolve_inflight(store_ref(state), order_id, result, now_s()) do
      :new ->
        state =
          update_backoff(state, store(state).get_order(store_ref(state), order_id), result)

        notify_result(state.result_fn, order_id, result)
        state

      :existing ->
        state
    end
  end

  defp notify_result(result_fn, order_id, result) do
    result_fn.({order_id, result})
  rescue
    error ->
      Logger.error(
        "result_fn failed order_id=#{order_id} status=#{inspect(result)} error=#{Exception.message(error)}"
      )
  catch
    kind, reason ->
      Logger.error(
        "result_fn failed order_id=#{order_id} status=#{inspect(result)} #{kind}=#{inspect(reason)}"
      )
  end

  # A mined result clears the user's revert streak; a revert increments it. Other
  # terminal outcomes (rpc_timeout) neither punish nor clear — they aren't the
  # griefing signal and shouldn't erase an accumulating streak.
  defp update_backoff(state, order, _result) when not is_map(order), do: state
  defp update_backoff(%{max_reverts: 0} = state, _order, _result), do: state

  defp update_backoff(state, %{user_ref: user_ref}, {:mined, _}),
    do: %{state | reverts: Map.delete(state.reverts, user_ref)}

  defp update_backoff(state, %{user_ref: user_ref}, {:failed, :reverted}),
    do: %{state | reverts: Map.update(state.reverts, user_ref, 1, &(&1 + 1))}

  defp update_backoff(state, _order, _result), do: state

  defp suspended?(_user_ref, %{max_reverts: 0}), do: false

  defp suspended?(user_ref, state),
    do: Map.get(state.reverts, user_ref, 0) >= state.max_reverts

  defp order_kind(req) do
    case Map.get(req, :kind, "permit") do
      "permit" ->
        {:ok, "permit"}

      "bind" ->
        {:ok, "bind"}

      "user_tx" ->
        case Map.get(req, :tx) do
          %{to: to, data: data, value: value}
          when is_binary(to) and is_binary(data) and is_integer(value) and value >= 0 and
                 value <= @max_json_safe_integer ->
            {:ok, "user_tx"}

          _ ->
            {:error, :bad_tx}
        end

      _ ->
        {:error, :bad_kind}
    end
  end

  defp order_ttl(req, state) do
    case Map.get(req, :ttl_s) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> state.order_ttl_s
    end
  end

  defp order_view(order, state) do
    base =
      order
      |> Map.take([:order_ref, :amount, :expires_at])
      |> Map.merge(%{
        kind: Map.get(order, :kind, "permit"),
        display: Map.get(order, :display, %{}),
        # The RUNTIME chain id, on EVERY view (unlike expected_owner it is
        # never conditional): the dapp compares it against its static
        # config.json and fails CLOSED on mismatch — a deployed config that
        # lags an RPC_URL move would otherwise enforce the stale chain and
        # let a server-built transfer succeed on the wrong network to an
        # unwatched address.
        chain_id: state.chain_id
      })

    # An owner binding is part of the payer-facing contract — the wallet the
    # user must pay from, not a secret — so the dapp can refuse a mismatched
    # connected account BEFORE anything is signed. Exposed only when set, so
    # unbound views keep their exact sanitized shape.
    base =
      case Map.get(order, :expected_owner) do
        nil -> base
        owner -> Map.put(base, :expected_owner, owner)
      end

    if base.kind == "user_tx", do: Map.put(base, :tx, order.tx), else: base
  end

  # Fail CLOSED when the app requires a binding but the loaded order has none
  # (e.g. a storage layer silently dropped `expected_owner`). Otherwise: set →
  # must match; unset → open (generic keeper / delegation lane).
  defp owner_binding_ok?(order, permit, state) do
    case Map.get(order, :expected_owner) do
      nil -> not state.require_owner_binding
      expected -> String.downcase(expected) == String.downcase(permit.owner)
    end
  end

  # Reject a permit whose deadline is too close to now to survive being mined
  # — it would pass simulation at `latest` yet revert on-chain, burning
  # sponsor gas. Uses chain time when an RPC is wired, else wall clock.
  defp deadline_slack_ok?(_permit, %{min_deadline_slack_s: 0}), do: true

  defp deadline_slack_ok?(permit, state) do
    now = chain_now(state)
    is_integer(permit.deadline) and permit.deadline >= now + state.min_deadline_slack_s
  end

  defp chain_now(%{rpc_mod: mod, rpc: rpc}) when not is_nil(mod) do
    mod.block_timestamp(rpc)
  rescue
    _ -> now_s()
  end

  defp chain_now(_state), do: now_s()

  # A raising receipt at boot (transient RPC) must not crash reconciliation —
  # leave the order pending; the run-time sweep retries.
  defp safe_receipt(mod, rpc, hash) do
    mod.receipt(rpc, hash)
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp safe_signer_receipt(signer, hash) do
    Signer.receipt(signer, hash)
  catch
    _kind, _reason -> nil
  end

  defp safe_signer_status(signer, action_key) do
    Signer.status(signer, action_key)
  catch
    _kind, _reason -> :unknown
  end

  # The order ref (the routing token the wallet dapp URL carries). Server-minted
  # by default; a CALLER-MINTED ref is accepted for the async object door
  # (which has no synchronous return channel to hand a minted ref back
  # through). A caller-minted ref must look exactly like a server-minted one
  # (64 lowercase hex chars — unguessable) and must not shadow an existing
  # order for the same user_ref (put_order would remap the by-ref lookup,
  # stranding the original order's URL).
  defp order_ref(state, req, user_ref) do
    case Map.get(req, :order_ref) do
      nil ->
        {:ok, hex(:crypto.strong_rand_bytes(32))}

      ref when is_binary(ref) ->
        cond do
          not Regex.match?(~r/^[0-9a-f]{64}$/, ref) ->
            {:error, :bad_order_ref}

          store(state).get_order_by_ref(store_ref(state), ref, user_ref) != nil ->
            {:error, :duplicate_order_ref}

          true ->
            {:ok, ref}
        end

      _other ->
        {:error, :bad_order_ref}
    end
  end

  defp store(%{store: {mod, _ref}}), do: mod
  defp store_ref(%{store: {_mod, ref}}), do: ref
  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp now_s, do: System.os_time(:second)
end
