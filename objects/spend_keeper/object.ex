defmodule DelegatedSpend.Keeper.Object do
  @moduledoc """
  The keeper's swarm-object door — a GenSwarms `ObjectHandler` over the
  `DelegatedSpend.Keeper` core.

  The keeper is a functional core with two doors:

    * **This message door** (async): other swarm objects register orders and
      manage backoff by sending JSON messages. The source identity is the
      framework-stamped `from` the ObjectServer hands to `handle_message/3`
      — for messages produced by another object's handler RETURN it is
      stamped by the framework and cannot be claimed in the payload.
    * **The call door** (sync): the app's intake HTTP glue keeps calling
      `Keeper.execute_with_permit/4` etc. directly — an HTTP response needs
      a synchronous answer, and end-user authority there is the platform
      auth (`DelegatedSpend.Intake`), not swarm identity.

  Because messages are one-way, the message door requires a CALLER-MINTED
  `order_ref` (64 lowercase hex chars, e.g. 32 random bytes hex-encoded):
  the sender already knows the ref it will put in the wallet dapp URL and does
  not need a reply to proceed. The keeper still enforces format and
  uniqueness. Every message is acknowledged with a `{:reply, json}` routed
  back to the sender; senders may ignore it (it is observability, not a
  required protocol step).

  This module implements the `Genswarms.Objects.ObjectHandler` contract
  (`init/1`, `handle_message/3`, `interface/0`, `handle_info/2`,
  `terminate/2`) structurally — the package does not depend on genswarms,
  so there is no `@behaviour` line; the ObjectServer dispatches by function,
  not by behaviour.

  ## Config

      %{name: :spend_keeper,
        handler: DelegatedSpend.Keeper.Object,
        config: %{keeper_opts: %{...Keeper.start_link opts...}}}

  Either:

    * `keeper_opts` — the object starts (and links) the keeper core itself;
      the message-door allowlist defaults to the core's `source_allowlist`.
    * `keeper` — pid (or name) of an already-running core; then
      `source_allowlist` must be given explicitly.

  The allowlist gates EVERY message-door action (an empty list fails
  closed). `register_order` is additionally re-checked by the core — the
  core's allowlist stays the single authority for registration.

  ## Message protocol (JSON)

      {"action": "register_order",
       "order": {"order_ref": "<64 lowercase hex>",
                 "user_ref": "...", "amount": 25000000,
                 "action_args": ["0x<hex>", 25000000, "0x<hex>"],
                 "expected_owner": "0x..."}}          // optional

      {"action": "order_status", "order_id": "0x..."}
      {"action": "reset_backoff", "user_ref": "..."}

  `action_args` carry EVM values over JSON: integers stay integers, `0x`-hex
  strings are decoded to raw binaries (matching the action's `arg_types`).
  """

  alias DelegatedSpend.Keeper

  @doc "ObjectHandler init — start or attach the keeper core."
  def init(config) do
    config = Map.new(config)

    case {Map.get(config, :keeper), Map.get(config, :keeper_opts)} do
      {nil, nil} ->
        {:error, :missing_keeper}

      {nil, opts} ->
        opts = Map.new(opts)

        case Keeper.start_link(opts) do
          {:ok, pid} ->
            allow = Map.get(config, :source_allowlist, Map.get(opts, :source_allowlist, []))
            {:ok, %{keeper: pid, allow: allow_set(allow), owned: true}}

          {:error, reason} ->
            {:error, reason}
        end

      {keeper, _} ->
        # Attaching to an external core: the door allowlist must be explicit
        # (there is nothing to inherit from). Missing → empty → fails closed.
        allow = Map.get(config, :source_allowlist, [])
        {:ok, %{keeper: keeper, allow: allow_set(allow), owned: false}}
    end
  end

  @doc "ObjectHandler handle_message — the authenticated async door."
  def handle_message(from, content, state) do
    source = to_string(from)

    reply =
      if MapSet.member?(state.allow, source) do
        case Jason.decode(content) do
          {:ok, %{"action" => action} = msg} -> dispatch(action, msg, source, state)
          _ -> err("bad_request", "not a JSON action message")
        end
      else
        err("unknown_source", source)
      end

    {:reply, Jason.encode!(reply), state}
  end

  @doc "ObjectHandler interface — shown by swarm-msg and the dashboard."
  def interface do
    %{
      register_order: %{
        input:
          "JSON {action: register_order, order: {order_ref (64 lowercase hex, caller-minted), " <>
            "user_ref, amount, action_args ([int | 0x-hex]), expected_owner?}}",
        output: "JSON ack {ok, order_ref, order_id, expires_at} | {ok: false, error}"
      },
      order_status: %{
        input: "JSON {action: order_status, order_id}",
        output: "JSON {ok, status: unknown|pending|submitted|mined|failed, ...}"
      },
      reset_backoff: %{
        input: "JSON {action: reset_backoff, user_ref}",
        output: "JSON {ok: true}"
      }
    }
  end

  @doc "ObjectHandler handle_info — the core owns its own timers; nothing here."
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "ObjectHandler terminate — stop the core only if this object started it."
  def terminate(_reason, %{owned: true, keeper: keeper}) do
    if is_pid(keeper) and Process.alive?(keeper), do: GenServer.stop(keeper, :normal, 5_000)
    :ok
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── dispatch ──────────────────────────────────────────────────────────────

  defp dispatch("register_order", %{"order" => order}, source, state) when is_map(order) do
    with {:ok, req} <- decode_order(order) do
      # The core re-checks `source` against ITS allowlist — registration
      # authority stays in one place even if the door's list drifts wider.
      case Keeper.register_order(state.keeper, source, req) do
        {:ok, ack} -> Map.merge(%{"ok" => true, "action" => "register_order"}, jsonable(ack))
        {:error, {:unknown_source, s}} -> err("unknown_source", s)
        {:error, reason} -> err(to_string(reason), "register_order refused")
      end
    else
      {:error, detail} -> err("bad_request", detail)
    end
  end

  defp dispatch("order_status", %{"order_id" => order_id}, _source, state)
       when is_binary(order_id) do
    case Keeper.order_status(state.keeper, order_id) do
      :unknown -> %{"ok" => true, "status" => "unknown"}
      :pending -> %{"ok" => true, "status" => "pending"}
      {:submitted, hash} -> %{"ok" => true, "status" => "submitted", "tx" => hash}
      {:mined, hash} -> %{"ok" => true, "status" => "mined", "tx" => hash}
      {:failed, reason} -> %{"ok" => true, "status" => "failed", "reason" => to_string(reason)}
    end
  end

  defp dispatch("reset_backoff", %{"user_ref" => user_ref}, _source, state)
       when is_binary(user_ref) do
    :ok = Keeper.reset_backoff(state.keeper, user_ref)
    %{"ok" => true, "action" => "reset_backoff"}
  end

  defp dispatch(action, _msg, _source, _state), do: err("bad_request", "unknown action #{action}")

  # ── order decoding (JSON → core request) ────────────────────────────────

  defp decode_order(order) do
    with ref when is_binary(ref) <- Map.get(order, "order_ref", {:error, "order_ref required"}),
         user_ref when is_binary(user_ref) <-
           Map.get(order, "user_ref", {:error, "user_ref required"}),
         amount when is_integer(amount) and amount >= 0 <-
           Map.get(order, "amount", {:error, "amount required"}),
         {:ok, args} <- decode_args(Map.get(order, "action_args")) do
      req = %{order_ref: ref, user_ref: user_ref, amount: amount, action_args: args}
      pass_order_options(order, req)
    else
      {:error, detail} -> {:error, detail}
      _ -> {:error, "order_ref/user_ref/amount malformed"}
    end
  end

  # EVM values over JSON: integers pass through, "0x…" hex decodes to raw
  # bytes. Anything else is rejected — no silent coercion into calldata.
  defp decode_args(args) when is_list(args) do
    Enum.reduce_while(args, {:ok, []}, fn arg, {:ok, acc} ->
      case decode_arg(arg) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :error -> {:halt, {:error, "action_args must be ints or 0x-hex strings"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp decode_args(_), do: {:error, "action_args must be a list"}

  defp decode_arg(n) when is_integer(n) and n >= 0, do: {:ok, n}

  defp decode_arg("0x" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} -> {:ok, bin}
      :error -> :error
    end
  end

  defp decode_arg(_), do: :error

  defp pass_order_options(order, req) do
    [
      {"expected_owner", :expected_owner, &is_binary/1, "expected_owner must be a string address"},
      {"kind", :kind, &is_binary/1, "kind must be a string"},
      {"tx", :tx, &is_map/1, "tx must be a map"},
      {"display", :display, &is_map/1, "display must be a map"},
      {"ttl_s", :ttl_s, fn v -> is_integer(v) and v > 0 end, "ttl_s must be a positive integer"}
    ]
    |> Enum.reduce_while({:ok, req}, fn {json_key, atom_key, valid?, error}, {:ok, acc} ->
      case Map.get(order, json_key) do
        nil ->
          {:cont, {:ok, acc}}

        value ->
          if valid?.(value),
            do: {:cont, {:ok, Map.put(acc, atom_key, normalize_order_option(atom_key, value))}},
            else: {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_order_option(:tx, tx) do
    tx
    |> take_string("to", :to)
    |> take_string("data", :data)
    |> take_int("value", :value)
  end

  defp normalize_order_option(_key, value), do: value

  defp take_string(tx, key, atom_key) do
    case Map.get(tx, key) do
      value when is_binary(value) -> Map.put(tx, atom_key, value)
      _ -> tx
    end
  end

  defp take_int(tx, key, atom_key) do
    case Map.get(tx, key) do
      value when is_integer(value) and value >= 0 -> Map.put(tx, atom_key, value)
      _ -> tx
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp allow_set(list), do: MapSet.new(Enum.map(List.wrap(list), &to_string/1))

  defp jsonable(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp err(code, detail), do: %{"ok" => false, "error" => code, "detail" => detail}
end
