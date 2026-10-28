defmodule Keyfleet.Code do
  @moduledoc """
  Each fleet's shared code: one private git repository per project
  (`Keyfleet.Projects.Project`, `repository`), kept in Keyfleet's own code
  store (a Git server on a private address) and reached only through this
  site, at `https://<host>/<repository>.git`
  (`KeyfleetWeb.Plugs.CodeGateway`). A project's repository is made when the
  project starts (`Keyfleet.Code.Setup`).

  Whoever holds one of the fleet's keys, or an agent with an active shard of
  one or a pairing with a holder, may copy it and send changes; a key whose
  workspace edits a vote has restricted may only copy it. An agent signs each
  of git's requests with its own sign-in and is checked on every one; a
  person's git signs in with a password this site hands out
  (`KeyfleetWeb.CodePassword`), checked again at most every `access_ttl_ms`.
  A key changing hands ends everyone's admission to that fleet's code at once
  (`end_access/1`, from `Keyfleet.Chain.Scanner`).

  The store records every change under the wallet that holds the key, and
  this site keeps a line for each (`Keyfleet.Code.Push`), under its project,
  for the fleet's workspace to show.
  """
  use Ash.Domain

  alias Keyfleet.AccessCache
  alias Keyfleet.Actors.System
  alias Keyfleet.Code.{NodeClient, Push, RecordsDownError, Repository, Setup}
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Errors.{EditsRestrictedError, NotKeyHolderError}
  alias Keyfleet.{Keys, Projects}

  resources do
    resource Repository do
      define :record_repository, action: :record, args: [:repository, :owner]
      define :get_repository, action: :read, get_by: [:repository], not_found_error?: false
      define :forget_repository, action: :forget
    end

    resource Push do
      define :recent_pushes, action: :recent, args: [:fleet_id, :project]
      define :pushes_of_commit, action: :of_commit, args: [:fleet_id, :project, :head]
    end
  end

  @doc "The code store settings: `config :keyfleet, :code`."
  def config, do: Application.fetch_env!(:keyfleet, :code)

  @doc "The project's repository, as `{:ok, repository}`, or `{:ok, nil}` for no such project."
  def repository(fleet_id, project) do
    with {:ok, found} <- Projects.project(fleet_id, project, actor: %System{}),
         do: {:ok, found && found.repository}
  end

  @doc """
  The fleet a repository's name belongs to, `{:ok, fleet_id}`: the name is
  its fleet's id, then, for any project but `general`, a hyphen and the
  project's name (`Keyfleet.Projects.Project`); fleet ids hold no
  hyphen. `:error` for a name no project's repository could have.
  """
  def repository_fleet(repository) do
    case Regex.run(~r/\A([a-z0-9_]{1,64})(?:-[a-z0-9]+)*\z/, repository) do
      [_whole, fleet_id] -> {:ok, fleet_id}
      nil -> :error
    end
  end

  @doc """
  The address a person's git copies a project's repository from. It carries
  a user name, which the site ignores, so git asks only for the password.
  """
  def clone_url(repository),
    do: URI.to_string(%{address(repository) | userinfo: "holder"})

  @doc """
  The address an agent's git copies a project's repository from, through
  `git-remote-siwa`, which signs each request in place of a password.
  """
  def agent_clone_url(repository), do: URI.to_string(address(repository))

  defp address(repository) do
    %URI{
      scheme: "https",
      host: config()[:host],
      port: config()[:public_port],
      path: "/#{repository}.git"
    }
  end

  @doc """
  The path of one commit on this site: the fleet's address, the project's
  repository (as git copies it from `/<repository>.git`) and the commit's
  full hash. A workspace cites a commit by this path on the site's own
  address, never by a short hash or a branch, which move or collide.
  """
  def commit_path(fleet_id, repository, hash),
    do: "#{Keyfleet.Fleets.path(fleet_id)}/code/#{repository}/commits/#{hash}"

  @doc """
  The path of a file or folder in a project's repository on this site, `""`
  for the top folder, as it stands on the default branch now.
  """
  def files_path(fleet_id, repository, ""),
    do: "#{Keyfleet.Fleets.path(fleet_id)}/code/#{repository}/files"

  def files_path(fleet_id, repository, path),
    do: files_path(fleet_id, repository, "") <> "?" <> URI.encode_query(path: path)

  @doc """
  The path of a file or folder in a project's repository on this site at the
  commit `at`, or on the default branch for nil.
  """
  def files_path(fleet_id, repository, path, nil), do: files_path(fleet_id, repository, path)

  def files_path(fleet_id, repository, path, at) do
    query = if path == "", do: [at: at], else: [path: path, at: at]
    files_path(fleet_id, repository, "") <> "?" <> URI.encode_query(query)
  end

  @doc """
  Whether `path` names a place in the code: names joined by `/`, none of
  them empty, `.` or `..`.
  """
  def code_path?(path) do
    is_binary(path) and path != "" and String.valid?(path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  @doc """
  What the folder `path` holds on the default branch now, or at the commit
  `at`, `""` for the top:
  `{:ok, entries}`, folders first, each `%{name:, folder?:, size:}`; nothing
  while the fleet has no repository, and nothing for a folder that isn't
  there or a file. `{:error, error}` when the store can't be read.
  """
  def folder(repository, path, at \\ nil) do
    with {:ok, owner} when is_binary(owner) <- stored_owner(repository),
         {:ok, entries} <- NodeClient.tree(repository, owner, path, at) do
      {:ok,
       entries
       |> Enum.map(&%{name: &1["name"], folder?: &1["type"] == "tree", size: &1["size"]})
       |> Enum.sort_by(&{not &1.folder?, &1.name})}
    else
      {:ok, nil} -> {:ok, []}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  The file at `path` on the default branch now, or at the commit `at`:
  `{:ok, bytes}`, `{:ok, :too_large}` past `file_max_bytes`, `:not_found` (no repository yet
  included), or `{:error, error}` when the store can't be read.
  """
  def file(repository, path, at \\ nil) do
    case stored_owner(repository) do
      {:ok, nil} -> :not_found
      {:ok, owner} -> NodeClient.blob(repository, owner, path, at)
      {:error, error} -> {:error, error}
    end
  end

  # A page reads the code only once the repository is made: it never asks
  # for one to be made.
  defp stored_owner(repository) do
    with {:ok, made} <- get_repository(repository, actor: %System{}),
         do: {:ok, made && made.owner}
  end

  @doc "Whether `hash` is a commit's full hash, as git writes it: 40 or 64 lowercase hex digits."
  def full_hash?(hash),
    do: is_binary(hash) and String.match?(hash, ~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/)

  @doc "Where the fleet's pages hear that changes were sent to its code."
  def topic(fleet_id), do: "code:#{fleet_id}"

  @doc """
  Whether `actor` may use the fleet's code now: `{:ok, holder}` when it holds
  one of the fleet's keys or, for an agent, an active shard of one, where
  `holder` names the key, the wallet holding it and whether a vote has
  restricted the key's edits; `{:ok, nil}` when it holds neither; and
  `{:error, error}` when the fleet's key ownership can't be read right now.
  """
  def holder(actor, fleet_id) do
    case Keys.identity(actor, fleet_id) do
      nil -> {:ok, nil}
      %{token_id: token_id, wallet: wallet} -> standing(actor, fleet_id, token_id, wallet)
    end
  end

  defp standing(actor, fleet_id, token_id, wallet) do
    within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]
    holder = %{token_id: token_id, wallet: wallet, restricted?: false}

    holder =
      case actor do
        %Keyfleet.Actors.Agent{} ->
          Map.merge(holder, %{
            acting_agent_wallet: actor.wallet_address,
            beneficiary_privy_user_id: actor.privy_user_id,
            agent_pairing_id: actor.pairing_id
          })

        _ ->
          holder
      end

    case KeyActor.command(actor, fleet_id, token_id, "code", within) do
      {:ok, _command} -> {:ok, holder}
      {:error, %EditsRestrictedError{}} -> {:ok, %{holder | restricted?: true}}
      {:error, %NotKeyHolderError{}} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  What `subject` was found to hold when last let into the fleet's code, while
  that still stands, or what `check` finds now, kept for `access_ttl_ms` when
  it is a holder.
  """
  def admitted(fleet_id, subject, check) do
    case AccessCache.lookup(:code, fleet_id, subject) do
      {:ok, found} ->
        {:ok, found}

      :none ->
        with {:ok, %{} = found} <- check.() do
          AccessCache.admit(:code, fleet_id, subject, found, config()[:access_ttl_ms])
          {:ok, found}
        end
    end
  end

  @doc "Ends everyone's admission to the fleet's code on every node now."
  def end_access(fleet_id), do: AccessCache.end_fleet(:code, fleet_id)

  @doc """
  The owner the store keeps the repository under, as `{:ok, owner}`; while
  it is being made, `{:setting_up, seconds}` until the next try; once its
  setup gave up, which this ask queues again (`Setup.queue/1`),
  `:setup_restarted`; or `{:error, error}` when it can't be read.
  """
  def owner(repository) do
    case get_repository(repository, actor: %System{}) do
      {:ok, %Repository{owner: owner}} ->
        {:ok, owner}

      {:ok, nil} ->
        Setup.queue(repository)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Records the branches and tags `holder` moved in one push to the project's
  repository, each `%{ref:, head:}`, and tells the fleet's open pages. The
  store has already taken the push and git has its answer, so a push that
  can't be recorded is saved with the site's errors
  (`Keyfleet.Code.RecordsDownError`) and never raises.
  """
  def record_pushes(_fleet_id, _project, _holder, []), do: :ok

  def record_pushes(fleet_id, project, holder, updates) do
    updates
    |> Enum.map(
      &Map.merge(
        &1,
        Map.merge(
          %{
            fleet_id: fleet_id,
            project: project,
            token_id: holder.token_id,
            wallet: holder.wallet
          },
          Map.take(holder, [:acting_agent_wallet, :beneficiary_privy_user_id, :agent_pairing_id])
        )
      )
    )
    |> Ash.bulk_create(Push, :record,
      actor: %System{},
      return_errors?: true,
      stop_on_error?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} ->
        Phoenix.PubSub.broadcast(Keyfleet.PubSub, topic(fleet_id), {:code_pushed, fleet_id})

      %Ash.BulkResult{errors: errors} ->
        RecordsDownError.report(
          "A push to #{fleet_id}'s #{project} could not be recorded: " <>
            Enum.map_join(errors, ", ", &inspect(&1.__struct__))
        )

        :ok
    end
  end
end
