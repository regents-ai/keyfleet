defmodule Keyfleet.Agents do
  @moduledoc """
  Wallet-owned agent profiles, independent of NFT authority, and when each
  agent checks in with each fleet.
  """
  use Ash.Domain

  import Ash.Expr, only: [expr: 1]
  require Ash.Query

  resources do
    resource Keyfleet.Agents.AgentProfile do
      define :ensure_profile, action: :ensure_profile
      define :get_my_profile, action: :get_my_profile, not_found_error?: false
      define :edit_my_profile, action: :edit_my_profile
      define :set_avatar, action: :set_avatar, args: [:avatar_key]
      define :remove_avatar, action: :remove_avatar
      define :agents_here, action: :here_in_fleet, args: [:fleet_id]
      define :agents_by_wallets, action: :by_wallets, args: [:wallets]
      define :listings, action: :listings, args: [:ids]
      define :agents_of_people, action: :of_people, args: [:human_ids]
      define :agents_here_in, action: :here_in_fleets, args: [:fleet_ids]
    end

    resource Keyfleet.Agents.Pairing do
      define :get_pairing, action: :by_wallet, args: [:wallet], not_found_error?: false
    end

    resource Keyfleet.Agents.CheckIn do
      define :get_check_in,
        action: :read,
        get_by: [:agent_profile_id, :fleet_id],
        not_found_error?: false

      define :check_ins_in_fleet, action: :in_fleet, args: [:fleet_id, :agent_profile_ids]
    end
  end

  alias Keyfleet.Agents.{Avatar, AvatarBucket, CheckIn, DeleteAvatar}

  @doc """
  How a check-in from an agent paired with a person's Regent account
  (`regent_agents`) names that person's Keyfleet account: by its display name,
  which is nil when they have none or no account here.
  """
  def account(privy_user_id) do
    account = Keyfleet.Accounts.get_by_privy_did!(privy_user_id, actor: %Keyfleet.Actors.System{})
    %{display_name: account && account.display_name}
  end

  @doc """
  The agent with its `pairing` (`Keyfleet.Actors.Agent`): the account of the
  person it is paired with, when it is backed by a person verified with World
  ID and that person has an account here; otherwise what it is missing.
  """
  def with_pairing(%Keyfleet.Actors.Agent{} = agent),
    do: %{agent | pairing: pairing(agent)}

  defp pairing(agent) do
    system = %Keyfleet.Actors.System{}

    case get_pairing!(agent.wallet_address, actor: system) do
      nil ->
        :none

      _paired when is_nil(agent.human_id) ->
        :not_backed

      %{privy_user_id: person} ->
        case Keyfleet.Accounts.get_by_privy_did!(person, actor: system) do
          nil -> :person_not_here
          account -> Keyfleet.Actors.Human.for_account(account)
        end
    end
  end

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

  @doc """
  Saves what the SIWA service said about the agent with this verified request
  onto its profile: its page in the agent registry, and the World ID person
  behind it with that person's agent count. The first person saved stays; a
  request naming nobody or someone else leaves them. Nothing is written when
  the request changes nothing, or when the agent has no profile yet;
  `ensure_profile` saves them when it makes one.
  """
  def save_listing(%Keyfleet.Actors.Agent{} = actor) do
    Keyfleet.Agents.AgentProfile
    |> Ash.Query.filter(wallet_address == ^actor.wallet_address)
    |> Ash.Query.filter(^listing_changes(actor))
    |> Ash.bulk_update!(:save_listing, %{}, actor: actor, strategy: :atomic, notify?: false)

    :ok
  end

  # The profiles this request would change: a new registry page, or a person
  # where none is saved, or a new count for the person saved.
  defp listing_changes(%{registry_url: url, human_id: nil}),
    do: expr(fragment("? IS DISTINCT FROM ?::text", registry_url, ^url))

  defp listing_changes(%{registry_url: url, human_id: person, same_person_agent_count: count}) do
    expr(
      fragment("? IS DISTINCT FROM ?::text", registry_url, ^url) or is_nil(human_id) or
        (human_id == ^person and same_person_agent_count != ^count)
    )
  end

  @doc """
  How many agents are here in the fleet: holding one of its keys or an active
  shard of one, or paired with a World ID person who holds one. `{:ok,
  count}`, or `{:error, failure}` when the database doesn't answer (see
  `Keyfleet.Count`).
  """
  def count_agents_here(fleet_id) do
    Keyfleet.Agents.AgentProfile
    |> Ash.Query.for_read(:here_in_fleet, %{fleet_id: fleet_id})
    |> Keyfleet.Count.of()
  end

  @doc """
  How many agents are here in any of `fleet_ids`, as `count_agents_here/1`
  counts them, each once however many of those fleets it is in, as `{:ok,
  count}` or `{:error, failure}`.
  """
  def count_agents_in_fleets(fleet_ids) do
    Keyfleet.Agents.AgentProfile
    |> Ash.Query.for_read(:here_in_fleets, %{fleet_ids: fleet_ids})
    |> Keyfleet.Count.of()
  end

  @doc """
  How many of the agents here checked in with the fleet in the last 24 hours,
  as `{:ok, count}` or `{:error, failure}`.
  """
  def count_agents_checked_in_last_day(fleet_id) do
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
    |> Keyfleet.Count.of()
  end

  @doc """
  Makes `bytes` the agent's picture, as it declared them (`Avatar.declare/1`)
  for its profile `profile_id`: checks them (`Avatar.check/2`), stores them in
  the bucket under a new key, then sets that key on the profile. Answers
  `{:ok, profile}`, `{:error, :mismatch | :unreadable}` for bytes that aren't
  what was declared or aren't such a picture, `{:error, :profile_not_found}`,
  or `{:error, reason}` when the bucket or the change fails. A picture stored
  whose change then fails is deleted again.
  """
  def store_avatar(actor, profile_id, declared, bytes) do
    with :ok <- Avatar.check(bytes, declared),
         {:ok, %{id: ^profile_id} = profile} <- get_my_profile(actor: actor),
         key = Avatar.new_key(profile_id, declared.content_type),
         :ok <- AvatarBucket.put(key, bytes, declared.content_type) do
      case set_avatar(profile, key, actor: actor) do
        {:ok, profile} ->
          {:ok, profile}

        {:error, error} ->
          Oban.insert!(DeleteAvatar.new(%{key: key}))
          {:error, error}
      end
    else
      {:ok, _other_or_none} -> {:error, :profile_not_found}
      {:error, reason} -> {:error, reason}
    end
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
