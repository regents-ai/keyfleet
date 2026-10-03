defmodule Mix.Tasks.Keyfleet.SyncApiContract do
  use Mix.Task

  @shortdoc "Syncs the canonical API contract to its served location"

  @source Path.expand("../../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @target Path.expand("../../../priv/static/api-contract.openapiv3.yaml", __DIR__)

  @impl Mix.Task
  def run([]) do
    contract = File.read!(@source)
    File.mkdir_p!(Path.dirname(@target))
    File.write!(@target, contract)
    Mix.shell().info("Synchronized API contract")
  end

  def run(["--check"]) do
    if File.exists?(@target) and File.read!(@target) == File.read!(@source),
      do: Mix.shell().info("API contract is synchronized"),
      else: Mix.raise("served API contract is out of sync")
  end

  def run(_args), do: Mix.raise("usage: mix keyfleet.sync_api_contract [--check]")
end
