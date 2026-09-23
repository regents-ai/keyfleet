defmodule KeyFleetWeb.RouteCatalogTest do
  use ExUnit.Case, async: true

  alias KeyFleetWeb.{RouteCatalog, Router}
  alias KeyFleetWeb.RouteCatalog.RouteTarget

  @paths [
    "/",
    "/app",
    "/account",
    "/app/fleets/:fleet_id",
    "/app/keys/:fleet_id/:token_id",
    "/app/fleets/:fleet_id/rooms/:slug",
    "/app/fleets/:fleet_id/workspace",
    "/app/fleets/:fleet_id/workspace/:object_id"
  ]

  test "contains exactly the approved pages" do
    assert Enum.map(RouteCatalog.entries(), & &1.path_pattern) == @paths
  end

  test "runtime GET router and catalog have identical paths, actions, order, and precedence" do
    runtime_routes =
      Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&(&1.verb == :get and &1.plug == Phoenix.LiveView.Plug))
      # Compile-disabled in production; the workshop has its own loopback gate.
      |> Enum.reject(fn route ->
        :local_showcase in Phoenix.Router.route_info(Router, "GET", route.path, "localhost").pipe_through
      end)
      |> Enum.map(&{&1.path, &1.plug_opts})

    catalog_routes = Enum.map(RouteCatalog.entries(), &{&1.path_pattern, &1.live_action})

    assert runtime_routes == catalog_routes
  end

  test "every catalog entry builds the route spec it declares, including /app" do
    assert Enum.all?(RouteCatalog.entries(), fn entry ->
             spec = RouteCatalog.fetch!(entry.live_action, sample_params(entry))
             spec.route_id == entry.route_spec_id
           end)

    app_entry = Enum.find(RouteCatalog.entries(), &(&1.path_pattern == "/app"))
    assert app_entry.route_spec_id == :app
    assert RouteCatalog.fetch!(:app).route_id == :app
  end

  test "the home page is the public landing outside the product shell" do
    home = RouteCatalog.fetch!(:home)

    assert home.route_id == :home
    assert home.destination == "/"
    assert home.app_id == nil
    assert home.app_display_label == nil
    assert home.page_display_label == "KeyFleet"
    assert home.canonical_root == "/"
    assert home.header_controls == []
    assert home.background_slot == :home
    assert home.content_transition_kind == :landing
    assert home.sidebar_model.id == :public
    assert home.sidebar_model.targets == []
  end

  test "the app overview is the product's canonical root" do
    app = RouteCatalog.fetch!(:app)

    assert app.route_id == :app
    assert app.destination == "/app"
    assert app.app_id == :product
    assert app.app_display_label == "KeyFleet"
    assert app.page_display_label == "Overview"
    assert app.canonical_root == "/app"
    assert app.header_controls == [:profile_actions]
    assert app.background_slot == :product
    assert app.content_transition_kind == :overview
    assert app.local_state == %{}
  end

  test "one key's page names the key it was asked for" do
    key = RouteCatalog.fetch!(:keys, %{"fleet_id" => "fibonacci_syndicate", "token_id" => "7"})

    assert key.route_id == :keys
    assert key.destination == "/app/keys/fibonacci_syndicate/7"
    assert key.page_display_label == "Key"
    assert key.canonical_root == "/app"
    assert key.content_transition_kind == :detail

    for params <- [
          %{"fleet_id" => "Fibonacci_syndicate", "token_id" => "7"},
          %{"fleet_id" => "fibonacci-syndicate", "token_id" => "7"},
          %{"fleet_id" => "fibonacci_syndicate", "token_id" => "07"},
          %{"fleet_id" => "fibonacci_syndicate", "token_id" => "0"},
          %{"fleet_id" => "fibonacci_syndicate", "token_id" => String.duplicate("9", 19)},
          %{"fleet_id" => "fibonacci_syndicate"}
        ] do
      assert_raise KeyFleetWeb.NotFoundError, fn -> RouteCatalog.fetch!(:keys, params) end
    end
  end

  test "a workspace item's page names the item it was asked for" do
    item =
      RouteCatalog.fetch!(:workspace_item, %{
        "fleet_id" => "fibonacci_syndicate",
        "object_id" => "launch_card#12"
      })

    assert item.route_id == :workspace_item
    assert item.destination == "/app/fleets/fibonacci_syndicate/workspace/launch_card%2312"
    assert item.page_display_label == "Workspace"
    assert item.canonical_root == "/app"

    assert RouteCatalog.fetch!(:workspace, %{"fleet_id" => "fibonacci_syndicate"}).destination ==
             "/app/fleets/fibonacci_syndicate/workspace"

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
      assert_raise KeyFleetWeb.NotFoundError, fn ->
        RouteCatalog.fetch!(:workspace_item, %{
          "fleet_id" => "fibonacci_syndicate",
          "object_id" => object_id
        })
      end
    end
  end

  test "account is the canonical product detail route" do
    account = RouteCatalog.fetch!(:account)

    assert account.route_id == :account
    assert account.destination == "/account"
    assert account.app_id == :product
    assert account.app_display_label == "KeyFleet"
    assert account.page_display_label == "Account"
    assert account.canonical_root == "/app"
    assert account.header_controls == [:profile_actions]
    assert account.background_slot == :product
    assert account.content_transition_kind == :detail
    assert account.local_state == %{}
  end

  test "the product sidebar lists Overview and Account on every product route" do
    for entry <- Enum.reject(RouteCatalog.entries(), &(&1.live_action == :home)) do
      assert RouteCatalog.fetch!(entry.live_action, sample_params(entry)).sidebar_model ==
               %RouteCatalog.SidebarModel{
                 id: :product,
                 targets: [
                   %RouteTarget{route_id: :app, label: "Overview", path: "/app"},
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
             spec = RouteCatalog.fetch!(entry.live_action, sample_params(entry))
             MapSet.subset?(MapSet.new(spec.header_controls), allowed_controls)
           end)
  end

  test "every route starts at the top" do
    assert Enum.all?(RouteCatalog.entries(), fn entry ->
             RouteCatalog.fetch!(entry.live_action, sample_params(entry)).scroll_policy == :top
           end)
  end

  test "Design handoff JSON and digest are deterministic" do
    first = RouteCatalog.design_handoff()
    second = RouteCatalog.design_handoff()

    assert first == second
    assert {:ok, decoded} = Jason.decode(first.json)
    assert length(decoded["routes"]) == 8

    assert Enum.map(decoded["routes"], & &1["route_id"]) == [
             "home",
             "app",
             "account",
             "fleet",
             "keys",
             "rooms",
             "workspace",
             "workspace_item"
           ]

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

             %{"type" => "heading", "label" => label} when is_binary(label) ->
               true

             _target ->
               false
           end)

    assert %{"sidebar_model" => %{"targets" => []}} =
             Enum.find(decoded["routes"], &(&1["route_id"] == "home"))

    assert %{"destination" => "/app/keys/:fleet_id/:token_id"} =
             Enum.find(decoded["routes"], &(&1["route_id"] == "keys"))
  end

  defp sample_params(%{parameter_schema: schema}) do
    Map.new(schema, fn
      {:fleet_id, _type} -> {"fleet_id", "fibonacci_syndicate"}
      {:token_id, _type} -> {"token_id", "1"}
      {:slug, _type} -> {"slug", "general"}
      {:object_id, _type} -> {"object_id", "task#12"}
    end)
  end
end
