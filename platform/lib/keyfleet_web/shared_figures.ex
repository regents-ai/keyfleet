defmodule KeyfleetWeb.SharedFigures do
  @moduledoc """
  The readings every open page shares (`Keyfleet.SharedReading`), as a page
  follows them. A page names the keys each part of it shows, by group; it
  starts hearing a key before it reads it, so a change that lands while it
  reads still reaches it, and stops hearing the keys a part no longer shows.
  """

  import Phoenix.Component, only: [update: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Keyfleet.SharedReading

  @doc "Hears `keys` for `group`, and no longer the keys `group` heard before."
  def follow(socket, group, keys) do
    keys = MapSet.new(keys)
    held = Map.get(socket.assigns.shared, group, MapSet.new())

    if connected?(socket) do
      Enum.each(MapSet.difference(held, keys), &SharedReading.unsubscribe/1)
      Enum.each(MapSet.difference(keys, held), &SharedReading.subscribe/1)
    end

    update(socket, :shared, &Map.put(&1, group, keys))
  end

  @doc "The reading held for `key`, or nil while there is none."
  def reading(key) do
    case SharedReading.fetch(key) do
      {:ok, %{reading: reading}} -> reading
      :error -> nil
    end
  end
end
