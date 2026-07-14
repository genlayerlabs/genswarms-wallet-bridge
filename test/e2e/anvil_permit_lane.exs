# Real keeper chain layer → real EVM. Requires:
#   ( cd contracts && forge build )
#   anvil --silent &
# Run: mix run test/e2e/anvil_permit_lane.exs
alias DelegatedSpend.Evm.{Abi, Address, Artifacts, Rpc, Secp256k1}
alias DelegatedSpend.Keeper.{PermitLane, Signer}

defmodule E2E do
  def assert!(true, _label), do: :ok
  def assert!(other, label), do: raise("E2E FAIL #{label}: got #{inspect(other)}")

  def await_mined(signer, key, tries \\ 100) do
    case Signer.status(signer, key) do
      {:mined, hash} ->
        hash

      {:failed, hash} ->
        raise "E2E FAIL: tx failed on-chain #{hash}"

      _ when tries > 0 ->
        Signer.sweep_now(signer)
        Process.sleep(100)
        await_mined(signer, key, tries - 1)

      _ ->
        raise "E2E FAIL: timeout waiting for #{key}"
    end
  end

  def view(rpc, to, name, types, args, ret_types) do
    data = "0x" <> Base.encode16(Abi.encode_call(name, types, args), case: :lower)
    "0x" <> hex = Rpc.eth_call(rpc, to, data)
    Abi.decode_result(ret_types, Base.decode16!(hex, case: :mixed))
  end
end

rpc = System.get_env("E2E_RPC_URL", "http://127.0.0.1:8545")
keeper_priv = Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
user_priv = Base.decode16!("59C6995E998F97A5A0044966F0945389DC9E86DAE88C7A8412F4603B6B78690D")
user = Address.from_private_key(user_priv)

chain_id = Rpc.chain_id(rpc)

{:ok, signer} =
  Signer.start_link(rpc_url: rpc, chain_id: chain_id, priv: keeper_priv, sweep_ms: 3_600_000)

%{token: token_art, echo: echo_art} = Artifacts.load_all()
unhex = fn "0x" <> h -> Base.decode16!(h, case: :mixed) end

# 1) deploy MockERC20Permit + EchoSpendRouter (anchor = arbitrary nonzero)
{:ok, _} = Signer.submit(signer, "deploy-token", %{to: :create, data: unhex.(token_art.bytecode)})
tok_hash = E2E.await_mined(signer, "deploy-token")
%{"contractAddress" => token} = Rpc.receipt(rpc, tok_hash)

anchor_arg = Address.to_bytes("0x00000000000000000000000000000000000000A1")

ctor =
  Abi.encode_constructor(
    [:address, :address, :address],
    [Address.to_bytes(token), anchor_arg, <<0::160>>]
  )

{:ok, _} = Signer.submit(signer, "deploy-echo", %{to: :create, data: unhex.(echo_art.bytecode) <> ctor})
echo_hash = E2E.await_mined(signer, "deploy-echo")
%{"contractAddress" => echo} = Rpc.receipt(rpc, echo_hash)

# 2) mint the user 100 USDC-units
mint = Abi.encode_call("mint", [:address, {:uint, 256}], [Address.to_bytes(user), 100_000_000])
{:ok, _} = Signer.submit(signer, "mint", %{to: token, data: mint})
E2E.await_mined(signer, "mint")

# 3) user signs an EIP-2612 permit for the router (keeper never touches user keys —
#    this block plays the wallet dapp's role)
[domain_sep] = E2E.view(rpc, token, "DOMAIN_SEPARATOR", [], [], [{:bytes, 32}])
[nonce] = E2E.view(rpc, token, "nonces", [:address], [Address.to_bytes(user)], [{:uint, 256}])
deadline = Rpc.block_timestamp(rpc) + 3600
digest = PermitLane.permit_digest(domain_sep, user, echo, 25_000_000, nonce, deadline)
{r, s, recid} = Secp256k1.sign(digest, user_priv)
permit = %{owner: user, deadline: deadline, v: recid + 27, r: r, s: s}

# 4) keeper executes the permit-lane spend
topic = DelegatedSpend.Keccak.hash_256("e2e-topic")
order_id = DelegatedSpend.Keccak.hash_256("e2e-order-1")

config = %{
  with_permit_name: "payWithPermit",
  arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
}

calldata = PermitLane.build_call(config, [topic, 25_000_000, order_id], permit)
{:ok, _} = Signer.submit(signer, "spend-1", %{to: echo, data: calldata})
E2E.await_mined(signer, "spend-1")

# 5) funds landed at the beneficiary-bound destination; router holds nothing
[dest] =
  E2E.view(
    rpc,
    echo,
    "destinationFor",
    [{:bytes, 32}, :address],
    [topic, Address.to_bytes(user)],
    [:address]
  )

dest_hex = "0x" <> Base.encode16(dest, case: :lower)
[dest_bal] = E2E.view(rpc, token, "balanceOf", [:address], [dest], [{:uint, 256}])
[router_bal] = E2E.view(rpc, token, "balanceOf", [:address], [Address.to_bytes(echo)], [{:uint, 256}])
[user_bal] = E2E.view(rpc, token, "balanceOf", [:address], [Address.to_bytes(user)], [{:uint, 256}])
E2E.assert!(dest_bal == 25_000_000, "destination funded")
E2E.assert!(router_bal == 0, "router residual zero")
E2E.assert!(user_bal == 75_000_000, "user debited")

# 6) idempotency: same action_key returns the SAME hash, no second spend
{:ok, h1} = Signer.submit(signer, "spend-1", %{to: echo, data: calldata})
E2E.assert!(match?({:mined, ^h1}, Signer.status(signer, "spend-1")), "idempotent action_key")

# 7) THE anti-griefing invariant, live: a fresh action_key replaying the SAME
#    orderId fails SIMULATION → typed failure, zero gas, keeper nonce untouched.
nonce_before = Rpc.nonce(rpc, Signer.address(signer))

{:error, {:reverted, _}} =
  Signer.submit(signer, "spend-1-retry-new-key", %{to: echo, data: calldata})

nonce_after = Rpc.nonce(rpc, Signer.address(signer))
E2E.assert!(nonce_before == nonce_after, "no gas spent on failed simulation")

[dest_bal2] = E2E.view(rpc, token, "balanceOf", [:address], [dest], [{:uint, 256}])
E2E.assert!(dest_bal2 == 25_000_000, "no double spend")

IO.puts("anvil e2e OK: permit lane end-to-end (destination #{dest_hex})")

# ═══════════════════════════════════════════════════════════════════════════
# Part 2 (Plan 3): the FULL registry path — product object registers a
# server-authoritative order, the wallet dapp fetches it through the intake
# (verified initData), signs a real permit, posts the grant, the keeper
# executes, the result goes typed. Then the abuse cases.
# ═══════════════════════════════════════════════════════════════════════════
alias DelegatedSpend.Intake
alias DelegatedSpend.Intake.Rate
alias DelegatedSpend.Keeper
alias DelegatedSpend.Keeper.MemoryStore

bot_token = "1234567:TEST-fake-bot-token-for-vectors"
user_id = 777_000_111

make_init_data = fn uid ->
  fields = %{
    "auth_date" => Integer.to_string(System.os_time(:second)),
    "query_id" => "AAF03",
    "user" => ~s({"id":#{uid},"first_name":"A"})
  }

  dcs =
    fields
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

  secret = :crypto.mac(:hmac, :sha256, "WebAppData", bot_token)
  hash = :crypto.mac(:hmac, :sha256, secret, dcs) |> Base.encode16(case: :lower)
  URI.encode_query(Map.put(fields, "hash", hash))
end

store = MemoryStore.start()

{:ok, keeper} =
  Keeper.start_link(
    signer: signer,
    chain_id: chain_id,
    store: {MemoryStore, store},
    router: echo,
    action: %{with_permit_name: "payWithPermit", arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]},
    source_allowlist: ["market_phase"],
    order_ttl_s: 600,
    rpc_mod: Rpc,
    rpc: rpc,
    sweep_ms: 3_600_000
  )

ctx = %{
  bot_token: bot_token,
  max_age_s: 900,
  user_ref_fn: fn uid -> "ref-" <> Integer.to_string(uid) end,
  keeper: keeper,
  pinned: %{chain_id: chain_id, token: token, router: echo, version: "0.4.0"},
  rate: {Rate.start(60), 100}
}

# product object registers the order (contract-level order id is the APP's)
topic2 = DelegatedSpend.Keccak.hash_256("e2e-topic-2")
oid2 = DelegatedSpend.Keccak.hash_256("e2e-order-2")

{:ok, %{order_ref: order_ref, order_id: keeper_oid}} =
  Keeper.register_order(keeper, "market_phase", %{
    user_ref: "ref-#{user_id}",
    amount: 10_000_000,
    action_args: [topic2, 10_000_000, oid2]
  })

# Wallet dapp fetches the order through the intake
{200, order_view} =
  Intake.handle_order(
    %{"init_data" => make_init_data.(user_id), "order_ref" => order_ref, "v" => "0.4.0"},
    ctx
  )

E2E.assert!(order_view["amount"] == 10_000_000, "intake order fetch")

E2E.assert!(
  order_view["chain_id"] == chain_id,
  "order view carries the RUNTIME chain id (webapp config-drift gate input)"
)

# user signs the REAL permit for exactly the fetched amount
[nonce2] = E2E.view(rpc, token, "nonces", [:address], [Address.to_bytes(user)], [{:uint, 256}])
deadline2 = Rpc.block_timestamp(rpc) + 3600
digest2 = PermitLane.permit_digest(domain_sep, user, echo, order_view["amount"], nonce2, deadline2)
{r2, s2, recid2} = Secp256k1.sign(digest2, user_priv)

envelope = %{
  "v" => "0.4.0",
  "chain_id" => chain_id,
  "token" => token,
  "spender" => echo,
  "owner" => user,
  "value" => order_view["amount"],
  "deadline" => deadline2,
  "sig" => %{
    "v" => recid2 + 27,
    "r" => "0x" <> Base.encode16(r2, case: :lower),
    "s" => "0x" <> Base.encode16(s2, case: :lower)
  }
}

{200, %{"status" => "submitted"}} =
  Intake.handle_grant(
    %{"init_data" => make_init_data.(user_id), "order_ref" => order_ref, "permit" => envelope},
    ctx
  )

# result goes typed: sweep signer + keeper until mined
await_mined = fn tries ->
  Enum.reduce_while(1..tries, nil, fn _, _ ->
    Signer.sweep_now(signer)
    Keeper.sweep_now(keeper)

    case Keeper.order_status(keeper, keeper_oid) do
      {:mined, h} -> {:halt, h}
      _ -> Process.sleep(100) && {:cont, nil}
    end
  end)
end

mined_hash = await_mined.(100)
E2E.assert!(is_binary(mined_hash), "typed mined result")

[dest2] =
  E2E.view(rpc, echo, "destinationFor", [{:bytes, 32}, :address], [topic2, Address.to_bytes(user)], [:address])

[dest2_bal] = E2E.view(rpc, token, "balanceOf", [:address], [dest2], [{:uint, 256}])
E2E.assert!(dest2_bal == 10_000_000, "registry-path funds landed")

# replay of the whole grant POST: idempotent, no second spend
{200, %{"status" => replay_status}} =
  Intake.handle_grant(
    %{"init_data" => make_init_data.(user_id), "order_ref" => order_ref, "permit" => envelope},
    ctx
  )

E2E.assert!(replay_status in ["submitted", "mined"], "replay reports recorded status")
[dest2_bal2] = E2E.view(rpc, token, "balanceOf", [:address], [dest2], [{:uint, 256}])
E2E.assert!(dest2_bal2 == 10_000_000, "replay caused no second spend")

# a different verified user cannot see or spend the order
{404, _} =
  Intake.handle_order(%{"init_data" => make_init_data.(666), "order_ref" => order_ref, "v" => "0.4.0"}, ctx)

# expired order: typed failure, zero broadcast (keeper nonce untouched)
{:ok, keeper_fast} =
  Keeper.start_link(
    signer: signer,
    chain_id: chain_id,
    store: {MemoryStore, MemoryStore.start()},
    router: echo,
    action: %{with_permit_name: "payWithPermit", arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]},
    source_allowlist: ["market_phase"],
    order_ttl_s: 0,
    sweep_ms: 3_600_000
  )

{:ok, %{order_ref: stale_ref}} =
  Keeper.register_order(keeper_fast, "market_phase", %{
    user_ref: "ref-#{user_id}",
    amount: 10_000_000,
    action_args: [topic2, 10_000_000, DelegatedSpend.Keccak.hash_256("stale")]
  })

Process.sleep(1100)
nonce_before2 = Rpc.nonce(rpc, Signer.address(signer))

{422, %{"reason" => "expired"}} =
  Intake.handle_grant(
    %{"init_data" => make_init_data.(user_id), "order_ref" => stale_ref,
      "permit" => envelope},
    %{ctx | keeper: keeper_fast}
  )

E2E.assert!(Rpc.nonce(rpc, Signer.address(signer)) == nonce_before2, "expired: zero gas")

IO.puts("anvil e2e OK part 2: registry path (intake → keeper → chain), replay-safe, expiry typed")
