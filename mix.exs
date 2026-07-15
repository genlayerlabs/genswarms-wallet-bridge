defmodule GenswarmsDelegatedSpend.MixProject do
  use Mix.Project

  # Package version is stamped here, in VERSION, vectors/VERSION and
  # webapp/config.json. CONTRACT_VERSION pins unchanged Solidity bytes.
  def project do
    [
      app: :genswarms_delegated_spend,
      version: "0.5.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Coverage ratchet (CI runs `mix test --cover`): the keeper sits at ~98%;
      # the build fails if the total regresses below the threshold.
      test_coverage: [summary: [threshold: 95]],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]

  defp elixirc_paths(:test), do: ["objects", "test/support"]
  defp elixirc_paths(_), do: ["objects"]

  defp deps do
    [
      {:ex_abi, "~> 0.8"},
      {:ex_rlp, "~> 0.6"},
      {:jason, "~> 1.4"}
    ]
  end
end
