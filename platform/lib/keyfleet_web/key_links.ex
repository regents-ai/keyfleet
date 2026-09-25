defmodule KeyfleetWeb.KeyLinks do
  @moduledoc """
  Where a key's profile opens: its fleet's page, with the key named in the
  address. The fleet page's list position and any referral stay in the
  address beside it, so closing the profile leaves the page as it was.
  """

  @kept ["after", "before", "ref"]

  @doc "The fleet page with key `token_id`'s profile open, keeping what `params` kept."
  def key_path(fleet_id, token_id, params \\ %{}),
    do: fleet_path(fleet_id, kept(params) ++ [{"key", token_id}])

  @doc "The fleet page with no key's profile open, keeping what `params` kept."
  def closed_path(fleet_id, params), do: fleet_path(fleet_id, kept(params))

  defp kept(params), do: for(name <- @kept, is_binary(params[name]), do: {name, params[name]})

  defp fleet_path(fleet_id, []), do: "/app/fleets/#{fleet_id}"
  defp fleet_path(fleet_id, query), do: "/app/fleets/#{fleet_id}?#{URI.encode_query(query)}"
end
