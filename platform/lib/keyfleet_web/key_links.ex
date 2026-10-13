defmodule KeyfleetWeb.KeyLinks do
  @moduledoc """
  Where a key's profile opens: its fleet's page, with the key named in the
  address. The fleet page's tab (the hall, or the map with `view=map`) and its
  list position stay in the address beside it, so closing the profile leaves
  the page as it was.
  """

  @kept ["after", "before", "view"]

  @doc "The fleet page with key `token_id`'s profile open, keeping what `params` kept."
  def key_path(fleet_id, token_id, params \\ %{}),
    do: fleet_path(fleet_id, kept(params) ++ [{"key", token_id}])

  @doc "The fleet page with no key's profile open, keeping what `params` kept."
  def closed_path(fleet_id, params), do: fleet_path(fleet_id, kept(params))

  @doc "The fleet page's hall, its first tab."
  def hall_path(fleet_id), do: fleet_path(fleet_id, [])

  @doc "The fleet page's map of Keys, with the list of Keys under it."
  def map_path(fleet_id), do: fleet_path(fleet_id, [{"view", "map"}])

  defp kept(params), do: for(name <- @kept, is_binary(params[name]), do: {name, params[name]})

  defp fleet_path(fleet_id, []), do: Keyfleet.Fleets.path(fleet_id)

  defp fleet_path(fleet_id, query),
    do: "#{Keyfleet.Fleets.path(fleet_id)}?#{URI.encode_query(query)}"
end
