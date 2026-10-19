defmodule KeyfleetWeb.RouteCatalogTest do
  use ExUnit.Case, async: true

  alias KeyfleetWeb.{RouteCatalog, Router}
  alias KeyfleetWeb.RouteCatalog.RouteTarget

  # Every fleet has the same pages under its own address.
  @fleet_pages [
    "",
    "/rooms/:slug",
    "/workspace",
    "/workspace/:object_id",
    "/code/:repository/commits/:commit",
    "/proposals",
    "/proposals/:number",
    "/treasury",
    "/polls",
    "/polls/:poll_id",
    "/keys/:token_id",
    "/keys/:token_id/dms",
    "/keys/:token_id/dms/:other_token_id"
  ]

  @paths [
           "/",
           "/account",
           "/account/points",
           "/account/wallets",
           "/account/connections",
           "/about",
           "/opportunities"
         ] ++
           for(
             fleet <-
               ~w(/classic/1 /syndicate/1 /cascade/1 /accelerant/1 /app/fleets/regents_club),
             page <- @fleet_pages,
             do: fleet <> page
           )

  test "contains exactly the approved pages" do
    assert Enum.map(RouteCatalog.entries(), & &1.path_pattern) == @paths
  end

  test "runtime GET router and catalog have identical paths, actions, order, and precedence" do
    runtime_routes =
      Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&(&1.verb == :get and &1.plug == Phoenix.LiveView.Plug))
      # Compile-disabled in production, the workshop has its own loopback gate;
      # the saved errors are ErrorTracker's own pages, for Credits admins only.
      |> Enum.reject(fn route ->
        pipes = Phoenix.Router.route_info(Router, "GET", route.path, "localhost").pipe_through
        :local_showcase in pipes or :errors_admin in pipes
      end)
      |> Enum.map(&{&1.path, &1.plug_opts})

    catalog_routes = Enum.map(RouteCatalog.entries(), &{&1.path_pattern, &1.live_action})

    assert runtime_routes == catalog_routes
  end

  test "every catalog entry builds the route spec it declares" do
    assert Enum.all?(RouteCatalog.entries(), fn entry ->
             spec = RouteCatalog.fetch!(entry.path_pattern, sample_params(entry))
             spec.route_id == entry.route_spec_id
           end)
  end

  test "the home page is the public landing outside the product shell" do
    home = RouteCatalog.fetch!("/")

    assert home.route_id == :home
    assert home.destination == "/"
    assert home.app_id == nil
    assert home.app_display_label == nil
    assert home.page_display_label == "Keyfleet"
    assert home.canonical_root == "/"
    assert home.header_controls == []
    assert home.background_slot == :home
    assert home.sidebar_model.id == :public
    assert home.sidebar_model.targets == []
  end

  test "one key's page names the key it was asked for" do
    key =
      RouteCatalog.fetch!("/syndicate/1/keys/:token_id", %{"token_id" => "7"})

    assert key.route_id == :keys
    assert key.fleet_id == "fibonacci_syndicate"
    assert key.destination == "/syndicate/1/keys/7"
    assert key.page_display_label == "Key"
    assert key.canonical_root == "/"

    for params <- [
          %{"token_id" => "07"},
          %{"token_id" => "0"},
          %{"token_id" => String.duplicate("9", 19)},
          %{}
        ] do
      assert_raise KeyfleetWeb.NotFoundError, fn ->
        RouteCatalog.fetch!("/syndicate/1/keys/:token_id", params)
      end
    end
  end

  test "a workspace item's page names the item it was asked for" do
    item =
      RouteCatalog.fetch!("/syndicate/1/workspace/:object_id", %{"object_id" => "task#12"})

    assert item.route_id == :workspace_item
    assert item.destination == "/syndicate/1/workspace/task%2312"
    assert item.page_display_label == "Workspace"
    assert item.canonical_root == "/"

    assert item.fleet_id == "fibonacci_syndicate"

    for object_id <- [
          "task",
          "task#0",
          "task#07",
          "Task#1",
          "#1",
          "task#1#2",
          "task#" <> String.duplicate("9", 19),
          "task/1",
          "rel_1"
        ] do
      assert_raise KeyfleetWeb.NotFoundError, fn ->
        RouteCatalog.fetch!("/syndicate/1/workspace/:object_id", %{"object_id" => object_id})
      end
    end
  end

  test "a proposal's page names the proposal it was asked for" do
    proposal =
      RouteCatalog.fetch!("/syndicate/1/proposals/:number", %{"number" => "3"})

    assert proposal.route_id == :proposal
    assert proposal.destination == "/syndicate/1/proposals/3"
    assert proposal.page_display_label == "Proposals"
    assert proposal.canonical_root == "/"

    for number <- ["0", "03", "-1", "1.5", "one", String.duplicate("9", 19)] do
      assert_raise KeyfleetWeb.NotFoundError, fn ->
        RouteCatalog.fetch!("/syndicate/1/proposals/:number", %{"number" => number})
      end
    end
  end

  test "account is the canonical product detail route" do
    account = RouteCatalog.fetch!("/account")

    assert account.route_id == :account
    assert account.destination == "/account"
    assert account.app_id == :product
    assert account.app_display_label == "Keyfleet"
    assert account.page_display_label == "Profile"
    assert account.canonical_root == "/"
    assert account.header_controls == [:profile_actions]
    assert account.background_slot == :product
    assert account.local_state == %{}
  end

  test "the product sidebar links Classic, the Regents Club, and Account on every product route" do
    for entry <- Enum.reject(RouteCatalog.entries(), &(&1.live_action == :home)) do
      assert RouteCatalog.fetch!(entry.path_pattern, sample_params(entry)).sidebar_model ==
               %RouteCatalog.SidebarModel{
                 id: :product,
                 targets: [
                   %RouteTarget{route_id: :fleet, label: "Classic #1", path: "/classic/1"},
                   %RouteTarget{
                     route_id: :fleet,
                     label: "Regents Club",
                     path: "/app/fleets/regents_club"
                   },
                   %RouteTarget{route_id: :account, label: "Account", path: "/account"}
                 ]
               }
    end
  end

  test "header controls use the closed contract" do
    allowed_controls =
      MapSet.new([
        :search,
        :filters,
        :view_switcher,
        :wallet_status,
        :network_status,
        :profile_actions
      ])

    assert Enum.all?(RouteCatalog.entries(), fn entry ->
             spec = RouteCatalog.fetch!(entry.path_pattern, sample_params(entry))
             MapSet.subset?(MapSet.new(spec.header_controls), allowed_controls)
           end)
  end

  test "every route starts at the top" do
    assert Enum.all?(RouteCatalog.entries(), fn entry ->
             RouteCatalog.fetch!(entry.path_pattern, sample_params(entry)).scroll_policy == :top
           end)
  end

  test "Design handoff JSON and digest are deterministic" do
    first = RouteCatalog.design_handoff()
    second = RouteCatalog.design_handoff()

    assert first == second
    assert {:ok, decoded} = Jason.decode(first.json)
    assert length(decoded["routes"]) == 72

    assert Enum.map(decoded["routes"], & &1["route_id"]) ==
             ~w(home account points wallets connections about opportunities) ++
               List.flatten(
                 List.duplicate(
                   ~w(fleet rooms workspace workspace_item code_commit proposals proposal treasury polls poll keys dms dm),
                   5
                 )
               )

    assert decoded["schema_version"] == 1
    assert first.digest == Base.encode16(:crypto.hash(:sha256, first.json), case: :lower)

    targets =
      decoded["routes"]
      |> Enum.flat_map(& &1["sidebar_model"]["targets"])

    assert targets != []

    assert Enum.all?(targets, fn
             %{"type" => "route", "destination" => path, "route_id" => route_id}
             when is_binary(path) and is_binary(route_id) ->
               true

             _target ->
               false
           end)

    assert %{"sidebar_model" => %{"targets" => []}} =
             Enum.find(decoded["routes"], &(&1["route_id"] == "home"))

    assert %{"destination" => "/classic/1/keys/:token_id"} =
             Enum.find(decoded["routes"], &(&1["route_id"] == "keys"))
  end

  defp sample_params(%{parameter_schema: schema}) do
    Map.new(schema, fn
      {:fleet_id, _type} -> {"fleet_id", "fibonacci_syndicate"}
      {:token_id, _type} -> {"token_id", "1"}
      {:other_token_id, _type} -> {"other_token_id", "2"}
      {:slug, _type} -> {"slug", "general"}
      {:object_id, _type} -> {"object_id", "task#12"}
      {:number, _type} -> {"number", "3"}
      {:poll_id, _type} -> {"poll_id", "3f1c6c2e-8a4b-4d2a-9b1e-0c5d7e9f1a2b"}
      {:repository, _type} -> {"repository", "fibonacci_syndicate"}
      {:commit, _type} -> {"commit", String.duplicate("a", 40)}
    end)
  end
end
