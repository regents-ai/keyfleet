defmodule Keyfleet.Projects.Publish do
  @moduledoc """
  Makes something public as one of the fleet's Keys, and takes it back
  (`Keyfleet.Projects.Publication`). The actor acts as the Key the same way a
  workspace write does (`Keyfleet.Graph.Checks.KeyActor`).

  Posts are made public into an active project of the fleet, from one of the
  fleet's rooms (never a Key's thread), over a range of at most
  `Publication.most_posts/0` places that holds at least one post written as
  the Key. Only the Key that made something public takes it back. A refusal
  says why in words (`Keyfleet.Projects.Errors.PublishError`).

  The room is read as the site reads it, whoever may read it: what is shown
  is what the Key chose to show, and only the posts written as that Key.
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Graph.Checks.KeyActor
  alias Keyfleet.Projects
  alias Keyfleet.Projects.Errors.{PublishError, UnknownProjectError}
  alias Keyfleet.Projects.Publication
  alias Keyfleet.Rooms

  @system %Keyfleet.Actors.System{}

  @impl true
  def run(input, opts, %{actor: actor}) do
    %{fleet_id: fleet_id, as_key: key} = input.arguments
    within = Application.fetch_env!(:keyfleet, :graph)[:check_timeout]

    with {:ok, _command} <- KeyActor.command(actor, fleet_id, key, nil, within) do
      step(Keyword.fetch!(opts, :step), fleet_id, key, input.arguments)
    end
  end

  defp step(:posts, fleet_id, key, %{project: project, room: room} = arguments) do
    %{from_seq: from, to_seq: to} = arguments

    with :ok <- active(fleet_id, project),
         :ok <- range(from, to),
         :ok <- room(fleet_id, room),
         :ok <- written(fleet_id, room, from, to, key) do
      Publication
      |> Ash.Changeset.for_create(
        :record,
        %{
          fleet_id: fleet_id,
          project: project,
          key: key,
          kind: :posts,
          room: room,
          from_seq: from,
          to_seq: to
        },
        actor: @system
      )
      |> Ash.create()
    end
  end

  defp step(:withdraw, fleet_id, key, %{id: id}) do
    case Ash.get(Publication, id, actor: @system, not_found_error?: false) do
      {:ok, %{fleet_id: ^fleet_id, key: ^key} = publication} ->
        with :ok <- Ash.destroy(publication, action: :remove, actor: @system),
             do: {:ok, publication}

      {:ok, %{fleet_id: ^fleet_id} = publication} ->
        refuse(:not_yours, "Key #{publication.key} made this public. Only that Key takes it back.")

      {:ok, _other} ->
        refuse(:unknown, "This fleet has nothing public by that id.")

      {:error, error} ->
        {:error, error}
    end
  end

  defp active(fleet_id, name) do
    case Projects.project(fleet_id, name, actor: @system) do
      {:ok, %{state: :active}} ->
        :ok

      {:ok, nil} ->
        {:error, UnknownProjectError.exception(fleet_id: fleet_id, project: name)}

      {:ok, project} ->
        refuse(:project_archived, "#{project.title} is archived. Make posts public in an active project.")

      {:error, error} ->
        {:error, error}
    end
  end

  defp range(from, to) when to < from,
    do: refuse(:range, "The last post comes after the first.")

  defp range(from, to) do
    if to - from < Publication.most_posts(),
      do: :ok,
      else: refuse(:range, "Make at most #{Publication.most_posts()} posts public at once.")
  end

  defp room(fleet_id, slug) do
    case Rooms.get_room(fleet_id, slug, authorize?: false) do
      {:ok, %{}} -> :ok
      {:ok, nil} -> refuse(:room_unknown, "This fleet has no room #{slug}.")
      {:error, error} -> {:error, error}
    end
  end

  defp written(fleet_id, room, from, to, key) do
    if Enum.any?(posts(fleet_id, room, from, to, key)),
      do: :ok,
      else: refuse(:none_written, "Key #{key} wrote no post there from #{from} to #{to}.")
  end

  @doc """
  The posts written as `key` in the fleet's room `room` from place `from` to
  `to`, oldest first, each with its author, read whoever may read the room.
  """
  def posts(fleet_id, room, from, to, key) do
    fleet_id
    |> Rooms.read_messages!(
      room,
      %{after_seq: from - 1, limit: to - from + 1},
      authorize?: false,
      load: [:reply_to_seq]
    )
    |> Enum.filter(&(&1.kind == :post and &1.as_key == key and &1.seq <= to))
  end

  defp refuse(code, words), do: {:error, PublishError.exception(code: code, words: words)}
end
