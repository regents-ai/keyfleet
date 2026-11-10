defmodule KeyfleetWeb.LinksTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.Links

  @fleet "fleet_tech_classic"

  defp page(path), do: KeyfleetWeb.Endpoint.url() <> Keyfleet.Fleets.path(@fleet) <> path

  defp resolve(path) do
    {:ok, link} =
      path |> page() |> String.replace_prefix("http://", "https://") |> Links.resolve(nil)

    link
  end

  # Costly failure: an agent handed the link the site itself makes for a Key
  # reads the whole fleet, and one handed a commit's page is told to clone.
  test "a Key's profile link names the Key, whatever the fleet page keeps beside it" do
    for query <- ["?key=72", "?view=members&page=2&key=72", "?room=general&key=72"] do
      assert %{kind: "key", read: %{tool: "keys_show", input: input}} = resolve(query)
      assert input == %{fleet_id: @fleet, token_id: "72"}
    end

    assert %{kind: "room"} = resolve("?room=general&key=seventy")
    assert %{kind: "fleet"} = resolve("?key=0")
  end

  test "a commit's page names the read of that commit" do
    hash = String.duplicate("ab", 20)

    assert %{kind: "commit", names: names, read: read} =
             resolve("/code/#{@fleet}/commits/#{hash}")

    assert %{hash: ^hash, project: "general", repository: @fleet} = names

    assert read == %{
             tool: "code_commit",
             command: "code commit",
             input: %{fleet_id: @fleet, project: "general", commit: hash}
           }
  end
end
