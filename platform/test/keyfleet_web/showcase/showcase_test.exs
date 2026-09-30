defmodule KeyfleetWeb.ShowcaseTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint KeyfleetWeb.Endpoint
  alias KeyfleetWeb.Showcase.{Catalog, LocalOnly, Sample, Utilities}

  defp local_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> put_private(:live_view_connect_info, %{
      peer_data: %{address: {127, 0, 0, 1}},
      uri: URI.parse("http://localhost/showcase")
    })
  end

  test "HTTP pages and machine inventory are loopback-only, without trusting forwarding headers" do
    for path <-
          ~w(/showcase /showcase/catalog /showcase/style.css /showcase/preview /showcase/privy /showcase/key-map) do
      for {host, peer} <- [{"example.com", {127, 0, 0, 1}}, {"localhost", {192, 0, 2, 1}}] do
        conn =
          build_conn()
          |> Map.put(:host, host)
          |> Map.put(:remote_ip, peer)
          |> put_req_header("x-forwarded-for", "127.0.0.1")
          |> put_req_header("x-forwarded-host", "localhost")
          |> get(path)

        assert response(conn, 404) == "Not found"
      end
    end

    conn = local_conn() |> get("/showcase/catalog")
    assert json_response(conn, 200)["components"] != []
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    reference = local_conn() |> get("/showcase/privy")
    assert html_response(reference, 200) =~ "Privy integration"
    assert get_resp_header(reference, "cache-control") == ["no-store"]
    assert LocalOnly.allowed?({0, 0, 0, 0, 0, 0, 0, 1}, "::1")
    refute LocalOnly.allowed?(nil, "localhost")
  end

  test "connected mount refuses remote and missing transport evidence" do
    for info <- [
          %{},
          %{peer_data: %{address: {192, 0, 2, 1}}, uri: URI.parse("http://localhost")},
          %{peer_data: %{address: {127, 0, 0, 1}}, uri: URI.parse("http://example.com")}
        ] do
      conn = local_conn() |> put_private(:live_view_connect_info, info)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/showcase")
    end
  end

  test "gallery connects, creates local Ash records, validates, and runs utilities" do
    {:ok, view, html} = live(local_conn(), "/showcase")
    assert html =~ "Shared foundations."
    assert has_element?(view, "input[type=color]")
    assert has_element?(view, "input[data-sc-shimmer-color][type=color]")
    assert has_element?(view, "#capabilities article.rg-feature", "Clear boundaries")
    assert has_element?(view, "#capabilities img[alt='Placeholder mark']")

    view |> element("button", "Create item") |> render_click()
    assert has_element?(view, "#empty-state-items", "Workshop item 1")
    refute has_element?(view, "#empty-state-demo", "Nothing here yet.")
    view |> element("#empty-state-demo button", "Add item") |> render_click()
    assert has_element?(view, "#empty-state-items", "Workshop item 2")
    view |> element("#empty-state-demo button", "Reset items") |> render_click()
    assert has_element?(view, "#empty-state-demo", "Nothing here yet.")

    view |> element("#showcase-step button", "Edit") |> render_click()
    assert has_element?(view, "#step-form")
    view |> form("#step-form", step: %{title: "x"}) |> render_submit()
    assert has_element?(view, "#step-title[aria-invalid=true][value=x]")
    view |> form("#step-form", step: %{title: "Revised step"}) |> render_submit()
    assert has_element?(view, "#showcase-step", "Revised step")
    refute has_element?(view, "#step-form")
    view |> element("#showcase-step button", "Edit") |> render_click()
    view |> element("#step-form button", "Cancel") |> render_click()
    assert has_element?(view, "#showcase-step", "Revised step")
    refute has_element?(view, "#step-form")

    assert has_element?(view, "#showcase-facts [data-sc-copy=showcase-facts-content]")

    assert has_element?(view, "[data-sc-privy-mode=fixture]", "Real sign-in is unavailable")
    assert has_element?(view, "[data-sc-privy-mode=fixture] button[disabled]", "Connect Privy")
    refute has_element?(view, "#account-control [data-account-target]")

    assert view
           |> form("#sample-form", sample: %{title: "Demo record", quantity: "2"})
           |> render_submit() =~ "Demo record × 2"

    assert view |> form("#sample-form", sample: %{title: "x", quantity: "0"}) |> render_submit() =~
             "aria-invalid=\"true\""

    assert view
           |> form("#utility-form", kind: "privy_valid")
           |> render_submit() =~ "Verified fixture"

    assert view |> element("#showcase-connections-github button") |> render_click() =~
             "No provider request"
  end

  test "active component inventory names exported functions and their attributes" do
    for {module, names} <- Catalog.registry() do
      Code.ensure_loaded!(module)
      for name <- names, do: assert(function_exported?(module, name, 1))
    end

    assert Enum.any?(Catalog.components(), &(&1.function == "field" and "label" in &1.attributes))

    assert Enum.any?(
             Catalog.components(),
             &(&1.function == "capability_card" and "media" in &1.slots)
           )
  end

  test "Ash sample validation uses no persistent data layer" do
    assert Ash.Resource.Info.data_layer(Sample) == Ash.DataLayer.Simple

    assert {:ok, %{title: "Valid", quantity: 2}} = create_sample(%{title: "Valid", quantity: 2})
    assert {:error, _} = create_sample(%{title: "x", quantity: 1})
    assert {:error, _} = create_sample(%{title: "Valid", quantity: 101})
    assert {:error, _} = create_sample(%{quantity: 1})
  end

  test "key map page sends every fleet's keys and shows the chosen key" do
    {:ok, view, html} = live(local_conn(), "/showcase/key-map")
    assert html =~ ~s(id="key-map-fibonacci")
    assert html =~ "No key chosen yet."

    render_hook(view, "keymap_ready", %{})
    assert_reply(view, %{minted: 17_768, max_supply: nil, mine: mine, agent: agent})
    mine = Base.decode64!(mine)
    agent = Base.decode64!(agent)
    # Only sold keys have owners and agents, so the bitsets end by key 17,768.
    assert byte_size(mine) <= 2_221 and byte_size(agent) <= 2_221
    assert held?(mine, 13) and not held?(mine, 14) and held?(agent, 3)

    assert render_hook(view, "select_key", %{"token_id" => 17_769}) =~ "Key 17,769 chosen."
    assert render_hook(view, "select_key", %{"token_id" => 17_770}) =~ "Key 17,769 chosen."
    assert render_hook(view, "select_key", %{"token_id" => 0}) =~ "Key 17,769 chosen."
    assert render_hook(view, "select_key", %{"token_id" => "7"}) =~ "Key 17,769 chosen."
    assert render_hook(view, "select_key", %{}) =~ "Key 17,769 chosen."
    assert render_hook(view, "show_fleet", %{"value" => "hexagon"}) =~ ~s(id="key-map-fibonacci")

    html = view |> element("button", "Classic") |> render_click()
    assert html =~ ~s(id="key-map-classic") and html =~ "No key chosen yet."
    render_hook(view, "keymap_ready", %{})
    assert_reply(view, %{minted: 1_023, max_supply: 1_024, mine: mine})
    assert byte_size(Base.decode64!(mine)) <= 128

    # Keys sold redraws the map at the new count, up to the whole fleet.
    assert render_hook(view, "select_key", %{"token_id" => 7}) =~ "Key 7 chosen."
    html = view |> form("#key-map-sold", %{minted: "4"}) |> render_change()
    assert html =~ "No key chosen yet."
    assert_push_event(view, "keymap:reset", %{})
    render_hook(view, "keymap_ready", %{})
    assert_reply(view, %{minted: 4, max_supply: 1_024})
    view |> form("#key-map-sold", %{minted: "0"}) |> render_change()
    render_hook(view, "keymap_ready", %{})
    assert_reply(view, %{minted: 0, mine: "", agent: ""})
    view |> form("#key-map-sold", %{minted: "5000"}) |> render_change()
    render_hook(view, "keymap_ready", %{})
    assert_reply(view, %{minted: 1_024})
  end

  defp held?(bits, id),
    do: Bitwise.band(:binary.at(bits, div(id - 1, 8)), Bitwise.bsl(1, rem(id - 1, 8))) != 0

  defp create_sample(params),
    do: Sample |> Ash.Changeset.for_create(:create, params) |> Ash.create()

  test "Privy fixture verifies actual signatures and rejects expiry and audience" do
    assert %{result: "Verified fixture", session_created: false} = Utilities.privy(:valid)
    assert %{reason: :token_expired} = Utilities.privy(:expired)
    assert %{reason: :invalid_audience} = Utilities.privy(:audience)
  end
end
