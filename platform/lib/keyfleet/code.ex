defmodule Keyfleet.Code do
  @moduledoc """
  Each fleet's shared code: one private git repository per fleet, kept in
  Keyfleet's own code store (a Twigpine node on a private address) and reached
  only through this site, at `https://<host>/<fleet id>.git`
  (`KeyfleetWeb.Plugs.CodeGateway`).

  Whoever holds one of the fleet's keys, or an agent with an active shard of
  one, may copy it and send changes; a key whose workspace edits a vote has
  restricted may only copy it. Git signs in with a password this site hands
  out (`KeyfleetWeb.CodePassword`). Each request is checked again at most every
  `access_ttl_ms`, and a key changing hands ends everyone's admission to that
  fleet's code at once (`end_access/1`, from `Keyfleet.Chain.Scanner`).

  The store records every change under the wallet that holds the key, and
  this site keeps a line for each (`Keyfleet.Code.Push`) for the fleet's
  workspace to show.
  """
  use Ash.Domain

  alias Keyfleet.AccessCache
  alias Keyfleet.Actors.System
  alias Keyfleet.Code.{Push, Repository, Setup}
  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Graph.Errors.{EditsRestrictedError, NotKeyHolderError}
  alias Keyfleet.Keys

  resources do
    resource Repository do
      define :record_repository, action: :record, args: [:fleet_id, :owner]
      define :get_repository, action: :read, get_by: [:fleet_id], not_found_error?: false
    end

    resource Push do
      define :recent_pushes, action: :recent, args: [:fleet_id]
      define :pushes_of_commit, action: :of_commit, args: [:fleet_id, :head]
    end
  end

  @doc "The code store settings: `config :keyfleet, :code`."
  def config, do: Application.fetch_env!(:keyfleet, :code)

  @doc "The address git copies the fleet's code from."
  def clone_url(fleet_id) do
    %URI{
      scheme: "https",
      host: config()[:host],
      port: config()[:public_port],
      path: "/#{fleet_id}.git"
    }
    |> URI.to_string()
  end

  @doc """
  The path of one commit in the fleet's code on this site: the fleet's
  address, its repository (named by the fleet, as git copies it from
  `/<fleet id>.git`) and the commit's full hash. A workspace cites a commit by
  this path on the site's own address, never by a short hash or a branch,
  which move or collide.
  """
  def commit_path(fleet_id, hash),
    do: "#{Keyfleet.Fleets.path(fleet_id)}/code/#{fleet_id}/commits/#{hash}"

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
  The owner the store keeps the fleet's repository under, as `{:ok, owner}`;
  while it is being made, which the first ask queues, `{:setting_up,
  seconds}` until the next try or `:setup_restarted` (`Setup.queue/1`); or
  `{:error, error}` when it can't be read.
  """
  def owner(fleet_id) do
    case get_repository(fleet_id, actor: %System{}) do
      {:ok, %Repository{owner: owner}} ->
        {:ok, owner}

      {:ok, nil} ->
        Setup.queue(fleet_id)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Records the branches and tags `holder` moved in one push, each `%{ref:,
  head:}`, and tells the fleet's open pages.
  """
  def record_pushes(_fleet_id, _holder, []), do: :ok

  def record_pushes(fleet_id, holder, updates) do
    updates
    |> Enum.map(
      &Map.merge(
        &1,
        Map.merge(
          %{fleet_id: fleet_id, token_id: holder.token_id, wallet: holder.wallet},
          Map.take(holder, [:acting_agent_wallet, :beneficiary_privy_user_id, :agent_pairing_id])
        )
      )
    )
    |> Ash.bulk_create!(Push, :record,
      actor: %System{},
      return_errors?: true,
      stop_on_error?: true
    )

    Phoenix.PubSub.broadcast(Keyfleet.PubSub, topic(fleet_id), {:code_pushed, fleet_id})
  end
end
