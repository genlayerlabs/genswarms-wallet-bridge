defmodule DelegatedSpend.FakeRpc do
  @moduledoc """
  Scripted RPC seam for Signer/BootCheck tests. Start with a config map; records
  every `send_raw` so tests can assert exactly what was (not) broadcast.
  The `rpc` handle IS the agent pid.
  """

  def start(config) do
    {:ok, pid} =
      Agent.start_link(fn -> Map.merge(%{sent: [], receipts: %{}, calls: []}, config) end)

    pid
  end

  def sent(pid), do: Agent.get(pid, & &1.sent) |> Enum.reverse()
  def put(pid, key, value), do: Agent.update(pid, &Map.put(&1, key, value))

  # Every `eth_call_from` (the Signer's pre-broadcast simulation) recorded in
  # order — the authorization-lane destination-guard test reads the LAST one
  # to see the exact `{to, data}` the keeper handed to the Signer, without
  # having to RLP-decode a fully signed transaction.
  def calls(pid), do: Agent.get(pid, &Map.get(&1, :calls, [])) |> Enum.reverse()

  # ── rpc_mod interface ──────────────────────────────────────────────────────
  # Failure knobs (default off, so existing tests are unaffected):
  #   :send_raw_fail  → send_raw returns {:error, reason}, records nothing
  #                     {:accepted, reason} records the tx, then returns the error
  #   :receipt_raises → receipt/2 raises (a transient-RPC crash simulation)
  #   :receipt_failure → :raise | :exit | :throw
  #   :fees_raise     → max_priority_fee raises (fees error path)
  #   :balance_raises → balance/2 raises (a transient-RPC crash simulation)
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

  # Task 3b: the gas-ceiling check (keeper) and the low-balance alarm
  # (signer sweep) each need one more typed reading. Configurable via
  # `:gas_price` / `:balance`, defaulting to values no economic-brake test
  # would ever trip by accident.
  def gas_price(pid), do: Agent.get(pid, &Map.get(&1, :gas_price, 1_000_000_000))

  def balance(pid, _addr) do
    if Agent.get(pid, &Map.get(&1, :balance_raises, false)),
      do: raise("simulated RPC balance failure")

    Agent.get(pid, &Map.get(&1, :balance, 1_000_000_000_000_000_000))
  end

  def block_timestamp(pid),
    do: Agent.get(pid, &Map.get(&1, :block_timestamp, System.os_time(:second)))

  def eth_call_from(pid, _from, to, data) do
    Agent.update(pid, &%{&1 | calls: [%{to: to, data: data} | &1.calls]})

    case Agent.get(pid, & &1.simulate) do
      :ok -> {:ok, "0x"}
      {:revert, info} -> {:error, info}
    end
  end

  # The keeper's boot-time reads on the authorization lane: DOMAIN_SEPARATOR()
  # (0x3644e515), name() (0x06fdde03) and version() (0x54fd4d50) — plain view
  # calls, no `from`. Dispatches by 4-byte selector so all three can be
  # answered DIFFERENTLY, the way a real token contract would.
  #
  # Defaults are SELF-CONSISTENT on purpose: the DOMAIN_SEPARATOR default is
  # COMPUTED (via the keeper's own `Eip3009.domain_separator/4`, production
  # code) from the SAME `:token_name`/`:token_version` defaults ("USDC"/"2")
  # that name()/version() answer, over the real `to` address and the
  # config's `:chain_id`. "USDC"/"2" are the real values on Base SEPOLIA's
  # USDC contract ONLY — externally verified against the live chain, see
  # `test/eip3009_test.exs`'s golden-vector test. Base MAINNET's USDC
  # answers name() == "USD Coin" (not "USDC"); this fixture deliberately
  # mirrors the Sepolia deployment `webapp/config.json` targets, and the
  # keeper's boot cross-check (this module's whole reason to dispatch by
  # selector) is exactly what would catch a mainnet copy of this default
  # being pointed at the wrong network. A test that doesn't
  # care about the domain fields still boots without wiring anything extra;
  # a test that wants the keeper's fail-closed mismatch/malformed-read raise
  # sets `:eth_call_result` (still honored, DOMAIN_SEPARATOR selector only —
  # e.g. a short "0xbad" for the malformed-read case) or `:token_name` /
  # `:token_version` (to make name()/version() disagree with the separator).
  def eth_call(pid, to, data) do
    case selector(data) do
      "3644e515" ->
        Agent.get(pid, fn s ->
          Map.get(s, :eth_call_result) || default_domain_separator(s, to)
        end)

      "06fdde03" ->
        Agent.get(pid, &encode_abi_string(Map.get(&1, :token_name, "USDC")))

      "54fd4d50" ->
        Agent.get(pid, &encode_abi_string(Map.get(&1, :token_version, "2")))

      _ ->
        Agent.get(pid, &Map.get(&1, :eth_call_result, "0x" <> String.duplicate("ab", 32)))
    end
  end

  defp selector("0x" <> hex), do: String.downcase(hex) |> String.slice(0, 8)
  defp selector(_), do: nil

  defp default_domain_separator(s, to) do
    name = Map.get(s, :token_name, "USDC")
    version = Map.get(s, :token_version, "2")

    ds = DelegatedSpend.Keeper.Eip3009.domain_separator(name, version, s.chain_id, to)
    "0x" <> Base.encode16(ds, case: :lower)
  end

  defp encode_abi_string(str) do
    len = byte_size(str)
    pad = rem(32 - rem(len, 32), 32)
    payload = str <> :binary.copy(<<0>>, pad)
    "0x" <> Base.encode16(<<32::256, len::256>> <> payload, case: :lower)
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
