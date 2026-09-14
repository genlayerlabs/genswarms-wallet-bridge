defmodule DelegatedSpend.ManifestTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  # The engine's `:require` loader compiles exactly the files listed in the
  # notarized entry; a module the keeper calls but the list omits only shows up
  # as an UndefinedFunctionError at boot or on the first order of that lane.
  test "swarm-object.json lists every objects/**/*.ex" do
    manifest = @root |> Path.join("swarm-object.json") |> File.read!() |> Jason.decode!()
    listed = manifest["files"]

    on_disk =
      @root
      |> Path.join("objects/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @root))

    assert listed -- on_disk == [], "listed but not on disk: #{inspect(listed -- on_disk)}"
    assert on_disk -- listed == [], "on disk but not listed: #{inspect(on_disk -- listed)}"
    assert listed == Enum.uniq(listed)
  end
end
