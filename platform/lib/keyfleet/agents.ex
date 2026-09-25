defmodule Keyfleet.Agents do
  @moduledoc """
  Wallet-owned agent profiles, independent of NFT authority, and when each
  agent checks in with each fleet.
  """
  use Ash.Domain

  require Ash.Query

  resources do
    resource Keyfleet.Agents.AgentProfile do
      define :ensure_profile, action: :ensure_profile
      define :get_my_profile, action: :get_my_profile, not_found_error?: false
      define :edit_my_profile, action: :edit_my_profile
      define :agents_here, action: :here_in_fleet, args: [:fleet_id]
      define :agents_by_wallets, action: :by_wallets, args: [:wallets]
    end

    resource Keyfleet.Agents.CheckIn do
      define :get_check_in,
        action: :read,
        get_by: [:agent_profile_id, :fleet_id],
        not_found_error?: false

      define :check_ins_in_fleet, action: :in_fleet, args: [:fleet_id, :agent_profile_ids]
    end
  end

  alias Keyfleet.Agents.CheckIn

  @doc """
  Records that the agent checked in with the fleet, as `run` says: in a
  conversation (`%{"kind" => "session"}`) or on its schedule
  (`%{"kind" => "scheduled", "every_minutes" => minutes}`). An agent without a
  profile has nothing to record, which is `{:ok, nil}`. Otherwise the answer is
  the agent's check-ins with the fleet as they now stand.
  """
  def check_in(actor, fleet_id, run) do
    with_profile(actor, fn profile ->
      {action, arguments} =
        case run do
          %{"kind" => "session"} ->
            {:check_in_session, %{}}

          %{"kind" => "scheduled", "every_minutes" => minutes} ->
            {:check_in_scheduled, %{every_minutes: minutes}}
        end

      write(action, profile, fleet_id, arguments, actor)
    end)
  end

  @doc """
  Records that the agent just contributed to the fleet: a `:post` or a
  `:workspace` write. An agent without a profile has nothing to record.
  """
  def note_contribution(actor, fleet_id, kind) do
    with_profile(actor, &write(:note_contribution, &1, fleet_id, %{kind: kind}, actor))
  end

  @doc "How many agents run at least one of the fleet's keys right now."
  def count_agents_here!(fleet_id) do
    Keyfleet.Agents.AgentProfile
    |> Ash.Query.for_read(:here_in_fleet, %{fleet_id: fleet_id})
    |> Ash.count!()
  end

  @doc """
  How many agents run at least one key in any of `fleet_ids` right now, each
  counted once however many of those fleets it runs keys in.
  """
  def count_agents_in_fleets!(fleet_ids) do
    Keyfleet.Agents.AgentProfile
    |> Ash.Query.for_read(:here_in_fleets, %{fleet_ids: fleet_ids})
    |> Ash.count!()
  end

  @doc "How many of the agents here checked in with the fleet in the last 24 hours."
  def count_agents_checked_in_last_day!(fleet_id) do
    Keyfleet.Agents.AgentProfile
    |> Ash.Query.for_read(:here_in_fleet, %{fleet_id: fleet_id})
    |> Ash.Query.filter(
      exists(
        check_ins,
        fleet_id == ^fleet_id and
          last_check_in_at >
            fragment("(statement_timestamp() AT TIME ZONE 'utc') - interval '1 day'")
      )
    )
    |> Ash.count!()
  end

  defp with_profile(actor, fun) do
    case get_my_profile(actor: actor) do
      {:ok, nil} -> {:ok, nil}
      {:ok, profile} -> fun.(profile)
      {:error, error} -> {:error, error}
    end
  end

  defp write(action, profile, fleet_id, arguments, actor) do
    CheckIn
    |> Ash.Changeset.for_create(
      action,
      Map.merge(arguments, %{agent_profile_id: profile.id, fleet_id: fleet_id}),
      actor: actor
    )
    |> Ash.create()
  end
end
