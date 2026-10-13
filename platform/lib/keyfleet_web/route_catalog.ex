defmodule KeyfleetWeb.RouteCatalog do
  @moduledoc "Canonical behavior metadata for the route allowlist."

  alias Keyfleet.Fleets
  alias KeyfleetWeb.NotFoundError

  alias __MODULE__.{
    Entry,
    NameOnly,
    RouteTarget,
    SidebarModel,
    Spec
  }

  @slug ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @fleet_id ~r/\A[a-z][a-z0-9_]{0,62}\z/
  # Eighteen digits at most, so every admitted key number is a database integer.
  @token_id ~r/\A[1-9][0-9]{0,17}\z/
  # A workspace item is named by its type and its number, such as `task#12`.
  @object_id ~r/\A[a-z][a-z_]{0,31}#[1-9][0-9]{0,17}\z/
  # Eighteen digits at most, so every admitted proposal number is a database integer.
  @number ~r/\A[1-9][0-9]{0,17}\z/
  # A poll is named by its id, a UUID in lower case.
  @poll_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @pages [
    %Entry{
      path_pattern: "/",
      live_action: :home,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :home
    },
    %Entry{
      path_pattern: "/account",
      live_action: :account,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :account
    },
    %Entry{
      path_pattern: "/account/points",
      live_action: :points,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :points
    },
    %Entry{
      path_pattern: "/account/wallets",
      live_action: :wallets,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :wallets
    },
    %Entry{
      path_pattern: "/account/connections",
      live_action: :connections,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :connections
    },
    %Entry{
      path_pattern: "/about",
      live_action: :about,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :about
    },
    %Entry{
      path_pattern: "/opportunities",
      live_action: :opportunities,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :opportunities
    },
    %Entry{
      path_pattern: "/app/keys/:fleet_id/:token_id",
      live_action: :keys,
      parameter_schema: %{fleet_id: :fleet_id, token_id: :token_id},
      reserved_values: %{},
      route_spec_id: :keys
    },
    %Entry{
      path_pattern: "/app/keys/:fleet_id/:token_id/dms",
      live_action: :dms,
      parameter_schema: %{fleet_id: :fleet_id, token_id: :token_id},
      reserved_values: %{},
      route_spec_id: :dms
    },
    %Entry{
      path_pattern: "/app/keys/:fleet_id/:token_id/dms/:other_token_id",
      live_action: :dm,
      parameter_schema: %{fleet_id: :fleet_id, token_id: :token_id, other_token_id: :token_id},
      reserved_values: %{},
      route_spec_id: :dm
    }
  ]

  # The pages every fleet has, each under the fleet's own address
  # (`Keyfleet.Fleets.path/1`): the fleet's page itself, then its rooms,
  # workspace, proposals and polls.
  @fleet_pages [
    {"", :fleet, %{}},
    {"/rooms/:slug", :rooms, %{slug: :slug}},
    {"/workspace", :workspace, %{}},
    {"/workspace/:object_id", :workspace_item, %{object_id: :object_id}},
    {"/proposals", :proposals, %{}},
    {"/proposals/:number", :proposal, %{number: :number}},
    {"/polls", :polls, %{}},
    {"/polls/:poll_id", :poll, %{poll_id: :poll_id}}
  ]

  @entries @pages ++
             for(
               %{id: fleet_id, path: path} <- Fleets.catalog(),
               {under, action, schema} <- @fleet_pages,
               do: %Entry{
                 path_pattern: path <> under,
                 fleet_id: fleet_id,
                 live_action: action,
                 parameter_schema: schema,
                 reserved_values: %{},
                 route_spec_id: action
               }
             )

  @specs %{
    home: {:home, nil, nil, "Keyfleet", "/", [], :home, %{}},
    account: {:account, :product, "Keyfleet", "Profile", "/", [:profile_actions], :product, %{}},
    points: {:points, :product, "Keyfleet", "Points", "/", [:profile_actions], :product, %{}},
    wallets: {:wallets, :product, "Keyfleet", "Wallets", "/", [:profile_actions], :product, %{}},
    connections:
      {:connections, :product, "Keyfleet", "Connections", "/", [:profile_actions], :product, %{}},
    about: {:about, :product, "Keyfleet", "About", "/", [:profile_actions], :product, %{}},
    opportunities:
      {:opportunities, :product, "Keyfleet", "What a fleet can take on", "/", [:profile_actions],
       :product, %{}},
    fleet: {:fleet, :product, "Keyfleet", "Fleet", "/", [:profile_actions], :product, %{}},
    keys: {:keys, :product, "Keyfleet", "Key", "/", [:profile_actions], :product, %{}},
    dms: {:dms, :product, "Keyfleet", "Messages", "/", [:profile_actions], :product, %{}},
    dm: {:dm, :product, "Keyfleet", "Messages", "/", [:profile_actions], :product, %{}},
    rooms: {:rooms, :product, "Keyfleet", "Rooms", "/", [:profile_actions], :product, %{}},
    workspace:
      {:workspace, :product, "Keyfleet", "Workspace", "/", [:profile_actions], :product, %{}},
    workspace_item:
      {:workspace_item, :product, "Keyfleet", "Workspace", "/", [:profile_actions], :product, %{}},
    proposals:
      {:proposals, :product, "Keyfleet", "Proposals", "/", [:profile_actions], :product, %{}},
    proposal:
      {:proposal, :product, "Keyfleet", "Proposals", "/", [:profile_actions], :product, %{}},
    polls: {:polls, :product, "Keyfleet", "Polls", "/", [:profile_actions], :product, %{}},
    poll: {:poll, :product, "Keyfleet", "Polls", "/", [:profile_actions], :product, %{}}
  }

  # The account's views, each its own page under one tab bar.
  @account_tabs [
    %RouteTarget{route_id: :account, label: "Profile", path: "/account"},
    %RouteTarget{route_id: :points, label: "Points", path: "/account/points"},
    %RouteTarget{route_id: :wallets, label: "Wallets", path: "/account/wallets"},
    %RouteTarget{route_id: :connections, label: "Connections", path: "/account/connections"}
  ]
  @account_tab_ids Enum.map(@account_tabs, & &1.route_id)

  def entries, do: @entries

  @doc """
  The page at the route `path_pattern`, as the router names the route an
  address matched, with the parts of the address the pattern names as
  `params`. A fleet's pages are at the fleet's own address
  (`Keyfleet.Fleets.path/1`) and nowhere else; the spec names that fleet as
  `fleet_id`.
  """
  def fetch!(path_pattern, params \\ %{}) do
    entry = Enum.find(@entries, &(&1.path_pattern == path_pattern)) || raise(NotFoundError)
    validate_params!(entry, params)
    build_spec(entry.route_spec_id, destination(path_pattern, params), entry.fleet_id)
  end

  def design_handoff do
    json =
      %{"schema_version" => 1, "routes" => Enum.map(@entries, &handoff_route/1)}
      |> ordered_json_value()
      |> Jason.encode!()

    %{json: json, digest: Base.encode16(:crypto.hash(:sha256, json), case: :lower)}
  end

  defp validate_params!(%Entry{parameter_schema: schema, reserved_values: reserved}, params) do
    valid? =
      Enum.all?(schema, fn {key, type} ->
        value = Map.get(params, Atom.to_string(key))
        valid_parameter?(type, value) and value not in Map.get(reserved, key, [])
      end)

    if valid?, do: :ok, else: raise(NotFoundError)
  end

  defp valid_parameter?(:slug, value), do: is_binary(value) and Regex.match?(@slug, value)
  defp valid_parameter?(:fleet_id, value), do: is_binary(value) and Regex.match?(@fleet_id, value)
  defp valid_parameter?(:token_id, value), do: is_binary(value) and Regex.match?(@token_id, value)

  defp valid_parameter?(:number, value), do: is_binary(value) and Regex.match?(@number, value)

  defp valid_parameter?(:poll_id, value),
    do: is_binary(value) and Regex.match?(@poll_id, value)

  defp valid_parameter?(:object_id, value),
    do: is_binary(value) and Regex.match?(@object_id, value)

  defp build_spec(route_spec_id, destination, fleet_id) do
    {route_id, app_id, app_label, page_label, root, controls, background, local_state} =
      Map.fetch!(@specs, route_spec_id)

    %Spec{
      route_id: route_id,
      destination: destination,
      fleet_id: fleet_id,
      app_id: app_id,
      app_display_label: app_label,
      page_display_label: page_label,
      canonical_root: root,
      sidebar_model: sidebar_model(app_id),
      tabs: tabs(route_id),
      header_controls: controls,
      background_slot: background,
      scroll_policy: :top,
      local_state: local_state
    }
  end

  defp tabs(route_id) when route_id in @account_tab_ids, do: @account_tabs
  defp tabs(_route_id), do: []

  defp sidebar_model(nil), do: %SidebarModel{id: :public, targets: []}

  # The fleets the sidebar shows, as a link to the fleet's page or as its name
  # alone, then the account page.
  defp sidebar_model(:product) do
    fleets =
      for %{sidebar: shown, name: name, path: path} <- Fleets.catalog(), shown != nil do
        case shown do
          :link -> %RouteTarget{route_id: :fleet, label: name, path: path}
          :name -> %NameOnly{label: name}
        end
      end

    %SidebarModel{
      id: :product,
      targets: fleets ++ [%RouteTarget{route_id: :account, label: "Account", path: "/account"}]
    }
  end

  # The handoff describes routes, not visits, so a parameterised route hands over
  # the pattern its paths are built from.
  defp handoff_route(entry) do
    spec = build_spec(entry.route_spec_id, entry.path_pattern, nil)

    %{
      "app_display_label" => spec.app_display_label,
      "app_id" => spec.app_id,
      "background_slot" => spec.background_slot,
      "canonical_root" => spec.canonical_root,
      "destination" => spec.destination,
      "header_controls" => spec.header_controls,
      "live_action" => entry.live_action,
      "local_state" => spec.local_state,
      "page_display_label" => spec.page_display_label,
      "parameter_schema" => entry.parameter_schema,
      "path_pattern" => entry.path_pattern,
      "reserved_values" => entry.reserved_values,
      "route_id" => spec.route_id,
      "scroll_policy" => spec.scroll_policy,
      "sidebar_model" => sidebar_handoff(spec.sidebar_model),
      "tabs" => Enum.map(spec.tabs, &target_handoff/1)
    }
  end

  defp sidebar_handoff(sidebar) do
    %{"id" => sidebar.id, "targets" => Enum.map(sidebar.targets, &target_handoff/1)}
  end

  defp target_handoff(%NameOnly{label: label}), do: %{"type" => "name", "label" => label}

  defp target_handoff(%RouteTarget{} = target) do
    %{
      "type" => "route",
      "route_id" => target.route_id,
      "label" => target.label,
      "destination" => target.path
    }
  end

  # A value is written into the path the way a browser sends it, so an item
  # such as `task#12` is `task%2312`.
  defp destination(path_pattern, params) do
    path_pattern
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> key -> params |> Map.fetch!(key) |> URI.encode(&URI.char_unreserved?/1)
      segment -> segment
    end)
  end

  defp ordered_json_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} ->
      {to_string(key), ordered_json_value(nested_value)}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered_json_value(value) when is_list(value), do: Enum.map(value, &ordered_json_value/1)
  defp ordered_json_value(value), do: value
end
