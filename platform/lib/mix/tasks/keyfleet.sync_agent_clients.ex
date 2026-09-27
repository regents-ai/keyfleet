defmodule Mix.Tasks.Keyfleet.SyncAgentClients do
  @shortdoc "Copies the pinned SIWA agent client into priv/agent, or checks it"

  @moduledoc """
  Keyfleet serves the SIWA agent client at `/agent/siwa_agent.py`, a
  byte-identical copy of the file in `elixir-utils` at the commit `mix.lock` pins
  for `siwa`, the one the image is built from. `priv/agent/clients.lock` records
  the served file's digest.

      mix keyfleet.sync_agent_clients           # copy the file and record its digest
      mix keyfleet.sync_agent_clients --check   # the served file matches the lock and the commit

  The file is read from the `siwa` dependency's own clone, which `mix deps.get`
  fetched. To upgrade, move the elixir-utils pin in `mix.exs`, run
  `mix deps.update siwa`, run the task and review the diff.
  """

  use Mix.Task

  @lock_path "priv/agent/clients.lock"
  @files ~w(siwa_agent.py)
  @source_dir "siwa/siwa-elixir/agent"

  @impl Mix.Task
  def run(args) do
    commit = elixir_utils_commit!()
    pinned = Map.new(@files, &{&1, pinned_bytes!(commit, &1)})

    case args do
      [] -> write!(commit, pinned)
      ["--check"] -> check!(commit, pinned)
      _ -> Mix.raise("usage: mix keyfleet.sync_agent_clients [--check]")
    end
  end

  defp write!(commit, pinned) do
    Enum.each(pinned, fn {file, bytes} -> File.write!(served_path(file), bytes) end)

    lock = %{
      "source" => "elixir-utils",
      "files" => Map.new(pinned, fn {file, bytes} -> {file, digest(bytes)} end)
    }

    File.write!(@lock_path, Jason.encode_to_iodata!(lock, pretty: true) ++ ["\n"])
    Mix.shell().info("Copied the agent client at #{commit}")
  end

  defp check!(commit, pinned) do
    lock = @lock_path |> File.read!() |> Jason.decode!()

    stale =
      Enum.reject(@files, fn file ->
        served = File.read(served_path(file))
        served == {:ok, pinned[file]} and lock["files"][file] == digest(pinned[file])
      end)

    if stale == [] do
      Mix.shell().info("Agent client matches #{commit}")
    else
      Mix.raise(
        "Agent client differs from #{commit}: #{Enum.join(stale, ", ")}. " <>
          "Run mix keyfleet.sync_agent_clients"
      )
    end
  end

  defp pinned_bytes!(commit, file) do
    repo = Mix.Project.deps_paths() |> Map.fetch!(:siwa)

    # Only the file's bytes are read; git says on stderr why it couldn't.
    case System.cmd("git", ["-C", repo, "show", "#{commit}:#{@source_dir}/#{file}"]) do
      {bytes, 0} -> bytes
      {_bytes, _status} -> Mix.raise("Can't read #{file} at #{commit} in #{repo}")
    end
  end

  defp elixir_utils_commit! do
    {:git, _url, commit, _opts} = Map.fetch!(Mix.Dep.Lock.read(), :siwa)
    commit
  end

  defp served_path(file), do: Path.join(Path.dirname(@lock_path), file)

  defp digest(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
