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

  # Costly failure: an agent handed the Atlas a person is looking at is told
  # the address names nothing, or reads a week's swarm where the page shows a
  # year's.
  test "the Atlas reads as the swarm it shows: its window, its day and its one kind" do
    atlas = resolve("/atlas?view=river&kind=notebooks&window=month&at=2026-11-02")
    assert Keyfleet.ContractSchema.errors(Map.put(atlas, :url, "atlas"), "Link") == []
    assert %{kind: "atlas", names: names, read: read} = atlas
    assert names == %{}

    assert read == %{
             tool: "atlas_swarm",
             command: "atlas swarm",
             input: %{
               fleet_id: @fleet,
               window: "month",
               at: "2026-11-02T00:00:00Z",
               source: "notebook"
             }
           }

    assert %{read: %{input: input}} = resolve("/atlas?show=list&window=hour&at=soon")
    assert input == %{fleet_id: @fleet, window: "year"}
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

  test "a file's page at a commit names the read of that file; the code as it stands now none" do
    hash = String.duplicate("ab", 20)
    files = "/code/#{@fleet}/files"

    assert %{kind: "code_files", read: read} = resolve("#{files}?path=lib%2Fapp.ex&at=#{hash}")

    assert read == %{
             tool: "code_file",
             command: "code file",
             input: %{fleet_id: @fleet, project: "general", commit: hash, path: "lib/app.ex"}
           }

    for now_or_top <- ["?path=lib%2Fapp.ex", "?at=#{hash}", ""] do
      assert %{kind: "code_files", read: nil} = resolve(files <> now_or_top)
    end
  end
end
