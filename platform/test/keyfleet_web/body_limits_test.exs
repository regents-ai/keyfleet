defmodule KeyfleetWeb.BodyLimitsTest do
  # Costly failure: the site decodes a body at an address that reads none, so
  # a hundred anonymous requests of under a megabyte each take gigabytes (a
  # 781 KiB JSON list took about 29 MB to decode), or a route that reads one
  # decodes more, or another kind, than it takes. Served on a real port, as a
  # visitor's request arrives.
  use ExUnit.Case, async: false

  alias Keyfleet.ContractSchema
  alias KeyfleetWeb.SignedAgentHelpers

  @json "application/json"
  @form "application/x-www-form-urlencoded"

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Keyfleet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    connector = Application.fetch_env!(:keyfleet, Keyfleet.OAuth)
    Application.put_env(:keyfleet, Keyfleet.OAuth, Keyword.put(connector, :enabled?, true))
    on_exit(fn -> Application.put_env(:keyfleet, Keyfleet.OAuth, connector) end)

    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:phoenix, :router_dispatch, :stop],
      &__MODULE__.dispatched/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{site: SignedAgentHelpers.serve_site!(:site).url}
  end

  @doc false
  # The fields a route's pipeline decoded, as the request leaves its route.
  def dispatched(_event, _measurements, %{conn: conn}, test),
    do: send(test, {:decoded, conn.request_path, conn.body_params})

  test "a body sent where no route reads one is never decoded", c do
    # Each body would be refused as unreadable (400) if it were decoded.
    answers =
      for path <- ["/", "/nope", "/api/v1/nope", "/api/v1/fleets", "/auth/privy/session"],
          {type, body} <- [{@json, "{"}, {@form, "%zz"}],
          do: {path, type, post!(c.site, path, [{"content-type", type}], body).status}

    assert answers == [
             {"/", @json, 404},
             {"/", @form, 404},
             {"/nope", @json, 404},
             {"/nope", @form, 404},
             {"/api/v1/nope", @json, 404},
             {"/api/v1/nope", @form, 404},
             {"/api/v1/fleets", @json, 404},
             {"/api/v1/fleets", @form, 404},
             {"/auth/privy/session", @json, 403},
             {"/auth/privy/session", @form, 403}
           ]
  end

  test "each route that reads a body decodes the one kind it takes, up to its size", c do
    session = forms_session(c.site)

    # The connector's address reads a body only once the request says who
    # sends it; this one's signature reaches a stand-in sign-in server, which
    # refuses it.
    SignedAgentHelpers.start_broker!(self(), :crypto.strong_rand_bytes(32))
    signed = [{Siwa.Contract.signature_input_header(), "sig1=()"}]

    routes = [
      {"/oauth/register", @json, 8192, []},
      {"/oauth/token", @form, 8192, []},
      {"/oauth/revoke", @form, 8192, []},
      {"/oauth/authorize", @form, 256, session},
      {"/oauth/connections/revoke", @form, 256, session},
      {"/api/agents/v1/pair", @json, 4096, []},
      {"/mcp", @json, 742 * 1024, signed},
      {"/visit-log", @json, 22 * 1024, session},
      {"/auth/privy/failure", @json, 64, session}
    ]

    for {path, type, limit, headers} <- routes do
      assert answers(c.site, path, type, limit, headers) == {path, :taken, 413, 415}
    end

    # The early-access form is served only while the site is closed.
    Application.put_env(:keyfleet, :app_surfaces, false)
    on_exit(fn -> Application.put_env(:keyfleet, :app_surfaces, true) end)

    assert answers(c.site, "/early", @form, 4096, session) == {"/early", :taken, 413, 415}
  end

  # Costly failure: an address the contract documents refuses a body with an
  # answer the contract doesn't give, such as the site's HTML error page.
  test "a documented address refuses a body too large or of another kind as the contract says",
       c do
    session = forms_session(c.site)

    for {path, headers} <- [{"/auth/privy/failure", session}, {"/api/agents/v1/pair", []}],
        {status, type, body} <- [{413, @json, body(@json, 8192)}, {415, @form, "x=a"}] do
      answer = post!(c.site, path, [{"content-type", type} | headers], body)

      assert answer.status == status, "#{path}: #{inspect(answer.body)}"
      assert ContractSchema.response_errors(answer.body, "POST", path, status) == []
    end
  end

  # A body of exactly `limit` bytes of the route's kind, one byte more, and
  # one of the other kind.
  defp answers(site, path, type, limit, headers) do
    other = if type == @json, do: @form, else: @json

    sent = fn type, size ->
      post!(site, path, [{"content-type", type} | headers], body(type, size))
    end

    sent.(type, limit)
    taken = taken(path, type, limit)
    {path, taken, sent.(type, limit + 1).status, sent.(other, 16).status}
  end

  # The body of exactly the limit reached its route whole. The connector
  # decodes a call only once the sign-in server has checked its signature, so
  # there the whole body is the one whose digest that server was sent.
  defp taken("/mcp", type, limit) do
    digest = Siwa.content_digest_for_body(body(type, limit))

    receive do
      {:broker_payload, %{"body_digest" => ^digest}} -> :taken
    after
      1_000 -> :not_read
    end
  end

  defp taken(path, type, limit) do
    field = field(type, limit)

    receive do
      {:decoded, ^path, %{"x" => ^field}} -> :taken
    after
      1_000 -> :not_decoded
    end
  end

  defp body(@json, size), do: ~s({"x":") <> field(@json, size) <> ~s("})
  defp body(@form, size), do: "x=" <> field(@form, size)

  defp field(@json, size), do: String.duplicate("a", size - 8)
  defp field(@form, size), do: String.duplicate("a", size - 2)

  # A browser's session cookie and the forms token its pages send.
  defp forms_session(site) do
    response = Req.get!(site <> "/auth/csrf", retry: false)

    [cookie | _rest] =
      response |> Req.Response.get_header("set-cookie") |> hd() |> String.split(";")

    [{"cookie", cookie}, {"x-csrf-token", response.body["csrf_token"]}]
  end

  # Each on its own connection: the site closes one whose body it refused
  # unread.
  defp post!(site, path, headers, body),
    do:
      Req.post!(site <> path,
        headers: [{"connection", "close"} | headers],
        body: body,
        retry: false,
        redirect: false
      )
end
