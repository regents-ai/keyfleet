defmodule Keyfleet.Graph.Checks.KeyActor do
  @moduledoc """
  Who may write a fleet's workspace as one of its keys: the person or agent
  whose wallet owns that key today, an agent holding an active shard of it
  whose wallet owns none of the fleet's keys, or an agent holding neither in
  the fleet that is paired with the person who owns the key today (`Keyfleet.Actors.Agent`'s `pairing`). A paired agent writes as its
  person's key, marked as its own: the stamp is the agent's, with its wallet.
  This is the rule rooms and direct messages use (`Keyfleet.Keys.identity/2`).
  Nobody writes as a key whose edits a vote of the fleet has restricted, its
  owner included.

  A write names the key it acts as. Standing is read from that key every
  time, and only while the fleet's key ownership is fresh, so a key changing
  hands moves the right to write with it, ends its shards, and an unknown
  owner grants nothing.

  Every key adds to the whole fleet's workspace, whatever kind of fleet it is;
  which objects a key may change is the fleet's writer's to answer
  (`Keyfleet.Graph.Workspace`).
  The policy asks first; the fleet's writer asks again when the write's turn
  comes, and only that answer lets the write through.

  Each check has a budget in milliseconds, the graph's `:check_timeout`, and
  every read it makes gets what is left of it; once it is spent, the check
  reads nothing more and answers `CheckExpiredError`. A read that fails or runs
  out of time answers the error it got.
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human
  alias Keyfleet.Graph.Errors.CheckExpiredError
  alias Keyfleet.Graph.Errors.EditsRestrictedError
  alias Keyfleet.Graph.Errors.NotKeyHolderError
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Errors.OwnershipRefreshingError

  @impl true
  def describe(_opts),
    do:
      "actor owns or holds a shard of the key it acts as, or is an agent paired with " <>
        "its owner, today, while the fleet's ownership is fresh and the key's edits are " <>
        "not restricted"

  # The Claude connector lists an agent's writes, and only an agent's, before
  # any write names a fleet or a key (`AshAi`); calling one runs the whole check.
  @impl true
  def match?(
        actor,
        %{subject: %Ash.ActionInput{context: %{private: %{ash_ai_pre_check?: true}}}},
        _opts
      ),
      do: is_struct(actor, Agent)

  def match?(actor, %{subject: %Ash.ActionInput{arguments: arguments}}, _opts) do
    within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]

    # A key whose edits are restricted passes here, so that the writer's own
    # check refuses the write and says why.
    case command(
           actor,
           arguments.fleet_id,
           arguments.as_key,
           Map.get(arguments, :command_id),
           within
         ) do
      {:ok, _command} -> true
      {:error, %EditsRestrictedError{}} -> true
      {:error, _error} -> false
    end
  end

  def match?(_actor, _context, _opts), do: false

  @doc """
  The command a write carries: its id, the member principal it is recorded
  under and the audit stamp of the standing that admits it, read now within
  `within` milliseconds.
  """
  def command(actor, fleet_id, token_id, command_id, within) do
    deadline = System.monotonic_time(:microsecond) + within * 1_000

    with {:ok, auth} <- authority(actor, fleet_id, token_id, deadline) do
      {:ok, %{id: command_id, principal: principal(auth), auth: auth}}
    end
  end

  @doc """
  Whether `actor` is in the fleet now, which is what reading its workspace
  takes: `{:ok, true}` when its wallet owns one of the fleet's keys today or,
  for an agent, it holds an active shard of one or is paired with a person who
  owns one; `{:ok, false}` when none of these; and `{:error, error}` when the
  fleet's key ownership can't be read right now, a refreshing one included. A read names no key: the one asked
  about is the key the actor is in the fleet as (`Keyfleet.Keys.identity/2`),
  its person's key for a paired agent.
  A key whose edits a vote has restricted still counts: holding it is what
  counts here. Read within `within` milliseconds, as `command/5` is.
  """
  def member(actor, fleet_id, within) do
    deadline = System.monotonic_time(:microsecond) + within * 1_000

    with %{token_id: token_id} <- Keys.identity(actor, fleet_id),
         {:ok, _reading} <- fresh_reading(fleet_id, deadline),
         {:ok, _standing} <- standing(actor, fleet_id, token_id, deadline) do
      {:ok, true}
    else
      nil -> {:ok, false}
      {:error, %NotKeyHolderError{}} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  As `member/3`, and also whether a vote of the fleet has restricted the
  edits of the key the actor is in the fleet as: `{:ok, %{token_id:,
  restricted?:}}` when it is in the fleet, `{:ok, nil}` when it is not, and
  `{:error, error}` when either can't be read right now. Read within
  `within` milliseconds, as `member/3` is.
  """
  def membership(actor, fleet_id, within) do
    deadline = System.monotonic_time(:microsecond) + within * 1_000

    with %{token_id: token_id} <- Keys.identity(actor, fleet_id),
         {:ok, _reading} <- fresh_reading(fleet_id, deadline),
         {:ok, _standing} <- standing(actor, fleet_id, token_id, deadline),
         {:ok, restricted?} <- restricted(fleet_id, token_id, deadline) do
      {:ok, %{token_id: token_id, restricted?: restricted?}}
    else
      nil -> {:ok, nil}
      {:error, %NotKeyHolderError{}} -> {:ok, nil}
      {:error, error} -> {:error, error}
    end
  end

  defp authority(actor, fleet_id, token_id, deadline) do
    with {:ok, reading} <- fresh_reading(fleet_id, deadline),
         {:ok, key} <- key_coordinate(fleet_id, token_id, deadline),
         {:ok, standing} <- standing(actor, fleet_id, token_id, deadline),
         :ok <- unrestricted(fleet_id, token_id, deadline) do
      {:ok,
       Map.merge(standing, %{
         key: key,
         checked_at: DateTime.to_iso8601(DateTime.utc_now()),
         # The last block the fleet's key ownership has been read through.
         chain_block: reading.next_block - 1
       })}
    end
  end

  defp fresh_reading(fleet_id, deadline) do
    with {:ok, opts} <- within(deadline, fleet_id) do
      case Keyfleet.Chain.fresh_cursor(fleet_id, opts) do
        {:ok, nil} -> {:error, OwnershipRefreshingError.exception(fleet_id: fleet_id)}
        other -> other
      end
    end
  end

  # A Key is named by its fleet's manager contract and its number in the
  # fleet. Only a deployed fleet's chain is read, and a deployment is for
  # good, so a fleet with a fresh reading always has its manager.
  defp key_coordinate(fleet_id, token_id, deadline) do
    with {:ok, opts} <- within(deadline, fleet_id),
         {:ok, fleet} <- Keyfleet.Fleets.get_fleet(fleet_id, [not_found_error?: true] ++ opts) do
      {:ok, %{chain_id: fleet.chain_id, contract: fleet.manager_address, token_id: token_id}}
    end
  end

  defp standing(actor, fleet_id, token_id, deadline) do
    with {:ok, opts} <- within(deadline, fleet_id) do
      holding(actor, fleet_id, token_id, opts)
    end
  end

  defp holding(%Human{wallet_addresses: wallets} = actor, fleet_id, token_id, opts) do
    case Keys.current_key(fleet_id, token_id, [actor: actor] ++ opts) do
      {:ok, %{owner_wallet: owner} = key} ->
        if owner in wallets,
          do: {:ok, stamp(key.ownership_epoch, "human", owner, nil)},
          else: not_a_holder(fleet_id, token_id)

      {:ok, nil} ->
        not_a_holder(fleet_id, token_id)

      error ->
        error
    end
  end

  defp holding(%Agent{} = actor, fleet_id, token_id, opts) do
    case Agent.refresh(actor) do
      {:ok, current} -> agent_holding(current, fleet_id, token_id, opts)
      _ -> not_a_holder(fleet_id, token_id)
    end
  end

  defp holding(_actor, fleet_id, token_id, _opts), do: not_a_holder(fleet_id, token_id)

  defp agent_holding(%Agent{wallet_address: wallet} = actor, fleet_id, token_id, opts) do
    case Keys.current_key(fleet_id, token_id, [actor: actor] ++ opts) do
      {:ok, %{owner_wallet: ^wallet} = key} ->
        {:ok, agent_stamp(key.ownership_epoch, actor)}

      {:ok, %{} = key} ->
        shard_holding(actor, key, opts)

      {:ok, nil} ->
        not_a_holder(fleet_id, token_id)

      error ->
        error
    end
  end

  # A wallet that owns one of the fleet's keys acts as its own key, never as
  # a shard or as its person.
  defp shard_holding(%Agent{wallet_address: wallet} = actor, key, opts) do
    read = [actor: actor] ++ opts

    with {:ok, nil} <- Keys.held_identity_key(key.fleet_id, [wallet], read),
         {:ok, %{} = shard} <- Keys.active_shard(key.fleet_id, key.token_id, wallet, read) do
      {:ok, agent_stamp(shard.ownership_epoch, actor)}
    else
      {:ok, nil} -> paired_holding(actor, key, read)
      {:ok, _held} -> not_a_holder(key.fleet_id, key.token_id)
      error -> error
    end
  end

  # An agent with a shard of any of the fleet's keys acts as that, never as
  # its person.
  defp paired_holding(%Agent{pairing: %Human{wallet_addresses: wallets}} = actor, key, read) do
    with true <- key.owner_wallet in wallets,
         {:ok, shards} <- Keys.active_shards_held_by(actor.wallet_address, read),
         false <- Enum.any?(shards, &(&1.fleet_id == key.fleet_id)) do
      {:ok, agent_stamp(key.ownership_epoch, actor)}
    else
      {:error, _error} = error -> error
      _not_its_person -> not_a_holder(key.fleet_id, key.token_id)
    end
  end

  defp paired_holding(_unpaired, key, _read), do: not_a_holder(key.fleet_id, key.token_id)

  defp agent_stamp(epoch, actor) do
    stamp(epoch, "agent", actor.wallet_address, actor.credential_ref)
    |> Map.merge(%{beneficiary_privy_user_id: actor.privy_user_id, pairing_id: actor.pairing_id})
  end

  defp stamp(ownership_epoch, kind, wallet, credential_ref),
    do: %{
      ownership_epoch: ownership_epoch,
      kind: kind,
      operator_wallet: wallet,
      credential_ref: credential_ref
    }

  defp unrestricted(fleet_id, token_id, deadline) do
    case restricted(fleet_id, token_id, deadline) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        {:error, EditsRestrictedError.exception(fleet_id: fleet_id, token_id: token_id)}

      error ->
        error
    end
  end

  defp restricted(fleet_id, token_id, deadline) do
    with {:ok, opts} <- within(deadline, fleet_id),
         do: Keys.edits_restricted?(fleet_id, token_id, opts)
  end

  # What is left of the check's budget, as the database's time limit for the
  # next read, in whole milliseconds. The database starts counting a limit
  # from the beginning of the millisecond the read is asked in, not from the
  # moment itself, so the limit is counted from there too and rounded up. A
  # limit counted from the moment could end up to a millisecond before the
  # budget does; counted this way it never ends before the budget, so a read
  # the database cuts off always means the budget is spent. A spent budget
  # reads nothing.
  defp within(deadline, fleet_id) do
    now = System.monotonic_time(:microsecond)

    if now < deadline do
      this_millisecond = Integer.floor_div(now, 1_000) * 1_000
      left = deadline - this_millisecond
      {:ok, [context: %{data_layer: %{timeout: div(left + 999, 1_000)}}]}
    else
      {:error, CheckExpiredError.exception(fleet_id: fleet_id)}
    end
  end

  defp not_a_holder(fleet_id, token_id),
    do: {:error, NotKeyHolderError.exception(fleet_id: fleet_id, token_id: token_id)}

  # The graph checks that the principal names exactly this key, epoch and wallet.
  defp principal(%{key: key} = auth),
    do:
      "member:#{key.chain_id}:#{key.contract}:#{key.token_id}" <>
        "@#{auth.ownership_epoch}/#{auth.kind}:#{auth.operator_wallet}"
end
