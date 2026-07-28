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
  `authorization_lane_disabled | not_yet_valid` on the EIP-3009 lane, plus
  `below_minimum` on both authorization lanes. Sponsored authorization also
  applies the sponsor-only `gas_too_expensive | budget_exhausted` brakes
  through `GasPolicy.admit/2` — see `gas_policy_admit/2`.
  `suspended` is the §5.2.1 revert backoff — a grant that produced
  `max_consecutive_reverts` reverts is frozen until `reset_backoff/2` (the
  wallet dapp re-enable).

  `{:refused, reason}` is NOT a failure of a broadcast: it is the simulation
  gate declining to broadcast at all — zero gas spent, relayer nonce
  untouched. `reason` is the node's decoded revert string (e.g. USDC's
  "transfer amount exceeds balance"), or `nil` when the node gave none.
  `{:failed, :reverted}` is reserved for the opposite truth: a transaction
  that WAS broadcast and that the chain reverted (gas was spent). Callers
  presenting results to users must not collapse the two — the first live
  deployment did, and told a user with insufficient USDC that their payment
  "didn't go through on the chain" when nothing had been sent.
  """
  use GenServer
  require Logger

  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.Keeper.{Eip3009, GasPolicy, PermitLane, Signer}
  alias DelegatedSpend.Keccak

  # Task 3b: the daily gas budget is a ROLLING 24h window, not a calendar-day
  # boundary — simpler (no timezone/midnight edge cases) and matches the
  # spec's real intent (bound what a gas-price spike can burn in ANY 24h
  # stretch, not reset a clock at UTC midnight for a griefer to exploit).
  @gas_budget_window_s 86_400

  # :chain_id is REQUIRED (0.3.1): every order view carries the keeper's
  # runtime chain id so the wallet dapp can refuse to run against a stale
  # static config.json (config drift = wrong-network fund-loss class). A
  # keeper that doesn't know its chain must not serve orders at all.
  @enforce_opts [:store, :source_allowlist, :order_ttl_s, :chain_id]
  @max_json_safe_integer 9_007_199_254_740_991
  @uint256_max Integer.pow(2, 256) - 1
  @secp256k1_order 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @secp256k1_half_order div(@secp256k1_order, 2)

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

  @doc """
  Validate a self-submit EIP-3009 authorization and return the token
  transaction without consuming the order. The destination and nonce remain
  server-derived, and the signature is recovered locally before calldata is
  exposed to the payer.
  """
  def build_self_authorization(keeper, order_ref, user_ref, auth),
    do: GenServer.call(keeper, {:build_self_authorization, order_ref, user_ref, auth})

  def order_status(keeper, order_id), do: GenServer.call(keeper, {:order_status, order_id})

  @doc """
  The EIP-712 domain the wallet dapp needs to compose a
  `TransferWithAuthorization` signature — `name`/`version` are the ones READ
  and CROSS-CHECKED at boot (see `read_and_verify_domain_fields/5`), never a
  hardcoded guess, plus the keeper's runtime `chain_id` and the
  treasury/token addresses. `:disabled` when the authorization lane isn't
  configured (nothing to serve, and nothing was read).
  """
  def authorization_domain(keeper), do: GenServer.call(keeper, :authorization_domain)

  @doc """
  Shared enrichment for every `"authorization"` or
  `"authorization_self"` order view — the registration ack
  (`DelegatedSpend.Keeper.Object`) and the wallet dapp's order view
  (`DelegatedSpend.Intake.handle_order/3`) both need the SAME
  nonce/destination/domain fields, computed from the SAME boot-verified
  `authorization_domain/1`; this is the one place that does it (review M7 —
  the two call sites merge into a differently-shaped `base` map and disagree
  on what `:disabled` should mean, so only the domain-lookup-and-merge core
  is shared; each caller still decides its own `:disabled` fallback).
  """
  def authorization_view_fields(keeper, order_ref, amount, expires_at, base) do
    case authorization_domain(keeper) do
      {:ok, domain} ->
        {:ok,
         Map.merge(base, %{
           "nonce" => DelegatedSpend.Orders.authorization_nonce_hex(order_ref),
           "to" => domain.treasury_address,
           "value" => amount,
           "valid_after" => 0,
           "valid_before" => expires_at,
           "token" => domain.token_address,
           "chain_id" => domain.chain_id,
           "domain" => %{
             "name" => domain.name,
             "version" => domain.version,
             "chainId" => domain.chain_id,
             "verifyingContract" => domain.token_address
           }
         })}

      :disabled ->
        :disabled
    end
  end

  @doc "Clear a suspended grant's revert backoff (the wallet dapp re-enable path)."
  def reset_backoff(keeper, user_ref), do: GenServer.call(keeper, {:reset_backoff, user_ref})

  @doc "Current consecutive-revert count for a user_ref (advisory / monitoring)."
  def backoff_count(keeper, user_ref), do: GenServer.call(keeper, {:backoff_count, user_ref})

  @doc "Deliver late results for work in flight when the keeper last stopped."
  def reconcile_boot(keeper), do: GenServer.call(keeper, :reconcile_boot, 60_000)

  def sweep_now(keeper), do: GenServer.call(keeper, :sweep_now, 60_000)

  @impl true
  def init(opts) do
    # Authorization lane config (EIP-3009), normalized ONCE here. Domain-ready
    # needs the token + treasury + the boot proof below and serves self-submit.
    # Sponsored additionally needs a signer. A one-address partial domain
    # still refuses boot, while signer-only remains a legal permit deployment.
    token_address = Map.get(opts, :token_address)
    treasury_address = Map.get(opts, :treasury_address)
    authorization_domain_ready? = authorization_domain_ready?(opts)
    authorization_sponsored? = authorization_sponsored?(opts, authorization_domain_ready?)

    # DOMAIN_SEPARATOR() = 0x3644e515. READ, never recomposed: a wrongly
    # composed domain produces signatures the chain rejects without saying
    # why (mirrors the Eip3009 moduledoc). Failing boot here is correct — with
    # no domain no signature can ever be validated on-chain, and booting
    # without it would only move the failure to the first paying user.
    {domain_separator, token_name, token_version} =
      case token_address do
        nil ->
          {nil, nil, nil}

        addr ->
          rpc_mod = Map.fetch!(opts, :rpc_mod)
          rpc = Map.fetch!(opts, :rpc)
          ds = read_domain_separator(rpc_mod, rpc, addr)
          {name, version} = read_and_verify_domain_fields(rpc_mod, rpc, addr, opts.chain_id, ds)
          {ds, name, version}
      end

    state = %{
      signer: Map.get(opts, :signer),
      token_address: token_address,
      treasury_address: treasury_address,
      domain_separator: domain_separator,
      # Boot-VERIFIED name/version (see `read_and_verify_domain_fields/5`
      # below) — the only fields ever served to the dapp as the EIP-712
      # domain, because they are proven to hash to the on-chain
      # DOMAIN_SEPARATOR read above, not merely assumed from public knowledge
      # of the real token deployments.
      token_name: token_name,
      token_version: token_version,
      authorization_domain_ready?: authorization_domain_ready?,
      authorization_sponsored?: authorization_sponsored?,
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
      sweep_ms: Map.get(opts, :sweep_ms, 5_000),
      # Task 3b economic brakes (spec §5), EIP-3009 lane only. ALL optional —
      # an absent key does not limit (GasPolicy's own deliberate rule; see its
      # moduledoc). Deliberately NOT in either authorization capability
      # predicate's
      # half-config check below: a deployment with none of these configured
      # is a legal, just UNBRAKED, deployment — real numbers are fixed by
      # measurement (Task 7), not required at boot.
      gas_policy: %{
        max_gas_wei: Map.get(opts, :max_gas_wei),
        daily_gas_budget_wei: Map.get(opts, :daily_gas_budget_wei),
        min_order_units: Map.get(opts, :min_order_units)
      }
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
         true <- valid_order_amount?(amount) || {:error, :bad_amount},
         {:ok, kind} <- order_kind(req, state),
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
                # Defense in depth: self-submit orders must never reach the
                # sponsor's consume/simulate/broadcast path, even on a keeper
                # that has a signer configured.
                {:reply, {:failed, :wrong_kind}, state}

              # Sponsored execution needs the boot-proved domain AND a signer.
              # Half-configured address pairs never boot.
              not state.authorization_sponsored? ->
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

              auth.value !== order.amount ->
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
                  :ok ->
                    # Task 3b (spec §5): the economic brakes, consulted
                    # BEFORE the Signer sees this order — a rejected order
                    # must not be consumed (see submit_consumed below).
                    case gas_policy_admit(auth.value, state) do
                      :ok -> execute_authorization_consumed(order, auth, state)
                      {:reject, reason} -> {:reply, {:failed, reason}, state}
                    end

                  reason ->
                    {:reply, {:failed, reason}, state}
                end
            end

          status ->
            {:reply, status, state}
        end
    end
  end

  def handle_call({:build_self_authorization, order_ref, user_ref, auth}, _from, state) do
    reply =
      case store(state).get_order_by_ref(store_ref(state), order_ref, user_ref) do
        nil ->
          {:error, :not_found}

        order ->
          cond do
            Map.get(order, :kind, "permit") != "authorization_self" ->
              {:error, :wrong_kind}

            not state.authorization_domain_ready? ->
              {:error, :authorization_lane_disabled}

            now_s() > order.expires_at ->
              {:error, :expired}

            not valid_authorization_fields?(auth) ->
              {:error, :no_grant}

            auth.value !== order.amount ->
              {:error, :no_grant}

            not owner_binding_ok?(order, auth.from, state) ->
              {:error, :no_grant}

            true ->
              with :ok <- error_result(authorization_window(auth, state)),
                   :ok <- error_result(GasPolicy.minimum(auth.value, state.gas_policy)),
                   {:ok, normalized_signature} <-
                     verify_authorization_signature(order, auth, state) do
                normalized_auth = Map.put(auth, :signature, normalized_signature)

                {:ok,
                 %{
                   to: state.token_address,
                   data: authorization_calldata_hex(order, normalized_auth, state),
                   chain_id: state.chain_id,
                   valid_before: auth.valid_before
                 }}
              else
                :error -> {:error, :invalid_signature}
                {:error, reason} -> {:error, reason}
              end
          end
      end

    {:reply, reply, state}
  end

  def handle_call(:authorization_domain, _from, state) do
    reply =
      if state.authorization_domain_ready? do
        {:ok,
         %{
           treasury_address: state.treasury_address,
           token_address: state.token_address,
           chain_id: state.chain_id,
           name: state.token_name,
           version: state.token_version
         }}
      else
        :disabled
      end

    {:reply, reply, state}
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

  # The domain needs BOTH addresses. One without the other is still a broken
  # deployment and refuses boot: neither self-submit nor sponsorship can build
  # safe calldata from it. Both absent is a clean permit-only deployment.
  defp authorization_domain_ready?(opts) do
    configured = [
      token_address: Map.get(opts, :token_address),
      treasury_address: Map.get(opts, :treasury_address)
    ]

    present = Enum.reject(configured, fn {_key, value} -> is_nil(value) end)
    missing = for {key, nil} <- configured, do: key

    cond do
      present == [] ->
        false

      missing != [] ->
        raise ArgumentError,
              "keeper: authorization domain is half-configured — missing " <>
                Enum.map_join(missing, ", ", &inspect/1) <>
                ". Configure both :token_address and :treasury_address, or neither."

      true ->
        validate_authorization_address!(:treasury_address, configured[:treasury_address])
        validate_authorization_address!(:token_address, configured[:token_address])
        true
    end
  end

  # A signer alone is the existing permit-only deployment and does not request
  # EIP-3009 sponsorship. A domain-ready keeper without one intentionally
  # serves self-submit only; adding the signer enables the sponsored lane too.
  defp authorization_sponsored?(opts, domain_ready?),
    do: domain_ready? and not is_nil(Map.get(opts, :signer))

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

  # name() = 0x06fdde03, version() = 0x54fd4d50. Proves the fields this
  # keeper will later serve as the EIP-712 domain are the TRUE preimage of
  # the on-chain DOMAIN_SEPARATOR already read above, rather than a
  # hardcoded guess — even though both values are public knowledge for the
  # real deployments this package targets ("USDC" / "2" on both Base
  # chains), reading and cross-checking them here is the only way to prove
  # what gets served is correct: composing a domain that merely LOOKS
  # plausible and handing it to the dapp would produce signatures the chain
  # silently rejects (see the Eip3009 moduledoc), discovered only after a
  # real user tries to pay. Boot fails closed on any mismatch or malformed
  # read, exactly like the DOMAIN_SEPARATOR read and BootCheck's codehash
  # pin.
  defp read_and_verify_domain_fields(rpc_mod, rpc, token_address, chain_id, domain_separator) do
    name = read_token_string(rpc_mod, rpc, token_address, "0x06fdde03", "name")
    version = read_token_string(rpc_mod, rpc, token_address, "0x54fd4d50", "version")

    computed =
      DelegatedSpend.Keeper.Eip3009.domain_separator(name, version, chain_id, token_address)

    unless computed == domain_separator do
      raise "keeper: token #{String.downcase(token_address)} name()/version() " <>
              "(#{inspect(name)}, #{inspect(version)}) do not hash to the on-chain " <>
              "DOMAIN_SEPARATOR — refusing to serve an unverified EIP-712 domain to the dapp " <>
              "(expected 0x#{Base.encode16(domain_separator, case: :lower)}, computed " <>
              "0x#{Base.encode16(computed, case: :lower)})"
    end

    {name, version}
  end

  defp read_token_string(rpc_mod, rpc, token_address, selector, label) do
    case rpc_mod.eth_call(rpc, token_address, selector) do
      "0x" <> hex ->
        case decode_abi_string(hex) do
          {:ok, str} ->
            str

          :error ->
            raise "keeper: could not decode #{label}() from token " <>
                    "#{String.downcase(token_address)}: malformed ABI string"
        end

      other ->
        raise "keeper: could not read #{label}() from token " <>
                "#{String.downcase(token_address)}: #{inspect(other)}"
    end
  end

  # Minimal ABI decode for a single dynamic `string` return: offset word (32
  # bytes, ignored — always 0x20 for a direct single-value return), length
  # word, then the UTF-8 bytes themselves (right-padded to a multiple of 32,
  # which `binary_part/3` below simply ignores).
  defp decode_abi_string(hex) do
    bytes = Base.decode16!(hex, case: :mixed)

    case bytes do
      <<_offset::256, len::256, rest::binary>> when byte_size(rest) >= len ->
        {:ok, binary_part(rest, 0, len)}

      _ ->
        :error
    end
  rescue
    _ -> :error
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
    calldata_hex = authorization_calldata_hex(order, auth, state)

    # Eip3009 returns calldata as "0x…" text (shaped for an external
    # consumer, e.g. an HTTP response), but the Signer — like
    # PermitLane.build_call above — expects `tx.data` as RAW bytes: Tx1559
    # signs over the actual byte string, not its hex spelling. Decode at this
    # boundary between the two conventions.
    # `replace_prefix/3`, not `trim_leading/2`: the latter strips EVERY leading
    # occurrence ("0x0x12" -> "12"), which is never the intent for a prefix.
    data = calldata_hex |> String.replace_prefix("0x", "") |> Base.decode16!(case: :mixed)

    # Fix wave (Important #1+#2): gas-spend recording is no longer a
    # post-submit side effect here — it happens INSIDE submit_consumed's
    # persist_hash_fn, at the same durable pre-broadcast moment the Signer
    # already writes the tx hash, for both the initial broadcast and every
    # fee-bumped replacement. See `record_tracked_gas_spend/3`.
    submit_consumed(order, %{to: state.token_address, data: data, value: 0}, state)
  end

  defp authorization_calldata_hex(order, auth, state) do
    Eip3009.transfer_with_authorization_calldata(
      auth.from,
      state.treasury_address,
      auth.value,
      auth.valid_after,
      auth.valid_before,
      DelegatedSpend.Orders.authorization_nonce(order.order_ref),
      auth.signature
    )
  end

  # Sponsored execution preserves the original all-or-nothing dynamic-read
  # behavior: configuring ANY economic brake (including only the minimum)
  # fetches the gas price and accounting readings before GasPolicy.admit/2.
  # Self-submit calls GasPolicy.minimum/2 directly and never reaches here.
  defp gas_policy_admit(order_units, state) do
    config = state.gas_policy

    if gas_policy_config_empty?(config) do
      :ok
    else
      case current_gas_price(state) do
        {:error, reason} ->
          {:reject, reason}

        price ->
          GasPolicy.admit(
            %{
              gas_price_wei: price,
              spent_today_wei: gas_spent_today(state),
              order_units: order_units
            },
            config
          )
      end
    end
  end

  defp gas_policy_config_empty?(%{
         max_gas_wei: nil,
         daily_gas_budget_wei: nil,
         min_order_units: nil
       }),
       do: true

  defp gas_policy_config_empty?(_config), do: false

  # `Rpc.gas_price/1` (eth_gasPrice) — the SAME typed wrapper `evm/rpc.ex`
  # already exposes, reused as-is rather than inventing a new RPC helper.
  # `rpc_mod`/`rpc` are guaranteed present here: the authorization lane
  # requires them at boot (the DOMAIN_SEPARATOR read above), and this helper
  # only ever runs on that lane. A transient RPC failure must not crash the
  # keeper — nothing has been consumed yet, so it degrades to the same typed
  # `:rpc_timeout` the submit path already uses for RPC trouble.
  defp current_gas_price(%{rpc_mod: mod, rpc: rpc}) do
    mod.gas_price(rpc)
  rescue
    _ -> {:error, :rpc_timeout}
  catch
    _kind, _reason -> {:error, :rpc_timeout}
  end

  defp gas_spent_today(state) do
    store = store(state)

    if function_exported?(store, :gas_spent_since, 2) do
      store.gas_spent_since(store_ref(state), now_s() - @gas_budget_window_s)
    else
      Logger.warning(
        "keeper gas budget configured but #{inspect(store)} does not implement " <>
          "optional gas_spent_since/2; treating prior sponsored gas spend as 0"
      )

      0
    end
  end

  # Fix wave (Important #1+#2, structural fix): gas-spend is recorded at the
  # SAME durable pre-broadcast moment the Signer already persists the
  # inflight tx hash (persist_hash_fn, called before EVERY initial broadcast
  # AND every fee-bumped replacement — see signer.ex's do_submit/bump). This
  # makes under-counting structurally impossible: a crash right after
  # broadcast has already had its spend recorded; a broadcast that then
  # fails to send overcounts by one estimate, which is conservative (the
  # budget brake trips earlier, never later).
  #
  # `cost_wei` is the full estimate on an initial broadcast, or only the
  # DELTA versus the previous broadcast on a fee-bumped replacement (signer.ex
  # computes which one applies); either way this function just adds it.
  #
  # Scoped to the authorization lane only — `order.kind == "authorization"` —
  # so a permit-lane order on a keeper that ALSO has the authorization lane
  # (and a daily gas budget) configured records nothing, keeping the permit
  # lane byte-for-byte unchanged (spec mandate).
  #
  # Gated on `:daily_gas_budget_wei` being configured (Minor #3): a keeper
  # that never set a daily budget performs zero extra store writes, not just
  # zero extra RPC/read cost — nothing ever reads this history back, so
  # nothing should be paying to write it. Enabling the budget later starts a
  # fresh window with no retroactive history, which is fine since the window
  # itself is rolling 24h, not a fixed epoch.
  #
  # Re-review fix (Important): this runs INSIDE the same `persist_hash_fn`
  # closure as the durable tx-hash write (see `submit_consumed/3`), but its
  # own outcome must never be allowed to affect that closure's return value.
  # The hash write is the anti-double-broadcast control — a caller
  # (signer.ex's `persist_hash/3`) that sees this closure raise cannot tell
  # "the accounting write failed" apart from "the hash failed to persist,"
  # and treats both as a reason to refuse the broadcast; keeper.ex's caller
  # then durably overwrites the order to a TERMINAL `{:failed, :rpc_timeout}`
  # — even though the hash had already been written and nothing was ever
  # broadcast twice. That would kill a perfectly good order over a lost
  # accounting row. So: rescue/catch everything here, log a warning naming
  # the order and the wei amount that won't be counted, and always return
  # `:ok`. Losing one row under-counts the daily budget by a bounded amount
  # (this one broadcast's cost) — a nuisance the operator is warned about;
  # losing a legitimate, already-consumed order is much worse and is exactly
  # what the old `safe_cost_estimate/2` was written to prevent. Accounting
  # must depend on hash persistence (it only runs when the hash write
  # succeeds); hash persistence must never depend on accounting.
  defp record_tracked_gas_spend(order, cost_wei, state) do
    tracked? = Map.get(order, :kind, "permit") == "authorization"
    budgeted? = not is_nil(state.gas_policy.daily_gas_budget_wei)

    if tracked? and budgeted? and cost_wei > 0 do
      at = now_s()
      store(state).record_gas_spend(store_ref(state), cost_wei, at, at - @gas_budget_window_s)
    end

    :ok
  rescue
    error ->
      warn_gas_spend_lost(order, cost_wei, inspect(error))
      :ok
  catch
    kind, reason ->
      warn_gas_spend_lost(order, cost_wei, "#{kind}: #{inspect(reason)}")
      :ok
  end

  defp warn_gas_spend_lost(order, cost_wei, detail) do
    Logger.warning(
      "order #{order.order_id}: gas spend not recorded — budget will under-count by " <>
        "~#{cost_wei} wei (accounting write raised: #{detail})"
    )
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
        # The hash write and the gas-spend record are both durable
        # PRE-broadcast side effects the Signer triggers via this one
        # callback, before every initial and fee-bumped broadcast (see
        # signer.ex moduledoc) — recording only happens once the hash write
        # itself succeeds (`result == :ok`): if the durable write fails, the
        # Signer never broadcasts (do_submit/bump both refuse on a
        # non-:ok persist_hash_fn), so nothing was spent and nothing should
        # be recorded either.
        persist_hash_fn = fn hash, cost_wei ->
          result = store(state).update_inflight_hash(store_ref(state), order.order_id, hash)
          if result == :ok, do: record_tracked_gas_spend(order, cost_wei, state)
          result
        end

        case Signer.submit(state.signer, order.order_id, tx, persist_hash_fn) do
          {:ok, hash} ->
            {:reply, {:submitted, hash}, state}

          {:error, {:reverted, info}} ->
            # The simulation gate said no BEFORE anything was broadcast: zero
            # gas, nonce untouched. That is a different truth from an on-chain
            # revert and gets a different word — with the node's own reason,
            # which was previously dropped right here.
            result = {:refused, refusal_reason(info)}
            {:reply, result, settle(state, order.order_id, result)}

          {:error, {:rejected, info}} ->
            # The node PARSED the broadcast and answered no (dry relayer,
            # 2026-07-27 live test: `insufficient funds`). Nothing entered
            # the pool, the Signer freed the nonce — a terminal the user
            # hears about instead of waiting forever on "submitted ✓". The
            # reason is an OPERATOR signal (it is OUR wallet that can't pay),
            # logged here, never shown raw to a chat user.
            Logger.warning(
              "keeper_submit_rejected order_id=#{order.order_id} info=#{inspect(info)}"
            )

            result = {:failed, :submit_rejected}
            {:reply, result, settle(state, order.order_id, result)}

          {:error, _reason} ->
            {:reply, {:failed, :rpc_timeout},
             settle(state, order.order_id, {:failed, :rpc_timeout})}
        end
    end
  end

  # ── refusal reasons ───────────────────────────────────────────────────────
  #
  # The node's eth_call error carries the contract's revert reason twice over:
  # ABI-encoded `Error(string)` bytes under "data" (selector 0x08c379a0), and
  # usually a human "message" too. Prefer the data — it is the contract's own
  # words, unmangled by node formatting — and fall back to the message with
  # the standard "execution reverted" prefix stripped. Every branch degrades
  # to nil rather than raising: this runs on the submit path, and a weird node
  # error must yield {:refused, nil}, never a crash.

  @error_string_selector "08c379a0"

  # The transport (Rpc.call) hands the JSON-RPC error object wrapped as
  # {:rpc_error, method, err} — unwrap first. The first live refusal shipped
  # without this clause (the test fake returned a bare map) and every real
  # reason decoded to nil.
  defp refusal_reason({:rpc_error, _method, err}), do: refusal_reason(err)

  defp refusal_reason(%{"data" => "0x" <> @error_string_selector <> hex}) do
    with {:ok, bin} <- Base.decode16(hex, case: :mixed),
         [reason] when is_binary(reason) <-
           DelegatedSpend.Evm.Abi.decode_result([:string], bin) do
      reason
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp refusal_reason(%{"message" => msg}) when is_binary(msg) do
    case msg |> String.replace_prefix("execution reverted:", "") |> String.trim() do
      "" -> nil
      "execution reverted" -> nil
      reason -> reason
    end
  end

  defp refusal_reason(_info), do: nil

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
        order = store(state).get_order(store_ref(state), order_id)
        state = update_backoff(state, order, result)
        notify_result(state.result_fn, order_id, order, result)
        state

      :existing ->
        state
    end
  end

  # The notification carries the caller's OWN identifier, not just ours.
  #
  # `order_id` is minted here, from random bytes, and a producer has no way to
  # resolve it: nothing it stored is keyed by it. A callback that can only say
  # "some order finished" cannot tell anyone WHICH — a real consumer wired this
  # up to notify the paying user and silently notified nobody, because every
  # lookup by that id missed. `order_ref` is the identifier the producer minted
  # and stored, so it is the one that can be joined back to.
  #
  # nil order_ref/user_ref/kind mean the order row is gone (a store that
  # forgot, or a terminal result for an order pruned underneath us): the
  # result is still worth delivering, and a consumer that cannot resolve it
  # simply does nothing.
  defp notify_result(result_fn, order_id, order, result) do
    result_fn.(%{
      order_id: order_id,
      order_ref: order && Map.get(order, :order_ref),
      user_ref: order && Map.get(order, :user_ref),
      kind: order && Map.get(order, :kind),
      result: result
    })
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

  # A simulation refusal counts too: signing authorizations that cannot clear
  # is exactly the griefing this counter exists to bound (§5.2.1), whether or
  # not the broadcast happened.
  defp update_backoff(state, %{user_ref: user_ref}, {:refused, _reason}),
    do: %{state | reverts: Map.update(state.reverts, user_ref, 1, &(&1 + 1))}

  defp update_backoff(state, _order, _result), do: state

  defp suspended?(_user_ref, %{max_reverts: 0}), do: false

  defp suspended?(user_ref, state),
    do: Map.get(state.reverts, user_ref, 0) >= state.max_reverts

  # `state` is threaded through so the "authorization" branch can refuse
  # BEFORE the caller ever reaches `order_ref/3`/`put_order/2` (review I2): a
  # disabled lane must not persist a phantom order or burn the caller-minted
  # `order_ref` — a rejected registration must be retriable, byte-identical,
  # with no trace left behind. Each authorization kind uses its own
  # boot-computed capability predicate.
  defp order_kind(req, state) do
    case Map.get(req, :kind, "permit") do
      "permit" ->
        {:ok, "permit"}

      # The EIP-3009 lane's kind. Registrable like "permit": the order carries
      # no routing payload of its own — the destination is the keeper's own
      # treasury — so there is nothing extra to validate here.
      "authorization" ->
        if state.authorization_sponsored?,
          do: {:ok, "authorization"},
          else: {:error, :authorization_lane_disabled}

      # Self-submit shares the boot-proved token/domain/destination but never
      # enters the sponsored execution door.
      "authorization_self" ->
        if state.authorization_domain_ready?,
          do: {:ok, "authorization_self"},
          else: {:error, :authorization_lane_disabled}

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

  defp verify_authorization_signature(order, auth, state) do
    with {:ok, r, s, recid, normalized_signature} <-
           normalize_authorization_signature(auth.signature),
         true <- valid_signature_scalar?(r),
         true <- valid_signature_scalar?(s),
         true <- low_signature_scalar?(s),
         digest <-
           Eip3009.authorization_digest(
             state.domain_separator,
             auth.from,
             state.treasury_address,
             auth.value,
             auth.valid_after,
             auth.valid_before,
             DelegatedSpend.Orders.authorization_nonce(order.order_ref)
           ),
         <<4, public_key::binary-size(64)>> <- Secp256k1.recover(digest, r, s, recid),
         recovered <-
           public_key
           |> Keccak.hash_256()
           |> binary_part(12, 20)
           |> Address.checksum() do
      if Address.eq?(recovered, auth.from), do: {:ok, normalized_signature}, else: :error
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp normalize_authorization_signature(<<r::binary-size(32), s::binary-size(32), v>>)
       when v in [0, 1],
       do: {:ok, r, s, v, r <> s <> <<v + 27>>}

  defp normalize_authorization_signature(<<r::binary-size(32), s::binary-size(32), v>>)
       when v in [27, 28],
       do: {:ok, r, s, v - 27, r <> s <> <<v>>}

  defp normalize_authorization_signature(_signature), do: :error

  defp valid_signature_scalar?(bytes) do
    scalar = :binary.decode_unsigned(bytes)
    scalar > 0 and scalar < @secp256k1_order
  end

  defp low_signature_scalar?(bytes),
    do: :binary.decode_unsigned(bytes) <= @secp256k1_half_order

  defp valid_order_amount?(amount),
    do: is_integer(amount) and amount >= 0 and amount <= @uint256_max

  defp error_result(:ok), do: :ok
  defp error_result({:reject, reason}), do: {:error, reason}
  defp error_result(reason) when is_atom(reason), do: {:error, reason}

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
