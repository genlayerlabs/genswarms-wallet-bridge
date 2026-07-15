defmodule DelegatedSpend.Compliance.Store do
  @moduledoc """
  Storage behaviour for legal-compliance records.

  Only opaque or blinded `user_ref` values are allowed. Adapters must never
  store or log raw initData, tokens, Telegram or platform ids, or
  authentication bodies.

  `record_acceptance/2` must be atomic first-write-wins per
  `{user_ref, v_hash}` and must never overwrite the original evidence.
  `record_event/2` must append each event without replacing earlier events.
  """

  @type meta :: %{
          required(:ip) => term | nil,
          required(:country) => String.t() | nil,
          required(:user_agent) => String.t() | nil,
          required(:session_id) => term | nil
        }
  @type acceptance :: %{
          required(:user_ref) => term,
          required(:v_hash) => term,
          required(:account) => term,
          required(:sig) => %{required(:v) => term, required(:r) => term, required(:s) => term},
          required(:issued_at) => integer,
          required(:accepted_at) => integer,
          required(:meta) => meta
        }
  @type event :: %{
          required(:user_ref) => term,
          required(:kind) => String.t(),
          required(:at) => integer,
          required(:meta) => meta,
          required(:wallet) => term | nil,
          required(:order_ref) => term
        }

  @callback record_acceptance(ref :: term, acceptance) :: :ok
  @callback get_acceptance(ref :: term, user_ref :: term, v_hash :: term) :: acceptance | nil
  @callback record_event(ref :: term, event) :: :ok
  @callback events_for(ref :: term, user_ref :: term) :: [event]

  @empty_meta %{ip: nil, country: nil, user_agent: nil, session_id: nil}

  @doc "Normalizes server-owned request metadata into its persisted shape."
  def normalize_meta(meta) when is_map(meta) do
    %{
      ip: meta[:ip],
      country: normalize_country(meta[:country]),
      user_agent: normalize_user_agent(meta[:user_agent]),
      session_id: meta[:session_id]
    }
  end

  def normalize_meta(_), do: @empty_meta

  defp normalize_country(<<a, b>> = country)
       when (a in ?A..?Z or a in ?a..?z) and (b in ?A..?Z or b in ?a..?z),
       do: String.upcase(country)

  defp normalize_country(_), do: nil

  defp normalize_user_agent(value) when is_binary(value) and byte_size(value) > 256 do
    prefix = binary_part(value, 0, 256)

    case :unicode.characters_to_binary(prefix) do
      {:incomplete, valid, _} -> valid
      _ -> prefix
    end
  end

  defp normalize_user_agent(value) when is_binary(value), do: value
  defp normalize_user_agent(_), do: nil
end

defmodule DelegatedSpend.Compliance.MemoryStore do
  @moduledoc "Dependency-free Agent reference adapter for compliance records."
  @behaviour DelegatedSpend.Compliance.Store

  alias DelegatedSpend.Compliance.Store

  def start do
    {:ok, pid} = Agent.start_link(fn -> %{acceptances: %{}, events: []} end)
    pid
  end

  @impl true
  def record_acceptance(pid, acceptance) do
    acceptance = Map.update!(acceptance, :meta, &Store.normalize_meta/1)
    key = {acceptance.user_ref, acceptance.v_hash}

    Agent.update(pid, fn state ->
      %{state | acceptances: Map.put_new(state.acceptances, key, acceptance)}
    end)
  end

  @impl true
  def get_acceptance(pid, user_ref, v_hash),
    do: Agent.get(pid, & &1.acceptances[{user_ref, v_hash}])

  @impl true
  def record_event(pid, event) do
    event = Map.update!(event, :meta, &Store.normalize_meta/1)
    Agent.update(pid, &%{&1 | events: [event | &1.events]})
  end

  @impl true
  def events_for(pid, user_ref) do
    Agent.get(pid, fn state ->
      for event <- Enum.reverse(state.events), event.user_ref == user_ref, do: event
    end)
  end
end
