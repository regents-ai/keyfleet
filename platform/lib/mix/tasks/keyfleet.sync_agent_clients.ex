defmodule Mix.Tasks.Keyfleet.SyncAgentClients do
  @shortdoc "Copies the pinned SIWA agent client into priv/agent, or checks it"

  @moduledoc """
  Keyfleet serves the SIWA agent client at `/agent/siwa_agent.py`, a
  byte-identical copy of the file in the sibling `elixir-utils` repository at
  the commit `priv/agent/clients.lock` names.

      mix keyfleet.sync_agent_clients           # copy the file and record its digest
      mix keyfleet.sync_agent_clients --check   # the served file matches the lock and the commit

  The repository is found the way `mix.exs` finds shared dependencies: under
  `REGENT_DEPS_ROOT`, or else two directories above this project. Nothing is
  fetched from the network. To upgrade, change the commit in the lock, run the
  task and review the diff.
  """

  use Mix.Task

  @lock_path "priv/agent/clients.lock"
  @files ~w(siwa_agent.py)
  @source_dir "siwa/siwa-elixir/agent"

  @impl Mix.Task
  def run(args) do
    lock = @lock_path |> File.read!() |> Jason.decode!()
    pinned = Map.new(@files, &{&1, pinned_bytes!(lock["commit"], &1)})

    case args do
      [] -> write!(lock, pinned)
      ["--check"] -> check!(lock, pinned)
      _ -> Mix.raise("usage: mix keyfleet.sync_agent_clients [--check]")
    end
  end

  defp write!(lock, pinned) do
    Enum.each(pinned, fn {file, bytes} -> File.write!(served_path(file), bytes) end)

    lock = %{
      "source" => "elixir-utils",
      "commit" => lock["commit"],
      "files" => Map.new(pinned, fn {file, bytes} -> {file, digest(bytes)} end)
    }

    File.write!(@lock_path, Jason.encode_to_iodata!(lock, pretty: true) ++ ["\n"])
    Mix.shell().info("Copied the agent client at #{lock["commit"]}")
  end

  defp check!(lock, pinned) do
    stale =
      Enum.reject(@files, fn file ->
        served = File.read(served_path(file))
        served == {:ok, pinned[file]} and lock["files"][file] == digest(pinned[file])
      end)

    if stale == [] do
      Mix.shell().info("Agent client matches #{lock["commit"]}")
    else
      Mix.raise(
        "Agent client differs from #{lock["commit"]}: #{Enum.join(stale, ", ")}. " <>
          "Run mix keyfleet.sync_agent_clients"
      )
    end
  end

  defp pinned_bytes!(commit, file) do
    repo = Path.join(deps_root(), "elixir-utils")

    # Only the file's bytes are read; git says on stderr why it couldn't.
    case System.cmd("git", ["-C", repo, "show", "#{commit}:#{@source_dir}/#{file}"]) do
      {bytes, 0} -> bytes
      {_bytes, _status} -> Mix.raise("Can't read #{file} at #{commit} in #{repo}")
    end
  end

  defp deps_root,
    do: System.get_env("REGENT_DEPS_ROOT", Path.expand("../..", File.cwd!()))

  defp served_path(file), do: Path.join(Path.dirname(@lock_path), file)

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
