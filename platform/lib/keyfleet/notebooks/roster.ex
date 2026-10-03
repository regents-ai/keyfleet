defmodule Keyfleet.Notebooks.Roster do
  @moduledoc """
  Brings one fleet's notebook hub in step with who holds the fleet's keys now.

  The first time, it sets the hub up: its first request makes this site's
  provisioner the hub's first user, then it makes the project the fleet's key
  holders work in and records it (`Keyfleet.Notebooks.Hub`).

  Then everyone who holds one of the fleet's keys, or an agent with an active
  shard of one, is an editor of that project; anyone else this site added
  loses their place, their open notebook connections close, and they are
  suspended in that hub, so nothing they hold there still lets them in. Someone
  who holds a key again is let back in.

  It runs whenever a key changes hands or a shard is issued or ended, and
  again when an issued shard runs out (`Keyfleet.Notebooks.Changes.UpdateRoster`),
  and for every fleet every ten minutes (`Keyfleet.Notebooks.Reconcile`). Every step is safe to repeat, and a
  run that fails part way is run again from the start. While the fleet's key
  ownership is still being read, it waits.

  Runs go one at a time (the `notebook_hubs` queue runs one job). One run per
  fleet waits to start at a time; a change made while one runs queues the
  next, so the last run always reads the latest owners. A run booked for when
  a shard runs out doesn't count as waiting, so it never holds back a run
  wanted now.
  """
  use Oban.Worker,
    queue: :notebook_hubs,
    max_attempts: 20,
    unique: [keys: [:fleet_id], period: :infinity, states: [:available, :retryable]]

  require Ash.Query

  alias Keyfleet.Actors.{Agent, Human, System}
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError
  alias Keyfleet.Notebooks
  alias Keyfleet.Notebooks.HubClient

  @project_name "Fleet notebooks"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"fleet_id" => fleet_id}}) do
    with true <- Notebooks.hub?(fleet_id) || {:cancel, :no_hub},
         {:ok, project_id} <- project(fleet_id),
         {:ok, holders} <- holders(fleet_id),
         {:ok, members} <- HubClient.members(fleet_id, project_id),
         {:ok, users} <- HubClient.users(fleet_id) do
      sync(fleet_id, project_id, holders, members, users)
    else
      {:error, %OwnershipRefreshingError{}} -> {:snooze, 15}
      other -> other
    end
  end

  defp project(fleet_id) do
    case Notebooks.project_id(fleet_id) do
      {:ok, nil} -> set_up(fleet_id)
      found -> found
    end
  end

  # The provisioner's first request is what makes it the hub's first user.
  defp set_up(fleet_id) do
    provisioner = HubClient.provisioner(fleet_id)

    with {:ok, projects} <- HubClient.projects(fleet_id),
         {:ok, project_id} <- ours(projects, provisioner) || create(fleet_id),
         {:ok, _hub} <- Notebooks.record_hub(fleet_id, project_id, actor: %System{}) do
      {:ok, project_id}
    end
  end

  defp ours(projects, provisioner) do
    Enum.find_value(projects, fn
      %{"id" => id, "name" => @project_name, "owner" => ^provisioner} -> {:ok, id}
      _project -> nil
    end)
  end

  defp create(fleet_id) do
    with {:ok, %{"id" => project_id}} <- HubClient.create_project(fleet_id, @project_name) do
      {:ok, project_id}
    end
  end

  # The subjects who hold one of the fleet's keys, or an active shard of one, now.
  defp holders(fleet_id) do
    wallets =
      Keyfleet.Keys.KeyAttachment
      |> Ash.Query.for_read(:current_in_fleet, %{fleet_id: fleet_id})
      |> Ash.stream!(actor: %System{}, batch_size: 100)
      |> Enum.map(& &1.owner_wallet)
      |> Enum.uniq()

    people =
      wallets
      |> Enum.chunk_every(100)
      |> Enum.flat_map(&Keyfleet.Accounts.accounts_holding_wallets!(&1, actor: %System{}))
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(&{Notebooks.subject(Human.for_account(&1)), Human.for_account(&1)})

    agents =
      wallets
      |> Enum.chunk_every(100)
      |> Enum.flat_map(&Keyfleet.Agents.agents_by_wallets!(&1, actor: %System{}))
      |> Enum.concat(Keyfleet.Agents.agents_with_shards_in!([fleet_id], actor: %System{}))
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn profile ->
        {Notebooks.agent_subject(profile.id),
         %Agent{
           wallet_address: profile.wallet_address,
           chain_id: 8453,
           verification_method: :eoa_recovery,
           audience: "keyfleet"
         }}
      end)

    Enum.reduce_while(people ++ agents, {:ok, MapSet.new()}, fn {subject, actor},
                                                                {:ok, holders} ->
      case Notebooks.member?(actor, fleet_id) do
        {:ok, true} -> {:cont, {:ok, MapSet.put(holders, subject)}}
        {:ok, false} -> {:cont, {:ok, holders}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp sync(fleet_id, project_id, holders, members, users) do
    # Each member this site added, by subject, with how the hub names it.
    members =
      for member <- members, subject = member_subject(member), into: %{}, do: {subject, member}

    managed = Enum.filter(users, &Notebooks.managed_subject?(&1["id"]))
    leaving = for %{"id" => id} <- managed, id not in holders, do: id
    leaving = Enum.uniq(leaving ++ Enum.reject(Map.keys(members), &(&1 in holders)))

    Enum.each(leaving, &Notebooks.end_access(fleet_id, &1))

    steps =
      Enum.concat([
        for(
          subject <- leaving,
          Map.has_key?(members, subject),
          do: fn ->
            HubClient.remove_member(fleet_id, project_id, member_ref(members[subject]))
          end
        ),
        for(
          %{"id" => id, "suspended_at" => nil} <- managed,
          id in leaving,
          do: fn -> HubClient.suspend(fleet_id, id) end
        ),
        for(
          %{"id" => id, "suspended_at" => at} <- managed,
          at != nil,
          id in holders,
          do: fn -> HubClient.reactivate(fleet_id, id) end
        ),
        for(
          subject <- holders,
          not Map.has_key?(members, subject),
          do: fn -> HubClient.add_editor(fleet_id, project_id, subject) end
        )
      ])

    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case step.() do
        {:ok, _answer} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp member_subject(%{"user_id" => id}), do: if(Notebooks.managed_subject?(id), do: id)
  defp member_subject(%{"email" => email}), do: Notebooks.subject_of_email(email)

  defp member_ref(%{"user_id" => id}), do: id
  defp member_ref(%{"email" => email}), do: email
end
