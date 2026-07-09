defmodule DelegatedSpend.Evm.RpcTest do
  use ExUnit.Case

  alias DelegatedSpend.Evm.Rpc

  setup do
    old_path = System.get_env("PATH") || ""
    bin = Path.join(System.tmp_dir!(), "delegated-spend-curl-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "curl"), """
    #!/bin/sh
    printf '%s' "$RPC_OUT"
    exit "${RPC_STATUS:-0}"
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)
    System.put_env("PATH", bin <> ":" <> old_path)
    System.delete_env("RPC_STATUS")
    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"result":"0x2a"}))

    on_exit(fn ->
      System.put_env("PATH", old_path)
      System.delete_env("RPC_OUT")
      System.delete_env("RPC_STATUS")
      File.rm_rf!(bin)
    end)

    :ok
  end

  test "call handles JSON-RPC result, RPC error, bad JSON, and curl failure" do
    assert {:ok, "0x2a"} = Rpc.call("http://rpc", "eth_chainId", [])

    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"no"}}))
    assert {:error, {:rpc_error, "eth_chainId", %{"code" => -1, "message" => "no"}}} =
             Rpc.call("http://rpc", "eth_chainId", [])

    System.put_env("RPC_OUT", "not json")
    assert {:error, {:bad_rpc_response, "eth_chainId", "not json"}} = Rpc.call("http://rpc", "eth_chainId", [])

    System.put_env("RPC_OUT", "curl sad")
    System.put_env("RPC_STATUS", "7")
    assert {:error, {:curl_failed, 7, "curl sad"}} = Rpc.call("http://rpc", "eth_chainId", [])
  end

  test "call! raises with method context on errors" do
    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"error":{"code":-1}}))

    assert_raise RuntimeError, ~r/rpc eth_chainId failed/, fn ->
      Rpc.call!("http://rpc", "eth_chainId", [])
    end
  end

  test "typed helpers map methods and decode hex values" do
    assert Rpc.hex_to_int("0x") == 0
    assert Rpc.hex_to_int("0x2a") == 42
    assert Rpc.hex_to_int(7) == 7

    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"result":"0x14a34"}))
    assert Rpc.chain_id("http://rpc") == 84_532
    assert Rpc.gas_price("http://rpc") == 84_532
    assert Rpc.nonce("http://rpc", "0xabc") == 84_532
    assert Rpc.block_number("http://rpc") == 84_532
    assert Rpc.balance("http://rpc", "0xabc") == 84_532
    assert Rpc.max_priority_fee("http://rpc") == 84_532

    assert {:ok, 84_532} = Rpc.estimate_gas("http://rpc", %{to: "0xabc"})
    assert Rpc.eth_call("http://rpc", "0xabc", "0x1234") == "0x14a34"
    assert Rpc.code("http://rpc", "0xabc") == "0x14a34"
    assert {:ok, "0x14a34"} = Rpc.send_raw("http://rpc", "0xraw")
    assert {:ok, "0x14a34"} = Rpc.eth_call_from("http://rpc", "0xfrom", "0xto", "0xdata")

    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"error":{"code":-32000}}))
    assert {:error, {:rpc_error, "eth_estimateGas", %{"code" => -32000}}} =
             Rpc.estimate_gas("http://rpc", %{to: "0xabc"})
  end

  test "block, receipt, and log helpers preserve structured RPC results" do
    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"result":{"timestamp":"0x64","baseFeePerGas":"0x5"}}))
    assert Rpc.block_timestamp("http://rpc") == 100
    assert Rpc.base_fee("http://rpc") == 5

    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"result":{"status":"0x1"}}))
    assert Rpc.receipt("http://rpc", "0xhash") == %{"status" => "0x1"}

    System.put_env("RPC_OUT", ~s({"jsonrpc":"2.0","id":1,"result":[{"data":"0x"}]}))
    assert Rpc.get_logs("http://rpc", %{}) == [%{"data" => "0x"}]
  end
end
