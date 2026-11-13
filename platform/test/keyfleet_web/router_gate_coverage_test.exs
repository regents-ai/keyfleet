defmodule KeyfleetWeb.RouterGateCoverageTest do
  @moduledoc """
  Walks the router's own route table so a route added later cannot quietly
  stay open while the site is closed: a route the launch gate lets through, or
  a LiveView mounted outside the gate's hook, fails here.
  """

  use KeyfleetWeb.ConnCase, async: false

  alias KeyfleetWeb.Live.LaunchGateHook

  setup do
    Application.put_env(:keyfleet, :app_surfaces, false)
    on_exit(fn -> Application.put_env(:keyfleet, :app_surfaces, true) end)
    :ok
  end

  test "only the early-access page, the reading pages, the operational files and NFT metadata stay open" do
    answers =
      for route <- routes(), conn = request(route), do: {route.verb, route.path, answer(conn)}

    still_open = for {verb, path, :open} <- answers, do: {verb, path}

    assert still_open == [
             {:get, "/healthz"},
             {:get, "/sitemap.xml"},
             {:get, "/robots.txt"},
             {:get, "/agents.md"},
             {:get, "/.well-known/security.txt"},
             {:get, "/.well-known/hub-jwks.json"},
             {:get, "/metadata/collection.json"},
             {:get, "/metadata/keys/:token_id"},
             {:get, "/early"},
             {:post, "/early"},
             {:get, "/about"},
             {:get, "/docs"},
             {:get, "/changelog"},
             {:get, "/agents"},
             {:get, "/agents/:agent"},
             {:get, "/privacy"},
             {:get, "/terms"}
           ]

    # Every page a browser opens is sent to the early-access page, and every
    # other address answers 503.
    assert for({:get, path, :to_early} <- answers, do: path) ==
             ~w(/admin/errors /admin/errors/:id /admin/errors/:id/:occurrence_id /admin/messages) ++
               ~w(/app /agent /start) ++
               ~w(/help /skill/:part /agent/git-remote-siwa /share/:file /share/projects/:fleet_id/:file /fleets/:file /fleets/:fleet_id/rooms) ++
               ~w(/oauth/authorize /oauth/connections / /fleets/:fleet_id/notebooks/open /account) ++
               ~w(/account/agents /account/points /account/wallets /account/connections /pair /opportunities) ++
               for(
                 fleet <-
                   ~w(/classic/1 /syndicate/1 /cascade/1 /accelerant/1 /app/fleets/regents_club),
                 page <-
                   ["", "/workspace", "/workspace/:object_id"] ++
                     ["/code/:repository/commits/:commit", "/code/:repository/commits"] ++
                     ["/code/:repository/files"] ++
                     ["/projects/:project", "/proposals"] ++
                     ["/proposals/:number", "/treasury", "/polls", "/polls/:poll_id", "/search"] ++
                     ["/worldline", "/keys/:token_id"] ++
                     ["/keys/:token_id/dms", "/keys/:token_id/dms/:other_token_id"],
                 do: fleet <> page
               )
  end

  # The walk above asks for `/skill/gate-coverage`, which names no file; an
  # agent asks for a part by its file name, as it asks for the guide.
  test "the joining guide's parts answer as the guide does while the site is closed" do
    for path <- ~w(/skill.md /skill/code.md /skill/notebooks.md /skill/decide.md) do
      assert build_conn() |> get(path) |> answer() == :closed, path
    end
  end

  test "every product LiveView mounts through the gate" do
    ungated =
      for route <- routes(),
          live_view = route.metadata[:phoenix_live_view],
          not mounts_through_gate?(live_view),
          do: route.path

    assert ungated == []
  end

  # The development workshop has an independent loopback gate, exercised by
  # ShowcaseTest for both HTTP and connected mounts. It is absent in production.
  defp routes do
    KeyfleetWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.reject(fn route ->
      method = route.verb |> Atom.to_string() |> String.upcase()

      info =
        Phoenix.Router.route_info(
          KeyfleetWeb.Router,
          method,
          concrete_path(route.path),
          "localhost"
        )

      :local_showcase in info.pipe_through
    end)
  end

  # The early-access form is sent with its page's token, as a browser sends it,
  # and an empty address, so the form's own answer comes back rather than a
  # redirect to its page.
  defp request(%{verb: :post, path: "/early"}) do
    page = get(build_conn(), "/early")

    [token] =
      Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body, capture: :all_but_first)

    page |> recycle() |> post("/early", %{"_csrf_token" => token, "email" => ""})
  end

  # An agent's page stays open, so the walk asks for one that is there.
  defp request(%{verb: :get, path: "/agents/:agent"}), do: get(build_conn(), "/agents/dots")

  defp request(route) do
    Phoenix.ConnTest.dispatch(build_conn(), @endpoint, route.verb, concrete_path(route.path), %{})
  end

  defp answer(%Plug.Conn{status: 503}), do: :closed

  defp answer(%Plug.Conn{status: 302} = conn),
    do: if(redirected_to(conn) == "/early", do: :to_early, else: :open)

  defp answer(_conn), do: :open

  # Placeholders stand in for path parameters; the gate answers before any
  # controller or LiveView reads them, on every route it closes.
  defp concrete_path(path) do
    String.replace(path, ~r{/[:*][^/]+}, "/gate-coverage")
  end

  defp mounts_through_gate?({_module, _action, _opts, %{extra: %{on_mount: hooks}}}) do
    Enum.any?(hooks, &(&1.id == {LaunchGateHook, :default}))
  end

  defp mounts_through_gate?(_live_view), do: false
end
