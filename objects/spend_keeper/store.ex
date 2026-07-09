defmodule DelegatedSpend.Keeper.Store do
  @moduledoc """
  Storage behaviour the consuming app implements (spec §5.3) — the
  security-relevant persistence interface for grants, server-authoritative
  orders, and in-flight submissions.

  Semantics every implementation MUST match (MemoryStore below is the
  reference; the SQL adapter's tests mirror these):

    * Orders are IMMUTABLE after `put_order` and consumed atomically exactly
      once: under concurrent `consume_order` calls, exactly one caller gets
      `{:ok, order}`.
    * All reads are scoped by `user_ref` — a wrong `user_ref` is
      indistinguishable from not-found (server-side authority, spec §6.1).
    * Grants are keyed by app-supplied opaque `user_ref` — never raw platform
      ids; implementations must never log grant bodies (spec §10).
    * `list_inflight/0` powers boot reconciliation: complete result delivery
      for transactions that mined while the keeper was down.
  """

  @type user_ref :: String.t()
  @type order :: %{
          required(:order_id) => String.t(),
          required(:order_ref) => String.t(),
          required(:user_ref) => user_ref,
          required(:amount) => non_neg_integer,
          required(:action_args) => list,
          required(:expires_at) => non_neg_integer,
          optional(:kind) => String.t(),
          optional(:tx) => map | nil,
          optional(:display) => map,
          optional(:expected_owner) => String.t() | nil
        }

  @callback put_grant(ref :: term, grant_ref :: String.t(), user_ref, grant :: map) :: :ok
  @callback get_grant(ref :: term, grant_ref :: String.t(), user_ref) :: map | nil
  @callback grants_for(ref :: term, user_ref) :: [map]
  @callback revoke_grant(ref :: term, grant_ref :: String.t(), user_ref) :: :ok
  @callback record_spend(ref :: term, user_ref, amount :: non_neg_integer, at :: integer) :: :ok
  @callback spent_since(ref :: term, user_ref, since :: integer) :: non_neg_integer

  @callback put_order(ref :: term, order) :: :ok
  @callback get_order(ref :: term, order_id :: String.t()) :: order | nil
  @callback get_order_by_ref(ref :: term, order_ref :: String.t(), user_ref) :: order | nil
  @callback consume_order(ref :: term, order_id :: String.t(), user_ref) ::
              {:ok, order} | :already_consumed | :not_found

  @callback put_inflight(ref :: term, order_id :: String.t(), action_key :: String.t()) :: :ok
  @callback update_inflight_hash(ref :: term, order_id :: String.t(), tx_hash :: String.t()) ::
              :ok
  @callback resolve_inflight(ref :: term, order_id :: String.t(), result :: term) :: :ok
  @callback list_inflight(ref :: term) :: [
              %{order_id: String.t(), action_key: String.t(), tx_hash: String.t() | nil}
            ]
end

defmodule DelegatedSpend.Keeper.MemoryStore do
  @moduledoc """
  Reference in-memory implementation of `DelegatedSpend.Keeper.Store` (Agent).
  Used by the package's own tests and the anvil e2e; the semantics here are
  the contract SQL adapters must reproduce.
  """
  @behaviour DelegatedSpend.Keeper.Store

  def start do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{grants: %{}, spends: [], orders: %{}, by_ref: %{}, consumed: %{}, inflight: %{}}
      end)

    pid
  end

  @impl true
  def put_grant(pid, grant_ref, user_ref, grant) do
    Agent.update(pid, &put_in(&1, [:grants, {grant_ref, user_ref}], Map.put(grant, :revoked, false)))
  end

  @impl true
  def get_grant(pid, grant_ref, user_ref),
    do: Agent.get(pid, &get_in(&1, [:grants, {grant_ref, user_ref}]))

  @impl true
  def grants_for(pid, user_ref) do
    Agent.get(pid, fn s ->
      for {{_gr, ur}, g} <- s.grants, ur == user_ref, do: g
    end)
  end

  @impl true
  def revoke_grant(pid, grant_ref, user_ref) do
    Agent.update(pid, fn s ->
      case get_in(s, [:grants, {grant_ref, user_ref}]) do
        nil -> s
        g -> put_in(s, [:grants, {grant_ref, user_ref}], %{g | revoked: true})
      end
    end)
  end

  @impl true
  def record_spend(pid, user_ref, amount, at),
    do: Agent.update(pid, &%{&1 | spends: [{user_ref, amount, at} | &1.spends]})

  @impl true
  def spent_since(pid, user_ref, since) do
    Agent.get(pid, fn s ->
      s.spends
      |> Enum.filter(fn {ur, _a, at} -> ur == user_ref and at >= since end)
      |> Enum.reduce(0, fn {_ur, a, _at}, acc -> acc + a end)
    end)
  end

  @impl true
  def put_order(pid, order) do
    Agent.update(pid, fn s ->
      s
      |> put_in([:orders, order.order_id], order)
      |> put_in([:by_ref, {order.order_ref, order.user_ref}], order.order_id)
    end)
  end

  @impl true
  def get_order(pid, order_id), do: Agent.get(pid, & &1.orders[order_id])

  @impl true
  def get_order_by_ref(pid, order_ref, user_ref) do
    Agent.get(pid, fn s ->
      with id when is_binary(id) <- get_in(s, [:by_ref, {order_ref, user_ref}]) do
        s.orders[id]
      end
    end)
  end

  @impl true
  def consume_order(pid, order_id, user_ref) do
    Agent.get_and_update(pid, fn s ->
      case s.orders[order_id] do
        nil ->
          {:not_found, s}

        %{user_ref: ^user_ref} = order ->
          if s.consumed[order_id],
            do: {:already_consumed, s},
            else: {{:ok, order}, put_in(s, [:consumed, order_id], true)}

        _wrong_user ->
          {:not_found, s}
      end
    end)
  end

  @impl true
  def put_inflight(pid, order_id, action_key) do
    Agent.update(
      pid,
      &put_in(&1, [:inflight, order_id], %{action_key: action_key, tx_hash: nil})
    )
  end

  @impl true
  def update_inflight_hash(pid, order_id, tx_hash) do
    Agent.update(pid, fn s ->
      case s.inflight[order_id] do
        nil -> s
        row -> put_in(s, [:inflight, order_id], %{row | tx_hash: tx_hash})
      end
    end)
  end

  @impl true
  def resolve_inflight(pid, order_id, result) do
    Agent.update(pid, fn s ->
      %{s | inflight: Map.delete(s.inflight, order_id)}
      |> Map.put(:last_result, {order_id, result})
    end)
  end

  @impl true
  def list_inflight(pid) do
    Agent.get(pid, fn s ->
      for {order_id, %{action_key: ak, tx_hash: h}} <- s.inflight,
          do: %{order_id: order_id, action_key: ak, tx_hash: h}
    end)
  end
end
