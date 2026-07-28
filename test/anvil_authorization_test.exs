defmodule DelegatedSpend.AnvilAuthorizationTest do
  use ExUnit.Case, async: false

  @anvil System.find_executable("anvil")
  @forge System.find_executable("forge")

  if is_binary(@anvil) and is_binary(@forge) do
    alias DelegatedSpend.Evm.{Abi, Address, Rpc, Secp256k1}
    alias DelegatedSpend.Keeper
    alias DelegatedSpend.Keeper.{Eip3009, MemoryStore, Signer}

    @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
    @treasury "0x" <> String.duplicate("99", 20)

    @tag :anvil
    @tag timeout: 120_000
    test "WB3(c): the chain rejects calldata whose signed destination or value is changed" do
      repo_root = Path.expand("..", __DIR__)
      contracts_root = Path.join(repo_root, "contracts")

      {build_output, 0} =
        System.cmd(
          @forge,
          [
            "build",
            "--offline",
            "--root",
            contracts_root,
            "test/mocks/MockEIP3009.sol"
          ],
          cd: repo_root,
          stderr_to_stdout: true
        )

      assert build_output =~ "Compiler run successful" or build_output =~ "No files changed"

      artifact_path =
        Path.join([
          contracts_root,
          "out",
          "MockEIP3009.sol",
          "MockEIP3009.json"
        ])

      bytecode =
        artifact_path
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["bytecode", "object"])
        |> String.replace_prefix("0x", "")
        |> Base.decode16!(case: :mixed)

      port_number = free_port()

      anvil_port =
        Port.open(
          {:spawn_executable, @anvil},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              "--silent",
              "--port",
              Integer.to_string(port_number),
              "--chain-id",
              "84532"
            ]
          ]
        )

      on_exit(fn ->
        if Port.info(anvil_port), do: Port.close(anvil_port)
      end)

      await_listener(port_number)
      rpc = "http://127.0.0.1:#{port_number}"
      chain_id = Rpc.chain_id(rpc)
      user = Address.from_private_key(@anvil0)

      {:ok, signer} =
        Signer.start_link(
          rpc_url: rpc,
          chain_id: chain_id,
          priv: @anvil0,
          sweep_ms: 3_600_000
        )

      {:ok, _} = Signer.submit(signer, "deploy-eip3009", %{to: :create, data: bytecode})
      deploy_hash = await_mined(signer, "deploy-eip3009")
      %{"contractAddress" => token} = Rpc.receipt(rpc, deploy_hash)

      mint =
        Abi.encode_call(
          "mint",
          [:address, {:uint, 256}],
          [Address.to_bytes(user), 1_000_000]
        )

      {:ok, _} = Signer.submit(signer, "mint-eip3009", %{to: token, data: mint})
      await_mined(signer, "mint-eip3009")

      store = MemoryStore.start()

      {:ok, keeper} =
        Keeper.start_link(
          chain_id: chain_id,
          store: {MemoryStore, store},
          source_allowlist: ["market_phase"],
          order_ttl_s: 600,
          treasury_address: @treasury,
          token_address: token,
          rpc_mod: Rpc,
          rpc: rpc,
          sweep_ms: 3_600_000
        )

      order_ref = String.duplicate("a3", 32)

      assert {:ok, %{order_ref: ^order_ref}} =
               Keeper.register_order(keeper, "market_phase", %{
                 order_ref: order_ref,
                 user_ref: "u1",
                 amount: 1_000_000,
                 action_args: [],
                 kind: "authorization_self"
               })

      valid_before = Rpc.block_timestamp(rpc) + 3_600
      nonce = DelegatedSpend.Orders.authorization_nonce(order_ref)
      domain = Eip3009.domain_separator("USDC", "2", chain_id, token)

      digest =
        Eip3009.authorization_digest(
          domain,
          user,
          @treasury,
          1_000_000,
          0,
          valid_before,
          nonce
        )

      {r, s, recid} = Secp256k1.sign(digest, @anvil0)

      auth = %{
        from: user,
        value: 1_000_000,
        valid_after: 0,
        valid_before: valid_before,
        signature: r <> s <> <<recid + 27>>
      }

      assert {:ok, %{to: ^token, data: data}} =
               Keeper.build_self_authorization(keeper, order_ref, "u1", auth)

      assert {:ok, "0x"} = Rpc.eth_call_from(rpc, user, token, data)

      attacker = "0x" <> String.duplicate("aa", 20)

      wrong_destination =
        Eip3009.transfer_with_authorization_calldata(
          user,
          attacker,
          auth.value,
          auth.valid_after,
          auth.valid_before,
          nonce,
          auth.signature
        )

      wrong_value =
        Eip3009.transfer_with_authorization_calldata(
          user,
          @treasury,
          auth.value - 1,
          auth.valid_after,
          auth.valid_before,
          nonce,
          auth.signature
        )

      assert {:error, {:rpc_error, "eth_call", _}} =
               Rpc.eth_call_from(rpc, user, token, wrong_destination)

      assert {:error, {:rpc_error, "eth_call", _}} =
               Rpc.eth_call_from(rpc, user, token, wrong_value)
    end

    defp free_port do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)
      port
    end

    defp await_listener(port, tries \\ 100)

    defp await_listener(port, tries) when tries > 0 do
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
        {:ok, socket} ->
          :ok = :gen_tcp.close(socket)

        {:error, _} ->
          Process.sleep(20)
          await_listener(port, tries - 1)
      end
    end

    defp await_listener(_port, 0), do: flunk("anvil did not listen within 2 seconds")

    defp await_mined(signer, key, tries \\ 100)

    defp await_mined(signer, key, tries) when tries > 0 do
      Signer.sweep_now(signer)

      case Signer.status(signer, key) do
        {:mined, hash} ->
          hash

        {:failed, hash} ->
          flunk("anvil transaction failed on-chain: #{hash}")

        _ ->
          Process.sleep(20)
          await_mined(signer, key, tries - 1)
      end
    end

    defp await_mined(_signer, key, 0), do: flunk("timed out waiting for #{key}")
  else
    missing =
      [{"anvil", @anvil}, {"forge", @forge}]
      |> Enum.filter(fn {_name, path} -> is_nil(path) end)
      |> Enum.map_join(", ", &elem(&1, 0))

    IO.puts("WB3(c) skipped: #{missing} not available on PATH")

    @tag :anvil
    @tag skip: "WB3(c) skipped: #{missing} not available on PATH"
    test "WB3(c): the chain rejects calldata whose signed destination or value is changed" do
      flunk("the skip tag must prevent this body from running")
    end
  end
end
