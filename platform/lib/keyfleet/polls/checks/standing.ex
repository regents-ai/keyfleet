defmodule Keyfleet.Polls.Checks.Standing do
  @moduledoc """
  Who may do what in a fleet's poll sessions, by the Key the actor takes part
  as (`Keyfleet.Polls.voter/2`): a person signed in on the site, an agent, or
  an agent paired with a person.

    * `role: :member`: anyone holding one of the fleet's Keys, or an active
      shard of one, lists the open sessions, opens one, joins one and votes.
    * `role: :seated`: anyone whose Key has a seat in the session reads its
      log, its rounds' observations and each Key's vote, and waits on it.
    * `role: :own_seat`: only the seat's own Key gives it up.
    * `role: :delegate`: only the delegate's Key opens rounds and ends the
      session.

  Standing is read from the Keys and their shards every time, so a Key
  changing hands or a shard ending moves it at once. While the fleet's Key
  ownership is not fresh, nobody has standing.
  """
  use Ash.Policy.SimpleCheck

  alias Keyfleet.Actors.System
  alias Keyfleet.Polls

  @impl true
  def describe(opts), do: "actor's Key is a #{Keyword.fetch!(opts, :role)} of the poll"

  @impl true
  def match?(actor, %{subject: subject}, opts) do
    fleet_id = value(subject, :fleet_id)

    with true <- Keyfleet.Chain.fresh?(fleet_id),
         %{key: key} <- Polls.voter(actor, fleet_id) do
      standing?(Keyword.fetch!(opts, :role), key, fleet_id, subject)
    else
      _no_standing -> false
    end
  end

  defp standing?(:member, _key, _fleet_id, _subject), do: true

  defp standing?(:seated, key, fleet_id, subject) do
    session_id = value(subject, :session_id) || value(subject, :id)

    in_fleet?(session_id, fleet_id) and
      Polls.get_seat!(session_id, key, actor: %System{}) != nil
  end

  defp standing?(:own_seat, key, fleet_id, %Ash.Changeset{
         data: %{token_id: key, session_id: session_id}
       }),
       do: in_fleet?(session_id, fleet_id)

  defp standing?(:own_seat, _key, _fleet_id, _subject), do: false

  defp standing?(:delegate, key, fleet_id, subject) do
    case session(value(subject, :session_id) || value(subject, :id), fleet_id) do
      %{delegate_key: ^key} -> true
      _other -> false
    end
  end

  defp in_fleet?(session_id, fleet_id), do: session(session_id, fleet_id) != nil

  defp session(session_id, fleet_id) when is_binary(session_id),
    do: Polls.get_session!(fleet_id, session_id, actor: %System{})

  defp session(_session_id, _fleet_id), do: nil

  defp value(%Ash.Changeset{} = changeset, name),
    do: Ash.Changeset.get_argument_or_attribute(changeset, name)

  defp value(%Ash.Query{} = query, name), do: Ash.Query.get_argument(query, name)
end
