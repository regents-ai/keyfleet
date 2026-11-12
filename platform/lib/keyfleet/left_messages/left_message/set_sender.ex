defmodule Keyfleet.LeftMessages.LeftMessage.SetSender do
  @moduledoc """
  Makes the actor the message's sender: a signed-in person, by their name or
  short wallet; or a signed agent, by its profile, with its person once they
  have signed in here. An agent with no profile has no name to leave it under
  and is refused as `profile_not_found`. Nothing a caller sends can name the
  sender.
  """

  use Ash.Resource.Change

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.{Agent, Human}
  alias Keyfleet.Agents
  alias Keyfleet.LeftMessages.Refused
  alias Keyfleet.PublicIdentity

  @impl true
  def change(changeset, _opts, %{actor: %Human{} = human}) do
    account = Accounts.get_human_account!(human.human_account_id, actor: human)

    Ash.Changeset.force_change_attributes(changeset,
      human_account_id: account.id,
      sender_name: PublicIdentity.label(account)
    )
  end

  def change(changeset, _opts, %{actor: %Agent{} = agent}) do
    case Agents.get_my_profile!(actor: agent) do
      nil ->
        Ash.Changeset.add_error(changeset, Refused.exception(code: "profile_not_found"))

      profile ->
        Ash.Changeset.force_change_attributes(changeset,
          human_account_id: agent.human_account_id,
          agent_profile_id: profile.id,
          sender_name: profile.name
        )
    end
  end

  # Anyone else is refused by the action's policy.
  def change(changeset, _opts, _context), do: changeset
end
