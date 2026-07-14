defmodule DelegatedSpend.Keeper.Store do
  @moduledoc """
  Storage behaviour the consuming app implements (spec §5.3) — the
  security-relevant persistence interface for grants, server-authoritative
  orders, and durable execution status.

  Semantics every implementation MUST match (MemoryStore below is the
  reference; the SQL adapter's tests mirror these):

    * Orders are IMMUTABLE after `put_order` and consumed atomically exactly
      once: under concurrent `consume_order` calls, exactly one caller gets
      `{:ok, order}`.
    * User-facing order/grant reads are scoped by `user_ref` — a wrong
      `user_ref` is indistinguishable from not-found (server-side authority,
      spec §6.1). Internal reconciliation reads use server-minted `order_id`.
    * Grants are keyed by app-supplied opaque `user_ref` — never raw platform
      ids; implementations must never log grant bodies (spec §10).
    * `begin_execution/4` atomically consumes a permit order and creates its
      durable `:pending` execution record.
    * The first terminal resolution wins, and a mined resolution records its
      spend in the same atomic write.
    * Terminal status is retained for as long as its order remains queryable.
    * `list_inflight/1` returns only unresolved executions and every durable
      same-nonce transaction hash for reconciliation.
  """

  @type user_ref :: String.t()
  @type execution_status ::
          :unknown
          | :pending
          | {:submitted, String.t()}
          | {:mined, String.t()}
          | {:failed, term}
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

  @callback begin_execution(
              ref :: term,
              order_id :: String.t(),
              user_ref,
              action_key :: String.t()
            ) :: {:ok, order} | :already_consumed | :not_found
  @callback get_execution_status(ref :: term, order_id :: String.t()) :: execution_status
  @callback update_inflight_hash(ref :: term, order_id :: String.t(), tx_hash :: String.t()) ::
              :ok | :not_found
  @callback resolve_inflight(
              ref :: term,
              order_id :: String.t(),
              result :: {:mined, String.t()} | {:failed, term},
              at :: integer
            ) :: :new | :existing
  @callback list_inflight(ref :: term) :: [
              %{order_id: String.t(), action_key: String.t(), tx_hashes: [String.t()]}
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
        %{
          grants: %{},
          spends: [],
          orders: %{},
          by_ref: %{},
          consumed: %{},
          executions: %{},
          inflight: %{}
        }
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
  def begin_execution(pid, order_id, user_ref, action_key) do
    Agent.get_and_update(pid, fn s ->
      case s.orders[order_id] do
        nil ->
          {:not_found, s}

        %{user_ref: ^user_ref} = order ->
          cond do
            s.consumed[order_id] ->
              {:already_consumed, s}

            Map.get(order, :kind, "permit") != "permit" ->
              {:not_found, s}

            true ->
              next =
                s
                |> put_in([:consumed, order_id], true)
                |> put_in([:executions, order_id], :pending)
                |> put_in([:inflight, order_id], %{action_key: action_key, tx_hashes: []})

              {{:ok, order}, next}
          end

        _wrong_user ->
          {:not_found, s}
      end
    end)
  end

  @impl true
  def get_execution_status(pid, order_id),
    do: Agent.get(pid, &Map.get(&1.executions, order_id, :unknown))

  @impl true
  def update_inflight_hash(pid, order_id, tx_hash) do
    Agent.get_and_update(pid, fn s ->
      case s.inflight[order_id] do
        nil ->
          {:not_found, s}

        row ->
          if tx_hash in row.tx_hashes do
            {:ok, s}
          else
            next =
              s
              |> put_in([:inflight, order_id], %{row | tx_hashes: [tx_hash | row.tx_hashes]})
              |> put_in([:executions, order_id], {:submitted, tx_hash})

            {:ok, next}
          end
      end
    end)
  end

  @impl true
  def resolve_inflight(pid, order_id, result, at) do
    Agent.get_and_update(pid, fn s ->
      if terminal?(s.executions[order_id]) or not Map.has_key?(s.inflight, order_id) do
        {:existing, s}
      else
        spends =
          case {result, s.orders[order_id]} do
            {{:mined, _hash}, %{user_ref: user_ref, amount: amount}} ->
              [{user_ref, amount, at} | s.spends]

            _ ->
              s.spends
          end

        next = %{
          s
          | executions: Map.put(s.executions, order_id, result),
            inflight: Map.delete(s.inflight, order_id),
            spends: spends
        }

        {:new, next}
      end
    end)
  end

  @impl true
  def list_inflight(pid) do
    Agent.get(pid, fn s ->
      for {order_id, %{action_key: ak, tx_hashes: hashes}} <- s.inflight,
          do: %{order_id: order_id, action_key: ak, tx_hashes: hashes}
    end)
  end

  defp terminal?({:mined, _}), do: true
  defp terminal?({:failed, _}), do: true
  defp terminal?(_), do: false
end
