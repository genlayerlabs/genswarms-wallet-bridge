defmodule DelegatedSpend.Evm.ArtifactsTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Evm.Artifacts

  defp write_artifact(root, file, contract, bytecode \\ "0x6001") do
    dir = Path.join(root, file)
    File.mkdir_p!(dir)
    path = Path.join(dir, contract <> ".json")
    File.write!(path, Jason.encode!(%{"abi" => [%{"type" => "constructor"}], "bytecode" => %{"object" => bytecode}}))
    path
  end

  test "load_all reads the required Foundry artifacts" do
    root = tmp_dir()
    write_artifact(root, "MockERC20Permit.sol", "MockERC20Permit")
    write_artifact(root, "EchoSpendRouter.sol", "EchoSpendRouter", "0x6002")

    assert %{
             token: %{abi: [%{"type" => "constructor"}], bytecode: "0x6001"},
             echo: %{bytecode: "0x6002"}
           } = Artifacts.load_all(root)
  end

  test "load_all raises loudly when an artifact is missing" do
    root = tmp_dir()
    write_artifact(root, "MockERC20Permit.sol", "MockERC20Permit")

    assert_raise RuntimeError, ~r/missing artifact .*EchoSpendRouter/, fn ->
      Artifacts.load_all(root)
    end
  end

  test "default artifact directory either loads or reports why it cannot" do
    case Artifacts.load_all() do
      artifacts when is_map(artifacts) ->
        assert Map.has_key?(artifacts, :token)
        assert Map.has_key?(artifacts, :echo)
    end
  rescue
    e in RuntimeError ->
      assert e.message =~ "artifact"
  end

  test "load_all rejects empty or invalid bytecode" do
    root = tmp_dir()
    write_artifact(root, "MockERC20Permit.sol", "MockERC20Permit", "")
    write_artifact(root, "EchoSpendRouter.sol", "EchoSpendRouter")

    assert_raise RuntimeError, ~r/empty\/invalid bytecode for MockERC20Permit/, fn ->
      Artifacts.load_all(root)
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "delegated-spend-artifacts-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
