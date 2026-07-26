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
  not_found | suspended | wrong_kind | permit_lane_disabled`, plus
  `authorization_lane_disabled | not_yet_valid` on the EIP-3009 lane.
  `suspended` is the §5.2.1 revert backoff — a grant that produced
  `max_consecutive_reverts` reverts is frozen until `reset_backoff/2` (the
  wallet dapp re-enable).
  """
  use GenServer
  require Logger

  alias DelegatedSpend.Evm.Address
  alias DelegatedSpend.Keeper.{PermitLane, Signer}

  # :chain_id is REQUIRED (0.3.1): every order view carries the keeper's
  # runtime chain id so the wallet dapp can refuse to run against a stale
  # static config.json (config drift = wrong-network fund-loss class). A
  # keeper that doesn't know its chain must not serve orders at all.
  @enforce_opts [:store, :source_allowlist, :order_ttl_s, :chain_id]
  @max_json_safe_integer 9_007_199_254_740_991
  @uint256_max Integer.pow(2, 256) - 1

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

  @doc """
  The EIP-3009 sibling of `execute_with_permit/4`. `auth` is
  `%{from:, value:, valid_after:, valid_before:, signature:}` — note there is
  no `to`: the destination is the keeper's own `:treasury_address`, never a
  client-supplied field (see `execute_authorization_consumed/3`).
  """
  def execute_with_authorization(keeper, order_ref, user_ref, auth),
    do: GenServer.call(keeper, {:execute_authorization, order_ref, user_ref, auth}, 60_000)

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
    # Authorization lane config (EIP-3009). Normalized ONCE, here: the lane is
    # enabled iff `:signer`, `:token_address` and `:treasury_address` are ALL
    # configured; a partial configuration refuses boot (see
    # `authorization_enabled?/1`). Everything downstream reads the single
    # boolean, so no execution path can ever discover a missing key halfway
    # through and crash with an order already consumed.
    token_address = Map.get(opts, :token_address)
    treasury_address = Map.get(opts, :treasury_address)
    authorization_enabled? = authorization_enabled?(opts)

    # DOMAIN_SEPARATOR() = 0x3644e515. READ, never recomposed: a wrongly
    # composed domain produces signatures the chain rejects without saying
    # why (mirrors the Eip3009 moduledoc). Failing boot here is correct — with
    # no domain no signature can ever be validated on-chain, and booting
    # without it would only move the failure to the first paying user.
    domain_separator =
      case token_address do
        nil ->
          nil

        addr ->
          read_domain_separator(Map.fetch!(opts, :rpc_mod), Map.fetch!(opts, :rpc), addr)
      end

    state = %{
      signer: Map.get(opts, :signer),
      token_address: token_address,
      treasury_address: treasury_address,
      domain_separator: domain_separator,
      authorization_enabled?: authorization_enabled?,
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

              not owner_binding_ok?(order, permit.owner, state) ->
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

  # The EIP-3009 sibling of {:execute, ...} — same shape (order lookup →
  # execution-status idempotency door → typed-failure cond → consume+submit),
  # with two differences from the permit path: the expected kind is
  # "authorization", and the AUTHORIZATION'S OWN validity window (valid_after/
  # valid_before) is checked in addition to the order's own expiry — a
  # transferWithAuthorization the token contract itself will reject on-chain
  # once validBefore passes, so that check is mandatory here, not an optional
  # anti-grief slack like the permit lane's deadline check.
  def handle_call({:execute_authorization, order_ref, user_ref, auth}, _from, state) do
    case store(state).get_order_by_ref(store_ref(state), order_ref, user_ref) do
      nil ->
        {:reply, {:failed, :not_found}, state}

      order ->
        case store(state).get_execution_status(store_ref(state), order.order_id) do
          :unknown ->
            cond do
              Map.get(order, :kind, "permit") != "authorization" ->
                {:reply, {:failed, :wrong_kind}, state}

              # ONE normalized predicate, computed at boot (see
              # `authorization_enabled?/1`): by the time we're here the lane is
              # either fully configured or the keeper never booted.
              not state.authorization_enabled? ->
                {:reply, {:failed, :authorization_lane_disabled}, state}

              # Same anti-griefing backoff as the permit lane (spec §5.2.1) —
              # one revert streak per user_ref, shared across both lanes.
              suspended?(order.user_ref, state) ->
                {:reply, {:failed, :suspended}, state}

              now_s() > order.expires_at ->
                {:reply, {:failed, :expired}, state}

              # Shape/type check BEFORE any field is compared or encoded:
              # nothing about `auth` is trusted, and a malformed field must be
              # a typed refusal, never a crash — the §5.2.1 revert backoff
              # lives only in this process's memory, so a crash is a free
              # suspension reset for a griefer.
              not valid_authorization_fields?(auth) ->
                {:reply, {:failed, :no_grant}, state}

              auth.value != order.amount ->
                {:reply, {:failed, :no_grant}, state}

              # The SAME fail-closed owner binding the permit lane enforces
              # (shared helper, so the two lanes can't drift): an app that
              # opted into "only this wallet may pay" must not lose that
              # guarantee by an order taking the other lane.
              not owner_binding_ok?(order, auth.from, state) ->
                {:reply, {:failed, :no_grant}, state}

              true ->
                # The two validity-window checks share ONE chain-time read:
                # two `eth_getBlockByNumber` round-trips per payment is both
                # wasteful and incoherent (the guards could observe different
                # timestamps). Evaluated last so the cheap refusals above
                # never pay for an RPC call.
                case authorization_window(auth, state) do
                  :ok -> execute_authorization_consumed(order, auth, state)
                  reason -> {:reply, {:failed, reason}, state}
                end
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

  # The authorization lane needs THREE things to move money: a signer to
  # broadcast, a token to call, and a treasury to credit. Half of them is not a
  # runtime condition, it is a broken DEPLOY — and one that is expensive to
  # discover late: a keeper that reports the lane enabled and then raises
  # mid-execution can leave an order durably `:pending` with no tx hash, which
  # adoption.md forbids ever resubmitting. So it fails at boot, exactly like the
  # DOMAIN_SEPARATOR read below.
  #
  # `:signer` ALONE is not a request for this lane — that's the permit-only
  # deployment every M1 keeper runs — so the lane is only "asked for" once one
  # of its own two address keys appears. Neither key = lane cleanly disabled,
  # no new boot cost, no new failure mode.
  defp authorization_enabled?(opts) do
    configured = [
      signer: Map.get(opts, :signer),
      token_address: Map.get(opts, :token_address),
      treasury_address: Map.get(opts, :treasury_address)
    ]

    requested? =
      not (is_nil(configured[:token_address]) and is_nil(configured[:treasury_address]))

    missing = for {key, nil} <- configured, do: key

    cond do
      not requested? ->
        false

      missing != [] ->
        raise ArgumentError,
              "keeper: authorization lane is half-configured — missing " <>
                Enum.map_join(missing, ", ", &inspect/1) <>
                ". Configure all of :signer, :token_address and :treasury_address, " <>
                "or none of :token_address/:treasury_address for a permit-only deployment."

      true ->
        validate_authorization_address!(:treasury_address, configured[:treasury_address])
        validate_authorization_address!(:token_address, configured[:token_address])
        true
    end
  end

  # R1 (re-review): presence is not shape. `Address.to_bytes/1` has a raw
  # `<<_::binary-size(20)>>` pass-through clause, so a config value that is
  # merely *20 characters long* — a truncated paste, e.g. a copy that lost
  # its tail — is silently accepted and used AS THE RAW ADDRESS BYTES,
  # ASCII and all: a deploy-time typo becomes an unrecoverable destination,
  # discovered only after real funds move. Reusing `address?/1` (0x + 40 hex,
  # the same predicate that already guards `auth.from` at execution time)
  # catches this at boot, before any order can be consumed.
  defp validate_authorization_address!(key, value) do
    unless address?(value) do
      raise ArgumentError,
            "keeper: authorization lane #{inspect(key)} is not a well-formed address " <>
              "(expected \"0x\" + 40 hex chars), got: #{inspect(value)}"
    end
  end

  # `Rpc.eth_call/3` (the plain, no-`from` view-call wrapper — unused so far
  # elsewhere, since `eth_call_from/4` is what the Signer's simulation needs)
  # either returns the raw `"0x…"` result or RAISES on transport failure
  # (`call!` underneath). We only add our own message for the shape-mismatch
  # case: a call that "succeeded" but didn't return a 32-byte word is not a
  # transport error, it's a wrong contract/network, and deserves its own
  # diagnosis rather than a generic rpc-failed message.
  defp read_domain_separator(rpc_mod, rpc, token_address) do
    case rpc_mod.eth_call(rpc, token_address, "0x3644e515") do
      "0x" <> hex when byte_size(hex) == 64 ->
        Base.decode16!(hex, case: :mixed)

      other ->
        raise "keeper: could not read DOMAIN_SEPARATOR from token #{String.downcase(token_address)}: #{inspect(other)}"
    end
  end

  # ── execution ─────────────────────────────────────────────────────────────

  defp execute_consumed(order, permit, state) do
    calldata = PermitLane.build_call(state.action, order.action_args, permit)
    submit_consumed(order, %{to: state.router, data: calldata}, state)
  end

  # The destination is picked by the SERVER, from `:treasury_address` —
  # NEVER from `auth`. A `to` that arrives from outside is a `to` an attacker
  # chooses; this keeper's whole authority model (see moduledoc) rests on
  # calldata being built solely from server-held config/state, never from
  # client-supplied routing.
  defp execute_authorization_consumed(order, auth, state) do
    nonce = DelegatedSpend.Orders.authorization_nonce(order.order_ref)

    calldata_hex =
      DelegatedSpend.Keeper.Eip3009.transfer_with_authorization_calldata(
        auth.from,
        state.treasury_address,
        auth.value,
        auth.valid_after,
        auth.valid_before,
        nonce,
        auth.signature
      )

    # Eip3009 returns calldata as "0x…" text (shaped for an external
    # consumer, e.g. an HTTP response), but the Signer — like
    # PermitLane.build_call above — expects `tx.data` as RAW bytes: Tx1559
    # signs over the actual byte string, not its hex spelling. Decode at this
    # boundary between the two conventions.
    # `replace_prefix/3`, not `trim_leading/2`: the latter strips EVERY leading
    # occurrence ("0x0x12" -> "12"), which is never the intent for a prefix.
    data = calldata_hex |> String.replace_prefix("0x", "") |> Base.decode16!(case: :mixed)

    submit_consumed(order, %{to: state.token_address, data: data, value: 0}, state)
  end

  # Shared by both lanes: consume the order + open its durable :pending
  # execution record + hand the built tx to the Signer. Extracted so permit
  # and authorization can never diverge on idempotency handling — the
  # `action_key` (the order_id) is what makes a retry return the recorded
  # result instead of broadcasting again (signer.ex, "action_key
  # idempotency").
  defp submit_consumed(order, tx, state) do
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
        persist_hash_fn = fn hash ->
          store(state).update_inflight_hash(store_ref(state), order.order_id, hash)
        end

        case Signer.submit(state.signer, order.order_id, tx, persist_hash_fn) do
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

      # The EIP-3009 lane's kind. Registrable like "permit": the order carries
      # no routing payload of its own — the destination is the keeper's own
      # treasury — so there is nothing extra to validate here.
      "authorization" ->
        {:ok, "authorization"}

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
  # `owner` is the address that signed the payment authorization: the permit's
  # `owner` on the permit lane, the authorization's `from` on the EIP-3009 one.
  # Deliberately ONE function for both — a duplicated security control is a
  # control that eventually diverges.
  defp owner_binding_ok?(order, owner, state) do
    case Map.get(order, :expected_owner) do
      nil -> not state.require_owner_binding
      expected -> Address.eq?(expected, owner)
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

  # Nothing in `auth` is server-authoritative — it is the payload a client
  # hands us — so every field is type-checked before it is compared, encoded
  # or handed to the Signer. Mirrors the permit lane's `is_integer(deadline)`
  # guard, generalized: Elixir's total term ordering makes ANY binary greater
  # than ANY integer, so an unguarded `valid_before > now` comparison lets a
  # string sail through the expiry gate and get ABI-encoded into a uint256
  # slot as garbage (which then reverts on-chain, on the sponsor's gas, and
  # advances the payer's revert backoff).
  defp valid_authorization_fields?(auth) when is_map(auth) do
    value = Map.get(auth, :value)
    valid_after = Map.get(auth, :valid_after)
    valid_before = Map.get(auth, :valid_before)
    signature = Map.get(auth, :signature)

    is_integer(value) and value > 0 and value <= @uint256_max and
      is_integer(valid_after) and valid_after >= 0 and valid_after <= @uint256_max and
      is_integer(valid_before) and valid_before >= 0 and valid_before <= @uint256_max and
      is_binary(signature) and byte_size(signature) > 0 and
      address?(Map.get(auth, :from))
  end

  defp valid_authorization_fields?(_auth), do: false

  # Defensive address validation at the trust boundary, in the same shape
  # `DelegatedSpend.Orders.validate_address!/2` uses for the order-building
  # side — as a PREDICATE, because here a malformed address must produce a
  # typed refusal, not an exception: `Address.to_bytes/1` (via
  # `Base.decode16!/2`) raises deep inside calldata construction otherwise.
  # The zero address is rejected too: it is never a payer.
  defp address?("0x" <> hex) when byte_size(hex) == 40 do
    body = String.downcase(hex)
    Regex.match?(~r/^[0-9a-f]{40}$/, body) and body != String.duplicate("0", 40)
  end

  defp address?(_other), do: false

  # Unlike `deadline_slack_ok?/2`, there is no "0 disables the check" escape
  # hatch here: `valid_before` is not an optional grief-prevention margin, it
  # is the EIP-3009 authorization's OWN on-chain validity boundary — the
  # token contract rejects the transfer once it passes, full stop.
  # `:min_deadline_slack_s` only widens that mandatory margin when set.
  #
  # Both bounds are checked against ONE chain-time read. `valid_after` is
  # STRICT (`valid_after >= now` refuses): EIP-3009 requires
  # `block.timestamp > validAfter`, so an authorization whose `validAfter`
  # equals the current block time still reverts on-chain — accepting it would
  # only burn sponsor gas and advance the payer's revert backoff.
  defp authorization_window(auth, state) do
    now = chain_now(state)

    cond do
      auth.valid_before <= now + state.min_deadline_slack_s -> :expired
      auth.valid_after >= now -> :not_yet_valid
      true -> :ok
    end
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
