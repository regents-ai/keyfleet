defmodule Keyfleet.NotebookHubHelpers do
  @moduledoc """
  A fleet's notebook hub for tests of what Keyfleet asks it as one of its
  members (`Keyfleet.Notebooks.MemberRequest`). It makes anyone an editor of
  any space, and lists a space's notebooks as the hub does: `q` matched in
  any case against each one's title and description, newest added first,
  then by id, a page at a time with `next_cursor` naming the rest. Its pages
  hold at most two, as a hub answers a larger `limit` with the most it
  lists, so whoever reads every match reads every page. A space can instead
  refuse (`{:status, status}`) or answer only after a wait (`{:after, ms,
  notebooks}`). Each listing reaches the test as `{:listed, space, subject,
  q}`. Like Fly's private addresses, it answers only on IPv6, by name.
  """
  import Plug.Conn

  alias KeyfleetWeb.SignedAgentHelpers

  @page 2

  @doc """
  Serves `spaces`, each space's notebooks or answer, as the hub of
  `fleet_id` until the test ends.
  """
  def serve!(fleet_id, spaces) do
    test = self()
    hub = SignedAgentHelpers.serve_ipv6!(:hub, &answer(&1, &2, test, spaces))
    notebooks = Application.fetch_env!(:keyfleet, :notebooks)
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:keyfleet, :notebooks, notebooks) end)

    Application.put_env(
      :keyfleet,
      :notebooks,
      Keyword.put(notebooks, :fleets, %{fleet_id => hub})
    )

    hub
  end

  @doc "Notebook `n` as the hub lists it, added at `added`."
  def notebook(n, title, description, %DateTime{} = added) do
    %{
      "id" => "nb-" <> String.pad_leading(Integer.to_string(n), 16, "0"),
      "title" => title,
      "description" => description,
      "status" => "active",
      "author" => "u_1",
      "created_at" => hub_time(added),
      "updated_at" => hub_time(added),
      "tags" => [],
      "last_run_at" => nil
    }
  end

  # The hub writes its times in UTC to the millisecond.
  defp hub_time(%DateTime{microsecond: {microsecond, _precision}} = at),
    do: DateTime.to_iso8601(%{at | microsecond: {div(microsecond, 1000) * 1000, 3}})

  defp answer(conn, _opts, test, spaces) do
    conn = fetch_query_params(conn)

    case {conn.method, conn.path_info} do
      {"GET", ["api", "v1", "projects", space, "notebooks"]} ->
        [pass] = get_req_header(conn, "x-keyfleet-assertion")
        subject = JOSE.JWT.peek_payload(pass).fields["sub"]
        send(test, {:listed, space, subject, conn.query_params["q"]})
        listing(conn, Map.get(spaces, space, []))

      {"POST", ["api", "v1", "projects", _space, "members"]} ->
        json(conn, 201, %{})

      {"DELETE", ["api", "v1", "admin", "users", _user, "suspension"]} ->
        json(conn, 200, %{})
    end
  end

  defp listing(conn, {:status, status}), do: json(conn, status, %{})

  defp listing(conn, {:after, ms, notebooks}) do
    Process.sleep(ms)
    listing(conn, notebooks)
  end

  defp listing(conn, notebooks) do
    q = String.downcase(conn.query_params["q"])

    matching =
      notebooks
      |> Enum.filter(fn notebook ->
        Enum.any?([notebook["title"], notebook["description"]], &(String.downcase(&1) =~ q))
      end)
      |> Enum.sort_by(&{&1["created_at"], &1["id"]}, :desc)

    rest =
      case conn.query_params["cursor"] do
        nil -> matching
        "after:" <> id -> matching |> Enum.drop_while(&(&1["id"] != id)) |> Enum.drop(1)
      end

    {page, more} = Enum.split(rest, @page)
    next = if more != [], do: "after:" <> List.last(page)["id"]
    json(conn, 200, %{items: page, next_cursor: next})
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{success: status < 300, data: data}))
  end
end
