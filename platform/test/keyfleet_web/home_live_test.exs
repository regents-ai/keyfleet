defmodule KeyfleetWeb.HomeLiveTest do
  use KeyfleetWeb.ConnCase, async: false

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys}
  alias KeyfleetWeb.HomeLive

  # Invariants covered:
  # - smoke: 200 mount and the public-home landmark, outside the signed-in shell
  # - the four fleets in catalog order, each opening its own map
  # - sales figures for a deployed fleet, following its key changes
  # - launch-gate: internal links stay on the fleets' maps, the account page,
  #   the public documents, or in-page anchors the document owns

  @owner "0x" <> String.duplicate("a", 40)

  setup do
    Fleets.bootstrap_catalog!()
    :ok
  end

  test "SMOKE: the homepage mounts and keeps its landmark", %{conn: conn} do
    assert conn |> get("/") |> html_response(200)
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#public-home")
    refute has_element?(view, "#app-shell")
  end

  test "the four fleets are cards, in catalog order, each opening its map", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    ids = Fleets.catalog_ids()
    assert attribute(html, ".rl-fleet-card", "id") == Enum.map(ids, &"home-fleet-#{&1}")

    for %{id: id, name: name} <- Fleets.catalog() do
      assert has_element?(view, ~s(#home-fleet-#{id} a[href="/app/fleets/#{id}"] h3), name)
      assert has_element?(view, "#home-fleet-#{id} [data-fleet-progress]", "Not on sale yet")
    end

    assert has_element?(
             view,
             "#home-fleet-fleet_tech_classic p",
             "144 keys, every one at 10 USDC."
           )

    assert attribute(html, ".key-map-preview", "data-layout") ==
             ~w(fibonacci fibonacci classic accelerant)
  end

  test "a deployed fleet's card shows its sales and follows its key changes", %{conn: conn} do
    fleet = "fleet_tech_accelerant"
    deploy!(fleet)
    ChainHelpers.seed_cursor!(fleet)
    issue!(fleet, 1)

    {:ok, view, _html} = live(conn, "/")

    assert progress(view, fleet) == "1 of 2,000 keys sold · next key 10.5 USDC"
    assert has_element?(view, ~s(#home-fleet-preview-#{fleet}[data-minted="1"]))

    issue!(fleet, 2)
    send(view.pid, {:keys_changed, fleet, [2]})

    assert progress(view, fleet) == "2 of 2,000 keys sold · next key 11.025 USDC"
    assert has_element?(view, ~s(#home-fleet-preview-#{fleet}[data-minted="2"]))
  end

  test "a deployed fleet whose sales are still being read says so", %{conn: conn} do
    deploy!("fleet_tech_classic")
    ChainHelpers.open_cursor!("fleet_tech_classic")

    {:ok, view, _html} = live(conn, "/")

    assert progress(view, "fleet_tech_classic") == "Sales figures are catching up"
  end

  @open_paths ~w(/account /llms.txt /docs /about /contact /opportunities /privacy /terms)

  test "the public homepage links only to known pages and its own anchors", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    anchors = attribute(html, "[id]", "id")
    fleet_paths = Enum.map(Fleets.catalog_ids(), &"/app/fleets/#{&1}")

    for href <- attribute(html, "a", "href"),
        href != "/",
        not String.starts_with?(href, "https://") do
      assert href in @open_paths or href in fleet_paths or String.starts_with?(href, "#")
      if String.starts_with?(href, "#"), do: assert(String.trim_leading(href, "#") in anchors)
    end
  end

  test "the agent-readable homepage describes every fleet and links its map" do
    markdown = HomeLive.agent_markdown()

    for %{id: id, name: name} <- Fleets.catalog() do
      assert markdown =~ "## #{name}"
      assert markdown =~ "/app/fleets/#{id})"
    end

    assert markdown =~ "144 keys, every one at 10 USDC."
  end

  defp progress(view, fleet_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#home-fleet-#{fleet_id} [data-fleet-progress]")
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp deploy!(fleet_id) do
    fleet_id
    |> Fleets.get_fleet!()
    |> Fleets.record_deployment!(
      %{
        chain_id: 8_453,
        contract_address: "0x" <> String.duplicate("7", 40),
        rewards_address: "0x" <> String.duplicate("8", 40),
        votes_address: "0x" <> String.duplicate("9", 40),
        usdc_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        deployed_block: 1,
        trait_table_hash: "0x" <> String.duplicate("a", 64)
      },
      actor: %Actors.System{}
    )
  end

  defp issue!(fleet_id, token_id) do
    Keys.record_epoch!(
      %{
        fleet_id: fleet_id,
        token_id: token_id,
        ownership_epoch: 0,
        owner_wallet: @owner,
        block_number: 10 + token_id,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash:
          "0x" <> Base.encode16(:crypto.hash(:sha256, "#{fleet_id}/#{token_id}"), case: :lower),
        log_index: 0
      },
      actor: %Actors.System{}
    )
  end

  defp attribute(html, selector, name),
    do: html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
end
