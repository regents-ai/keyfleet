defmodule KeyFleetWeb.RouteCatalog do
  @moduledoc "Canonical behavior metadata for the route allowlist."

  alias KeyFleetWeb.NotFoundError

  alias __MODULE__.{
    Entry,
    RouteTarget,
    SidebarHeading,
    SidebarModel,
    Spec
  }

  @slug ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @fleet_id ~r/\A[a-z][a-z0-9_]{0,62}\z/
  # Eighteen digits at most, so every admitted key number is a database integer.
  @token_id ~r/\A[1-9][0-9]{0,17}\z/

  @entries [
    %Entry{
      path_pattern: "/",
      live_action: :home,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :home
    },
    %Entry{
      path_pattern: "/app",
      live_action: :app,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :app
    },
    %Entry{
      path_pattern: "/account",
      live_action: :account,
      parameter_schema: %{},
      reserved_values: %{},
      route_spec_id: :account
    },
    %Entry{
      path_pattern: "/app/keys/:fleet_id/:token_id",
      live_action: :keys,
      parameter_schema: %{fleet_id: :fleet_id, token_id: :token_id},
      reserved_values: %{},
      route_spec_id: :keys
    },
    %Entry{
      path_pattern: "/app/fleets/:fleet_id/rooms/:slug",
      live_action: :rooms,
      parameter_schema: %{fleet_id: :fleet_id, slug: :slug},
      reserved_values: %{},
      route_spec_id: :rooms
    }
  ]

  @specs %{
    home: {:home, nil, nil, "KeyFleet", "/", [], :home, :landing, %{}},
    app:
      {:app, :product, "KeyFleet", "Overview", "/app", [:profile_actions], :product, :overview,
       %{}},
    account:
      {:account, :product, "KeyFleet", "Account", "/app", [:profile_actions], :product, :detail,
       %{}},
    keys:
      {:keys, :product, "KeyFleet", "Key", "/app", [:profile_actions], :product, :detail, %{}},
    rooms:
      {:rooms, :product, "KeyFleet", "Rooms", "/app", [:profile_actions], :product, :detail, %{}}
  }

  def entries, do: @entries

  def fetch!(action, params \\ %{}) do
    entry = Enum.find(@entries, &(&1.live_action == action)) || raise(NotFoundError)
    validate_params!(entry, params)
    build_spec(entry.route_spec_id, destination(entry.path_pattern, params))
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

  defp build_spec(route_spec_id, destination) do
    {route_id, app_id, app_label, page_label, root, controls, background, transition, local_state} =
      Map.fetch!(@specs, route_spec_id)

    %Spec{
      route_id: route_id,
      destination: destination,
      app_id: app_id,
      app_display_label: app_label,
      page_display_label: page_label,
      canonical_root: root,
      sidebar_model: sidebar_model(app_id),
      header_controls: controls,
      background_slot: background,
      content_transition_kind: transition,
      scroll_policy: :top,
      local_state: local_state
    }
  end

  defp sidebar_model(nil), do: %SidebarModel{id: :public, targets: []}

  defp sidebar_model(:product) do
    %SidebarModel{
      id: :product,
      targets: [
        %RouteTarget{route_id: :app, label: "Overview", path: "/app"},
        %RouteTarget{route_id: :account, label: "Account", path: "/account"}
      ]
    }
  end

  # The handoff describes routes, not visits, so a parameterised route hands over
  # the pattern its paths are built from.
  defp handoff_route(entry) do
    spec = build_spec(entry.route_spec_id, entry.path_pattern)

    %{
      "app_display_label" => spec.app_display_label,
      "app_id" => spec.app_id,
      "background_slot" => spec.background_slot,
      "canonical_root" => spec.canonical_root,
      "content_transition_kind" => spec.content_transition_kind,
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
      "sidebar_model" => sidebar_handoff(spec.sidebar_model)
    }
  end

  defp sidebar_handoff(sidebar) do
    %{"id" => sidebar.id, "targets" => Enum.map(sidebar.targets, &sidebar_target_handoff/1)}
  end

  defp sidebar_target_handoff(%RouteTarget{} = target) do
    %{
      "type" => "route",
      "route_id" => target.route_id,
      "label" => target.label,
      "destination" => target.path
    }
  end

  defp sidebar_target_handoff(%SidebarHeading{} = heading) do
    %{"type" => "heading", "label" => heading.label}
  end

  defp destination(path_pattern, params) do
    path_pattern
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> key -> Map.fetch!(params, key)
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
