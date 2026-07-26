defmodule DelegatedSpend.Keeper.Signer do
  @moduledoc """
  The keeper's transaction submitter — its OWN key, never the app's bot key.

  Owns (spec §5.2 item 2, §5.2.1):
    * boot verification: pinned chain id checked against the RPC before start
      completes (a wrong RPC refuses to come up rather than sign for the
      wrong chain);
    * simulation before broadcast: every submit `eth_call`s the exact
      transaction first — a failing simulation is a typed failure and spends
      ZERO gas (the anti-griefing core; do not weaken);
    * gap-free nonces: once a signed candidate is durably recorded, its nonce
      is reserved even when the RPC response is ambiguous;
    * `action_key` idempotency: a retry of the same action can never
      double-broadcast — it returns the recorded hash/terminal state;
    * sweep: stuck transactions are rebroadcast at the SAME nonce with
      bumped fees;
    * low-balance alarm (Task 3b, spec §5 — the most likely failure mode):
      the SAME periodic sweep reads the relayer's native balance and, below
      the optional `:low_balance_wei`, logs a `warning` naming the
      `keeper_relayer_low_balance` metric — there is no metrics framework in
      this package, so a host that wants to alert on it scrapes the log line;
    * `cost_estimate/2`: the wei cost (gas * max_fee) already computed for a
      still-in-flight `action_key`, read back — not re-derived — by the
      keeper right after a successful submit to record the day's gas spend.
      It is an ESTIMATE (the ceiling used, not the gas actually burned) and
      only exists while the entry is in flight: once resolved, `done` keeps
      just the terminal status, not its params.

  The Keeper Store, not this process, owns durable execution status across
  restarts. Keeper supplies the request-critical hash writer used before each
  initial or replacement broadcast.
  """
  use GenServer
  require Logger

  alias DelegatedSpend.Evm.{Address, Rpc, Tx1559}

  @gas_headroom_num 13
  @gas_headroom_den 10
  @fee_bump_num 5
  @fee_bump_den 4

  # Optional :name registers the server (supervision-friendly: a restarted
  # signer is reachable at the same name, so holders never keep a stale pid).
  def start_link(opts) do
    opts = Map.new(opts)

    case Map.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def submit(server, action_key, tx),
    do: submit(server, action_key, tx, fn _hash -> :ok end)

  def submit(server, action_key, tx, persist_hash_fn),
    do: GenServer.call(server, {:submit, action_key, tx, persist_hash_fn}, 60_000)

  def status(server, action_key), do: GenServer.call(server, {:status, action_key})
  def receipt(server, tx_hash), do: GenServer.call(server, {:receipt, tx_hash}, 60_000)
  def address(server), do: GenServer.call(server, :address)
  def sweep_now(server), do: GenServer.call(server, :sweep_now, 60_000)

  @doc """
  The estimated wei cost (gas * max_fee) of the still-in-flight entry for
  `action_key` — `{:ok, wei}`, or `:unknown` once it never existed or has
  already resolved (see moduledoc).
  """
  def cost_estimate(server, action_key), do: GenServer.call(server, {:cost_estimate, action_key})

  @impl true
  def init(opts) do
    rpc_mod = Map.get(opts, :rpc_mod, Rpc)
    rpc = Map.fetch!(opts, :rpc_url)
    pinned = Map.fetch!(opts, :chain_id)
    priv = Map.fetch!(opts, :priv)

    case rpc_mod.chain_id(rpc) do
      ^pinned ->
        addr = Address.from_private_key(priv)

        state = %{
          rpc_mod: rpc_mod,
          rpc: rpc,
          chain_id: pinned,
          priv: priv,
          addr: addr,
          next_nonce: rpc_mod.nonce(rpc, addr),
          pending: %{},
          done: %{},
          sweep_ms: Map.get(opts, :sweep_ms, 15_000),
          bump_after_ms: Map.get(opts, :bump_after_ms, 30_000),
          # Task 3b: optional — absent means no alarm, consistent with
          # GasPolicy's own "no limit configured" rule. Nil also means the
          # sweep never pays for the extra `eth_getBalance` read at all (see
          # `check_low_balance/1`).
          low_balance_wei: Map.get(opts, :low_balance_wei)
        }

        Process.send_after(self(), :sweep, state.sweep_ms)
        {:ok, state}

      other ->
        {:stop, {:chain_id_mismatch, expected: pinned, got: other}}
    end
  end

  @impl true
  def handle_call(:address, _from, state), do: {:reply, state.addr, state}

  def handle_call({:receipt, tx_hash}, _from, state),
    do: {:reply, safe_receipt(state, tx_hash), state}

  def handle_call({:status, key}, _from, state) do
    reply =
      cond do
        terminal = state.done[key] -> terminal
        p = state.pending[key] -> {:pending, p.hash}
        true -> :unknown
      end

    {:reply, reply, state}
  end

  def handle_call(:sweep_now, _from, state), do: {:reply, :ok, do_sweep(state)}

  def handle_call({:cost_estimate, key}, _from, state) do
    reply =
      case state.pending[key] do
        %{params: %{gas: gas, max_fee: max_fee}} -> {:ok, gas * max_fee}
        nil -> :unknown
      end

    {:reply, reply, state}
  end

  def handle_call({:submit, key, tx, persist_hash_fn}, _from, state) do
    cond do
      terminal = state.done[key] ->
        {:reply, terminal_reply(terminal), state}

      p = state.pending[key] ->
        {:reply, {:ok, p.hash}, state}

      true ->
        do_submit(key, tx, persist_hash_fn, state)
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, state.sweep_ms)
    {:noreply, do_sweep(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── submit path ──────────────────────────────────────────────────────────

  defp do_submit(key, tx, persist_hash_fn, state) do
    %{rpc_mod: rpc_mod, rpc: rpc} = state
    to = Map.fetch!(tx, :to)
    data = Map.fetch!(tx, :data)
    value = Map.get(tx, :value, 0)
    data_hex = "0x" <> Base.encode16(data, case: :lower)

    # THE invariant: never broadcast what failed simulation. Zero gas spent
    # on a revert; the nonce is untouched.
    case simulate(rpc_mod, rpc, state.addr, to, data_hex) do
      {:error, info} ->
        {:reply, {:error, {:reverted, info}}, state}

      {:ok, _} ->
        with {:ok, gas} <- estimate(rpc_mod, rpc, state.addr, to, data_hex, value),
             {:ok, fees} <- fees(rpc_mod, rpc) do
          params = %{
            nonce: state.next_nonce,
            max_priority_fee: fees.prio,
            max_fee: fees.max_fee,
            gas: div(gas * @gas_headroom_num, @gas_headroom_den),
            to: to,
            value: value,
            data: data,
            chain_id: state.chain_id
          }

          {raw, hash} = Tx1559.sign(params, state.priv)

          case persist_hash(persist_hash_fn, hash) do
            :ok ->
              _ = rpc_mod.send_raw(rpc, raw)

              # `hashes` keeps every same-nonce variant ever broadcast for this
              # action: after a fee bump BOTH transactions are valid at the
              # nonce and EITHER may mine — the sweep must watch them all.
              entry = %{
                hash: hash,
                hashes: [hash],
                params: params,
                persist_hash_fn: persist_hash_fn,
                sent_at: now_ms(),
                bumps: 0
              }

              {:reply, {:ok, hash},
               %{
                 state
                 | next_nonce: state.next_nonce + 1,
                   pending: Map.put(state.pending, key, entry)
               }}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # Contract creations cannot be meaningfully eth_call-simulated with a `to`;
  # they go straight to estimation (which itself rejects invalid init code).
  defp simulate(_rpc_mod, _rpc, _from, :create, _data_hex), do: {:ok, :create}

  defp simulate(rpc_mod, rpc, from, to, data_hex),
    do: rpc_mod.eth_call_from(rpc, from, to, data_hex)

  defp estimate(rpc_mod, rpc, from, to, data_hex, value) do
    tx = %{from: from, data: data_hex, value: "0x" <> Integer.to_string(value, 16)}
    tx = if to == :create, do: tx, else: Map.put(tx, :to, to_hex(to))

    case rpc_mod.estimate_gas(rpc, tx) do
      {:ok, gas} when is_integer(gas) -> {:ok, gas}
      other -> {:error, {:estimate_gas, other}}
    end
  end

  defp fees(rpc_mod, rpc) do
    prio = rpc_mod.max_priority_fee(rpc)
    base = rpc_mod.base_fee(rpc)
    {:ok, %{prio: prio, max_fee: base * 2 + prio}}
  rescue
    e -> {:error, {:fees, e}}
  end

  defp to_hex(<<_::binary-size(20)>> = bin), do: "0x" <> Base.encode16(bin, case: :lower)
  defp to_hex("0x" <> _ = addr), do: addr

  # ── sweep: receipts + same-nonce fee-bumped rebroadcast ──────────────────

  defp do_sweep(state) do
    check_low_balance(state)

    Enum.reduce(state.pending, state, fn {key, entry}, acc ->
      # Check EVERY same-nonce variant — after a bump, the original tx can
      # still be the one that mines.
      mined =
        Enum.find_value(entry.hashes, fn h ->
          case safe_receipt(acc, h) do
            %{"status" => "0x1"} -> {:mined, h}
            %{"status" => "0x0"} -> {:failed, h}
            _ -> nil
          end
        end)

      case mined do
        {status, h} ->
          finish(acc, key, {status, h})

        nil ->
          if now_ms() - entry.sent_at > acc.bump_after_ms, do: bump(acc, key, entry), else: acc
      end
    end)
  end

  # Task 3b, spec §5: the single most likely way this whole system fails is
  # the relayer's own wallet running dry mid-day — it has to warn BEFORE
  # zero, not after. `nil` (unset) skips the check entirely: no RPC call, no
  # cost, for a deployment that hasn't picked a threshold yet.
  defp check_low_balance(%{low_balance_wei: nil}), do: :ok

  defp check_low_balance(state) do
    case safe_balance(state) do
      nil ->
        :ok

      balance when balance < state.low_balance_wei ->
        # No metrics/telemetry framework exists in this package — the metric
        # NAME is embedded in the log line itself (first token, key=value
        # after it) so a host that scrapes logs can alert on
        # `keeper_relayer_low_balance` without us inventing a framework here.
        Logger.warning(
          "keeper_relayer_low_balance addr=#{state.addr} balance_wei=#{balance} " <>
            "threshold_wei=#{state.low_balance_wei}"
        )

      _balance ->
        :ok
    end
  end

  # A transient RPC error reading the balance must not crash the sweep, same
  # reasoning as `safe_receipt/2` below.
  defp safe_balance(state) do
    state.rpc_mod.balance(state.rpc, state.addr)
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  # A transient RPC error while polling a receipt (the real Rpc.receipt uses
  # call! and RAISES on transport failure) must NOT crash the sweep and wipe
  # the in-memory idempotency/hash state — treat it as "no receipt yet" and
  # let the next tick retry.
  defp safe_receipt(state, hash) do
    state.rpc_mod.receipt(state.rpc, hash)
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp finish(state, key, terminal) do
    %{
      state
      | pending: Map.delete(state.pending, key),
        done: Map.put(state.done, key, terminal)
    }
  end

  defp bump(state, key, entry) do
    params = %{
      entry.params
      | max_priority_fee: div(entry.params.max_priority_fee * @fee_bump_num, @fee_bump_den) + 1,
        max_fee: div(entry.params.max_fee * @fee_bump_num, @fee_bump_den) + 1
    }

    {raw, hash} = Tx1559.sign(params, state.priv)

    case persist_hash(entry.persist_hash_fn, hash) do
      :ok ->
        _ = state.rpc_mod.send_raw(state.rpc, raw)

        entry = %{
          entry
          | hash: hash,
            hashes: [hash | entry.hashes],
            params: params,
            sent_at: now_ms(),
            bumps: entry.bumps + 1
        }

        %{state | pending: Map.put(state.pending, key, entry)}

      {:error, _reason} ->
        state
    end
  end

  defp persist_hash(fun, hash) do
    case fun.(hash) do
      :ok -> :ok
      other -> {:error, {:persist_hash, other}}
    end
  rescue
    error -> {:error, {:persist_hash, error}}
  catch
    kind, reason -> {:error, {:persist_hash, {kind, reason}}}
  end

  defp terminal_reply({:mined, hash}), do: {:ok, hash}
  defp terminal_reply({:failed, hash}), do: {:error, {:onchain_failed, hash}}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
