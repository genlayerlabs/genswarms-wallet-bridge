defmodule DelegatedSpend.FakeRpc do
  @moduledoc """
  Scripted RPC seam for Signer/BootCheck tests. Start with a config map; records
  every `send_raw` so tests can assert exactly what was (not) broadcast.
  The `rpc` handle IS the agent pid.
  """

  def start(config) do
    {:ok, pid} = Agent.start_link(fn -> Map.merge(%{sent: [], receipts: %{}}, config) end)
    pid
  end

  def sent(pid), do: Agent.get(pid, & &1.sent) |> Enum.reverse()
  def put(pid, key, value), do: Agent.update(pid, &Map.put(&1, key, value))

  # ── rpc_mod interface ──────────────────────────────────────────────────────
  # Failure knobs (default off, so existing tests are unaffected):
  #   :send_raw_fail  → send_raw returns {:error, reason}, records nothing
  #                     {:accepted, reason} records the tx, then returns the error
  #   :receipt_raises → receipt/2 raises (a transient-RPC crash simulation)
  #   :receipt_failure → :raise | :exit | :throw
  #   :fees_raise     → max_priority_fee raises (fees error path)
  #   :block_timestamp → the value block_timestamp/1 returns (else wall clock)
  def chain_id(pid), do: Agent.get(pid, & &1.chain_id)
  def nonce(pid, _addr), do: Agent.get(pid, & &1.nonce)

  def max_priority_fee(pid) do
    if Agent.get(pid, &Map.get(&1, :fees_raise, false)), do: raise("simulated fees RPC failure")
    1_000_000_000
  end

  def base_fee(_pid), do: 10_000_000_000
  def estimate_gas(pid, _tx), do: {:ok, Agent.get(pid, &Map.get(&1, :gas, 100_000))}
  def code(pid, addr), do: Agent.get(pid, &Map.fetch!(&1.codes, addr))

  def block_timestamp(pid),
    do: Agent.get(pid, &Map.get(&1, :block_timestamp, System.os_time(:second)))

  def eth_call_from(pid, _from, _to, _data) do
    case Agent.get(pid, & &1.simulate) do
      :ok -> {:ok, "0x"}
      {:revert, info} -> {:error, info}
    end
  end

  def send_raw(pid, raw) do
    case Agent.get(pid, &Map.get(&1, :send_raw_fail)) do
      nil ->
        Agent.update(pid, &%{&1 | sent: [raw | &1.sent]})
        {:ok, "0x" <> Base.encode16(:crypto.hash(:sha256, raw), case: :lower)}

      {:accepted, reason} ->
        Agent.update(pid, &%{&1 | sent: [raw | &1.sent]})
        {:error, reason}

      reason ->
        {:error, reason}
    end
  end

  def receipt(pid, hash) do
    if Agent.get(pid, &Map.get(&1, :receipt_raises, false)),
      do: raise("simulated RPC receipt failure")

    case Agent.get(pid, &Map.get(&1, :receipt_failure)) do
      :raise -> raise("simulated RPC receipt failure")
      :exit -> exit(:simulated_rpc_receipt_failure)
      :throw -> throw(:simulated_rpc_receipt_failure)
      nil -> :ok
    end

    Agent.get(pid, &Map.get(&1.receipts, hash))
  end
end
